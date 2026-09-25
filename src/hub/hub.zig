//! `omajot hub`: the always-on relay in the middle (docs/PROTOCOL.md §2).
//! Stores op batches and attachments, rings an SSE doorbell when the head
//! moves, and serves the PWA. Ops are opaque here. Runs on baz, bound to
//! loopback; `tailscale serve` provides HTTPS and the identity header.
const std = @import("std");
const builtin = @import("builtin");
const web = @import("baz");
const core = @import("core");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const store = @import("store.zig");
pub const blobs = @import("blobs.zig");
pub const static = @import("static.zig");
pub const rawjson = @import("rawjson.zig");
pub const tsurl = @import("tsurl.zig");
const qrcli = @import("../qrcli.zig");

// Explicit limits. See also store.max_* and blobs.max_blob_bytes.
pub const max_subscribers = 64;
pub const connections = 24;
pub const workers = 4;
/// Ordinary requests: one batch or one 1 MiB blob chunk, also from a phone on
/// a slow link.
pub const request_timeout_ms: u32 = 30_000;
/// A kept-alive connection may wait this long for its next request; the
/// request's own deadline starts at its first byte (bounded/http idle_timeout_ms).
pub const idle_timeout_ms: u32 = 60_000;
/// The SSE doorbell route's own deadline (baz RouteOptions.timeout_ms), so a
/// phone or daemon reconnects every ~10 minutes instead of every request timeout.
pub const sse_timeout_ms: u32 = 10 * 60_000;
/// SSE streams end cleanly this long before their deadline, so baz never
/// cuts a chunked body (spikes/hub/REPORT.md).
pub const sse_margin_ms: u32 = 10_000;
pub const heartbeat_ms: u32 = 15_000;
/// bounded/http reserves (and touches) 2 × max_body per connection at start,
/// so bodies stay at 1 MiB: one batch, one blob chunk, or one small blob.
pub const max_body: u32 = @intCast(@max(store.max_batch_bytes, blobs.max_chunk_bytes));

const usage =
    \\usage: omajot hub [--port 8787] [--data <dir>] (--login <tailscale login> | --no-auth)
    \\                  [--web <dir>] [--bind 127.0.0.1] [--url <public url>]
    \\
    \\  --login    only requests whose Tailscale-User-Login equals this may use /api/*
    \\  --no-auth  skip the identity check (local development; loopback only)
    \\  --data     batches.jsonl and blobs/ live here (default: ./omajot-data)
    \\  --web      the PWA to serve (default: web/dist of this checkout, if present)
    \\  --timeout-ms  deadline for ordinary requests (default 30000); the SSE route has
    \\           its own 10-minute deadline and its streams end cleanly before it
    \\  --url    the URL phones use, printed with a QR code at startup
    \\           (default: found in `tailscale serve status`)
    \\
;

const Subscription = struct {
    active: bool = false,
    notification: web.continuation.Notification = undefined,
};

pub const Shared = struct {
    gpa: Allocator,
    io: Io,
    /// Guards `log` and `subscriptions`.
    mutex: Io.Mutex = .init,
    log: store.Store,
    head: std.atomic.Value(u64) = .init(0),
    subscriptions: [max_subscribers]Subscription = @splat(.{}),
    blob_dir: Io.Dir,
    blob_tmp_counter: std.atomic.Value(u64) = .init(0),
    /// Serializes chunked uploads (single user; contention is rare).
    blob_mutex: Io.Mutex = .init,
    assets: static.Assets,
    /// null: --no-auth.
    login: ?[]const u8,
    sse_lifetime_ns: u64,

    fn lock(self: *Shared) void {
        self.mutex.lockUncancelable(self.io);
    }
    fn unlock(self: *Shared) void {
        self.mutex.unlock(self.io);
    }
};

const Application = web.App(Shared);
const Context = Application.Context;
const Step = web.continuation.Step;

// ------------------------------------------------------------------ auth

fn authenticate(ctx: *Context) !Application.Decision {
    const login = ctx.shared.login orelse return .continue_request;
    const path = ctx.request.path() orelse return .continue_request;
    if (!std.mem.startsWith(u8, path, "/api/")) return .continue_request;
    const given = ctx.request.header("Tailscale-User-Login") orelse "";
    if (std.mem.eql(u8, given, login)) return .continue_request;
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.text(403, "forbidden: not the configured tailnet login\n");
    return .respond;
}

// ------------------------------------------------------------------ api

fn whoami(ctx: *Context) !void {
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.jsonValue(200, .{
        .login = ctx.request.header("Tailscale-User-Login"),
        .name = ctx.request.header("Tailscale-User-Name"),
        .head = ctx.shared.head.load(.acquire),
    });
}

/// The request body as one slice: borrowed when contiguous, else copied into `owned`.
fn bodyBytes(ctx: *Context, owned: *?[]u8) ![]const u8 {
    const body = ctx.request.body();
    if (body.contiguous()) |bytes| return bytes;
    const copy = try ctx.shared.gpa.alloc(u8, body.len());
    errdefer ctx.shared.gpa.free(copy);
    owned.* = copy;
    return try body.copyTo(copy);
}

fn postBatch(ctx: *Context) !void {
    try ctx.response.header("Cache-Control", "no-store");
    if (ctx.request.body().len() > store.max_batch_bytes) return ctx.response.text(413, "batch too large\n");
    var owned: ?[]u8 = null;
    defer if (owned) |o| ctx.shared.gpa.free(o);
    const body = try bodyBytes(ctx, &owned);

    var notifications: [max_subscribers]web.continuation.Notification = undefined;
    var count: usize = 0;
    const outcome = blk: {
        ctx.shared.lock();
        defer ctx.shared.unlock();
        const appended = ctx.shared.log.append(body);
        const fresh = if (appended) |a| !a.duplicate else |_| false;
        if (fresh) {
            ctx.shared.head.store(ctx.shared.log.head(), .release);
            for (&ctx.shared.subscriptions) |*subscription| {
                if (!subscription.active) continue;
                notifications[count] = subscription.notification;
                count += 1;
            }
        }
        break :blk appended;
    };
    // Signal after releasing the lock, as in baz's jobs example.
    for (notifications[0..count]) |notification| _ = notification.signal();
    const result = outcome catch |err| return switch (err) {
        error.InvalidBatch => ctx.response.text(400, "invalid batch\n"),
        error.OutOfOrder => ctx.response.text(409, "bseq out of order\n"),
        error.BatchTooLarge => ctx.response.text(413, "batch too large\n"),
        else => err,
    };
    try ctx.response.jsonValue(200, .{ .seq = result.seq, .head = result.head });
}

fn getBatches(ctx: *Context) !void {
    try ctx.response.header("Cache-Control", "no-store");
    const query = ctx.request.query() catch return ctx.response.text(400, "bad query\n");
    const after = if (query.firstRaw("after")) |raw|
        std.fmt.parseInt(u64, raw.value_raw, 10) catch return ctx.response.text(400, "bad after\n")
    else
        0;
    const limit = if (query.firstRaw("limit")) |raw|
        std.fmt.parseInt(u32, raw.value_raw, 10) catch return ctx.response.text(400, "bad limit\n")
    else
        store.default_page_limit;
    if (limit == 0) return ctx.response.text(400, "bad limit\n");

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(ctx.shared.gpa);
    const head = blk: {
        ctx.shared.lock();
        defer ctx.shared.unlock();
        try ctx.shared.log.page(after, limit, &lines, ctx.shared.gpa);
        break :blk ctx.shared.log.head();
    };
    // Line bytes are immutable once stored, so they are written without the lock.
    var out = try ctx.response.stream(200, "application/json", .{});
    try out.print("{{\"head\":{d},\"batches\":[", .{head});
    for (lines.items, 0..) |line, i| {
        if (i != 0) try out.writeAll(",");
        try out.writeAll(line);
    }
    try out.writeAll("]}");
    try out.finish();
}

fn putBlob(ctx: *Context) !void {
    try ctx.response.header("Cache-Control", "no-store");
    const name = ctx.param("name") orelse return ctx.response.text(404, "not found\n");
    if (!blobs.validName(name)) return ctx.response.text(400, "bad blob name\n");
    const query = ctx.request.query() catch return ctx.response.text(400, "bad query\n");
    var owned: ?[]u8 = null;
    defer if (owned) |o| ctx.shared.gpa.free(o);
    const body = try bodyBytes(ctx, &owned);

    if (query.firstRaw("total")) |total_raw| {
        // Resumable chunked upload for blobs larger than one request body.
        const total = std.fmt.parseInt(u64, total_raw.value_raw, 10) catch return ctx.response.text(400, "bad total\n");
        const offset = if (query.firstRaw("offset")) |raw|
            std.fmt.parseInt(u64, raw.value_raw, 10) catch return ctx.response.text(400, "bad offset\n")
        else
            0;
        var received: u64 = 0;
        const result = blk: {
            ctx.shared.blob_mutex.lockUncancelable(ctx.shared.io);
            defer ctx.shared.blob_mutex.unlock(ctx.shared.io);
            break :blk blobs.appendChunk(ctx.shared.io, ctx.shared.blob_dir, name, offset, total, body, &received);
        };
        const chunked = result catch |err| return switch (err) {
            error.OffsetMismatch => ctx.response.jsonValue(409, .{ .received = received }),
            error.HashMismatch => ctx.response.text(400, "sha256 of body does not match name\n"),
            error.BlobTooLarge => ctx.response.text(413, "blob too large\n"),
            error.BadChunk => ctx.response.text(400, "bad chunk\n"),
            else => err,
        };
        return switch (chunked) {
            .partial => |n| ctx.response.jsonValue(202, .{ .received = n }),
            .created => ctx.response.jsonValue(201, .{ .received = total }),
            .existed => ctx.response.jsonValue(200, .{ .received = total }),
        };
    }

    const suffix = ctx.shared.blob_tmp_counter.fetchAdd(1, .monotonic);
    const saved = blobs.save(ctx.shared.io, ctx.shared.blob_dir, name, &.{body}, suffix) catch |err| switch (err) {
        error.HashMismatch => return ctx.response.text(400, "sha256 of body does not match name\n"),
        error.BlobTooLarge => return ctx.response.text(413, "blob too large\n"),
        else => return err,
    };
    try ctx.response.text(if (saved == .created) 201 else 200, if (saved == .created) "created\n" else "exists\n");
}

fn getBlob(ctx: *Context) !void {
    const name = ctx.param("name") orelse return ctx.response.text(404, "not found\n");
    if (!blobs.validName(name)) return ctx.response.text(404, "not found\n");
    const io = ctx.shared.io;
    const file = ctx.shared.blob_dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.response.header("Cache-Control", "no-store");
            return ctx.response.text(404, "not found\n");
        },
        else => return err,
    };
    defer file.close(io);
    const size = try file.length(io);
    try ctx.response.header("Cache-Control", "public, max-age=31536000, immutable");
    try ctx.response.header("X-Content-Type-Options", "nosniff");
    // Attachments share the PWA's origin; never let one run script.
    try ctx.response.header("Content-Security-Policy", "sandbox; default-src 'none'; img-src 'self'; style-src 'unsafe-inline'");
    var out = try ctx.response.stream(200, blobs.contentType(name), .{ .content_length = size });
    var read_buffer: [16 * 1024]u8 = undefined;
    var scratch: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    _ = try out.copyFrom(&reader.interface, &scratch);
    try out.finish();
}

// ------------------------------------------------------------------ SSE doorbell

const Doorbell = struct {
    cursor: u64 = 0,
    /// Send the current head once even if it equals the cursor? Only when the
    /// client is ahead of the hub (hub data reset): it must learn the real head.
    force: bool = false,
    subscription: ?u8 = null,
    started_ns: i96 = 0,
    last_write_ns: i96 = 0,

    pub fn deinit(self: *Doorbell, ctx: *Context) void {
        if (self.subscription) |slot| {
            ctx.shared.lock();
            defer ctx.shared.unlock();
            ctx.shared.subscriptions[slot].active = false;
            self.subscription = null;
        }
    }
};

fn nowNs(ctx: *Context) i96 {
    return Io.Clock.awake.now(ctx.shared.io).nanoseconds;
}

fn startEvents(ctx: *Context, state: *Doorbell) !Step {
    try ctx.response.header("Cache-Control", "no-store");
    if (ctx.request.header("Last-Event-ID")) |raw| {
        state.cursor = std.fmt.parseInt(u64, std.mem.trim(u8, raw, " "), 10) catch {
            try ctx.response.text(400, "bad Last-Event-ID\n");
            return .finish;
        };
    }
    {
        ctx.shared.lock();
        defer ctx.shared.unlock();
        for (&ctx.shared.subscriptions, 0..) |*subscription, index| {
            if (subscription.active) continue;
            subscription.notification = try ctx.notification();
            subscription.active = true;
            state.subscription = @intCast(index);
            break;
        }
    }
    if (state.subscription == null) {
        try ctx.response.text(503, "too many event streams\n");
        return .finish;
    }
    state.force = state.cursor > ctx.shared.head.load(.acquire);
    state.started_ns = nowNs(ctx);
    state.last_write_ns = state.started_ns;
    try ctx.response.header("X-Accel-Buffering", "no");
    var out = try ctx.response.snapshot(200, web.sse.content_type, .{});
    // Reconnect quickly after the stream ends at its planned lifetime.
    try web.sse.comment(out.writer(), "omajot doorbell");
    try web.sse.write(out.writer(), .{ .event = "hello", .data = "{}", .retry_ms = 1000 });
    return .flush;
}

fn resumeEvents(ctx: *Context, state: *Doorbell, event: web.continuation.Event) !Step {
    const now = nowNs(ctx);
    const lifetime: i96 = ctx.shared.sse_lifetime_ns;
    const elapsed = now - state.started_ns;
    if (elapsed >= lifetime) return .finish;

    const head = ctx.shared.head.load(.acquire);
    if (head > state.cursor or state.force) {
        var id_buffer: [24]u8 = undefined;
        var data_buffer: [48]u8 = undefined;
        var out = try ctx.response.resumeSnapshot();
        const id = try std.fmt.bufPrint(&id_buffer, "{d}", .{head});
        const data = try std.fmt.bufPrint(&data_buffer, "{{\"head\":{d}}}", .{head});
        try web.sse.write(out.writer(), .{ .event = "head", .id = id, .data = data });
        state.cursor = head;
        state.force = false;
        state.last_write_ns = now;
        return .flush;
    }
    const heartbeat: i96 = @as(i96, heartbeat_ms) * std.time.ns_per_ms;
    if (event == .timer and now - state.last_write_ns >= heartbeat - std.time.ns_per_ms) {
        var out = try ctx.response.resumeSnapshot();
        try web.sse.heartbeat(out.writer());
        state.last_write_ns = now;
        return .flush;
    }
    const until_heartbeat = @max(heartbeat - (now - state.last_write_ns), std.time.ns_per_ms);
    const until_end = lifetime - elapsed;
    return .{ .await_notification = @intCast(@min(until_heartbeat, until_end)) };
}

// ------------------------------------------------------------------ static PWA

fn notFound(ctx: *Context) !void {
    const method = ctx.request.method();
    const path = ctx.request.path() orelse "/";
    if (!std.mem.startsWith(u8, path, "/api/") and
        (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD")))
    {
        if (ctx.shared.assets.lookup(path)) |asset| {
            // The service worker owns offline caching; always revalidate here.
            try ctx.response.header("Cache-Control", "no-cache");
            return ctx.response.borrowBody(200, asset.content_type, asset.body);
        }
        if (ctx.shared.assets.map.count() == 0 and std.mem.eql(u8, path, "/")) {
            return ctx.response.borrowBody(200, "text/html; charset=utf-8",
                \\<!doctype html><meta charset="utf-8"><title>omajot hub</title>
                \\<p>omajot hub is running. No web app was found; start it with <code>--web &lt;dir&gt;</code>.
            );
        }
    }
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.text(404, "not found\n");
}

// ------------------------------------------------------------------ main

const Options = struct {
    port: u16 = 8787,
    bind: [4]u8 = .{ 127, 0, 0, 1 },
    data: []const u8 = "omajot-data",
    login: ?[]const u8 = null,
    no_auth: bool = false,
    web_dir: ?[]const u8 = null,
    timeout_ms: u32 = request_timeout_ms,
    url: ?[]const u8 = null,
};

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        var name = arg;
        var value: ?[]const u8 = null;
        if (std.mem.findScalar(u8, arg, '=')) |eq| {
            name = arg[0..eq];
            value = arg[eq + 1 ..];
        }
        if (std.mem.eql(u8, name, "--no-auth")) {
            options.no_auth = true;
            continue;
        }
        if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) return error.Help;
        const v = value orelse blk: {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            break :blk args[i];
        };
        if (std.mem.eql(u8, name, "--port")) {
            options.port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, name, "--bind")) {
            options.bind = try web.Config.parseBindAddress(v);
        } else if (std.mem.eql(u8, name, "--data")) {
            options.data = v;
        } else if (std.mem.eql(u8, name, "--login")) {
            options.login = v;
        } else if (std.mem.eql(u8, name, "--web")) {
            options.web_dir = v;
        } else if (std.mem.eql(u8, name, "--url")) {
            options.url = v;
        } else if (std.mem.eql(u8, name, "--timeout-ms")) {
            options.timeout_ms = try std.fmt.parseInt(u32, v, 10);
            if (options.timeout_ms < 2000) return error.TimeoutTooShort;
        } else return error.UnknownOption;
    }
    if (options.no_auth == (options.login != null)) return error.NeedLoginOrNoAuth;
    if (options.no_auth and options.bind[0] != 127) return error.NoAuthRequiresLoopback;
    return options;
}

/// The URL and QR code for phones, on stderr next to the READY line.
fn printPhoneUrl(gpa: Allocator, io: Io, explicit: ?[]const u8, port: u16) void {
    const detected = if (explicit == null) tsurl.detect(gpa, io, port) else null;
    defer if (detected) |d| gpa.free(d);
    const url = explicit orelse detected orelse {
        std.debug.print("omajot hub: no public URL (publish it with `tailscale serve --bg --https=8443 http://127.0.0.1:{d}`, or pass --url)\n", .{port});
        var buffer: [2048]u8 = undefined;
        var w: Io.Writer = .fixed(&buffer);
        core.invite.writeText(&w) catch return;
        std.debug.print("\n{s}", .{w.buffered()});
        return;
    };
    var buffer: [16 * 1024]u8 = undefined;
    var aw: Io.Writer = .fixed(&buffer);
    qrcli.write(&aw, "omajot on your phone (scan, then Share → Add to Home Screen):", url) catch {
        std.debug.print("omajot hub: phones open {s}\n", .{url});
        return;
    };
    std.debug.print("{s}\n", .{aw.buffered()});
}

/// `<repo>/web/dist` when this binary is `<repo>/zig-out/bin/omajot`.
fn defaultWebDir(io: Io, gpa: Allocator) !?[]u8 {
    const exe_dir = std.process.executableDirPathAlloc(io, gpa) catch return null;
    defer gpa.free(exe_dir);
    const candidate = try std.fs.path.join(gpa, &.{ exe_dir, "..", "..", "web", "dist" });
    Io.Dir.cwd().access(io, candidate, .{}) catch {
        gpa.free(candidate);
        return null;
    };
    return candidate;
}

var stop_target: std.atomic.Value(?*Application) = .init(null);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    if (stop_target.load(.seq_cst)) |app| app.requestStopFromSignal();
}

pub fn main(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const gpa = init.gpa;
    const options = parseOptions(args) catch |err| {
        if (err != error.Help) std.debug.print("omajot hub: {s}\n", .{@errorName(err)});
        std.debug.print("{s}", .{usage});
        std.process.exit(if (err == error.Help) 0 else 2);
    };

    try Io.Dir.cwd().createDirPath(io, options.data);
    var data_dir = try Io.Dir.cwd().openDir(io, options.data, .{});
    defer data_dir.close(io);
    try data_dir.createDirPath(io, blobs.dir_name);
    var blob_dir = try data_dir.openDir(io, blobs.dir_name, .{});
    defer blob_dir.close(io);

    var owned_web: ?[]u8 = null;
    defer if (owned_web) |w| gpa.free(w);
    const web_dir: ?[]const u8 = options.web_dir orelse blk: {
        owned_web = try defaultWebDir(io, gpa);
        break :blk owned_web;
    };
    var assets = if (web_dir) |dir| static.Assets.load(gpa, io, dir) catch |err| {
        std.debug.print("omajot hub: cannot load web dir {s}: {s}\n", .{ dir, @errorName(err) });
        return err;
    } else static.Assets.empty(gpa);
    defer assets.deinit();

    const shared = try gpa.create(Shared);
    defer gpa.destroy(shared);
    shared.* = .{
        .gpa = gpa,
        .io = io,
        .log = try store.Store.open(gpa, io, data_dir),
        .blob_dir = blob_dir,
        .assets = assets,
        .login = options.login,
        .sse_lifetime_ns = @as(u64, sse_timeout_ms - sse_margin_ms) * std.time.ns_per_ms,
    };
    defer shared.log.deinit();
    shared.head.store(shared.log.head(), .release);
    if (shared.log.dropped_bytes > 0)
        std.log.warn("{s}: dropped a torn last line ({d} bytes) left by a crash", .{ store.file_name, shared.log.dropped_bytes });

    const app = try Application.init(.{
        .allocator = gpa,
        .io = io,
        .shared = shared,
        .server = .{
            .port = options.port,
            .bind_address = options.bind,
            .execution = .workers,
            .workers = workers,
            .connections = connections,
            .shards = 1,
            .timeout_ms = options.timeout_ms,
            .idle_timeout_ms = idle_timeout_ms,
            .max_timeout_ms = @max(sse_timeout_ms, options.timeout_ms),
            .max_body = max_body,
            .shutdown_ms = 2000,
            .output_bytes = 128 * 1024,
            .memory_budget_bytes = 256 << 20,
        },
        .response = .{ .body_bytes = 32 * 1024 },
        .max_continuations = max_subscribers,
        .middleware = &.{.{ .before = authenticate }},
        .not_found = notFound,
    });
    defer app.deinit();
    try app.route("GET", "/api/whoami", whoami);
    try app.route("POST", "/api/batches", postBatch);
    try app.route("GET", "/api/batches", getBatches);
    try app.route("PUT", "/api/blobs/:name", putBlob);
    try app.route("GET", "/api/blobs/:name", getBlob);
    try app.routeContinuation("GET", "/api/events", Doorbell, startEvents, resumeEvents, .{ .timeout_ms = sse_timeout_ms });

    try app.start();
    stop_target.store(app, .seq_cst);
    defer stop_target.store(null, .seq_cst);
    if (builtin.os.tag != .windows) {
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);
    }
    std.debug.print("omajot hub READY port={d} backend={s} data={s} head={d} web={s} auth={s}\n", .{
        app.port(),              web.backend_name,                        options.data,
        shared.log.head(),       web_dir orelse "(none)",                 options.login orelse "OFF (--no-auth)",
    });
    printPhoneUrl(gpa, io, options.url, app.port());
    app.run() catch |err| {
        // Storage may still be borrowed by the engine: never unwind into deinit.
        std.debug.print("omajot hub: FATAL {s}\n", .{@errorName(err)});
        std.process.exit(70);
    };
}

test {
    _ = store;
    _ = blobs;
    _ = static;
    _ = rawjson;
    _ = tsurl;
}

test "parseOptions" {
    const o = try parseOptions(&.{ "--port", "9000", "--login=me@x", "--data", "/tmp/d" });
    try std.testing.expectEqual(@as(u16, 9000), o.port);
    try std.testing.expectEqualStrings("me@x", o.login.?);
    try std.testing.expectError(error.NeedLoginOrNoAuth, parseOptions(&.{}));
    try std.testing.expectError(error.NeedLoginOrNoAuth, parseOptions(&.{ "--no-auth", "--login", "x" }));
    try std.testing.expectError(error.NoAuthRequiresLoopback, parseOptions(&.{ "--no-auth", "--bind", "0.0.0.0" }));
    _ = try parseOptions(&.{"--no-auth"});
}
