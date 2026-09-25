//! `omajot daemon`: the desktop replica behind the Omarchy plugin.
//! Speaks the client protocol (docs/PROTOCOL.md §1) as JSON lines on
//! stdin/stdout, keeps the replica on disk (§4), and syncs with the hub (§2).
//!
//! Threads: main reads stdin; `syncLoop` pushes the outbox, pulls pages,
//! moves attachments; `doorbellLoop` follows the hub's SSE stream and wakes
//! the sync loop. `lock` guards the engine, the replica and sync status;
//! `out_lock` guards stdout.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const rawjson = @import("../hub/rawjson.zig");
pub const replica = @import("replica.zig");
pub const attachments = @import("attachments.zig");
pub const hubclient = @import("hubclient.zig");
pub const paste = @import("paste.zig");

pub const version = "0.1.0";
pub const max_line_bytes: usize = 16 << 20;
pub const page_limit = 200;
/// Idle pull interval even without doorbell (safety net).
pub const idle_poll_ms = 60_000;
pub const max_backoff_ms = 30_000;
/// Coalesce keystrokes into one batch.
pub const push_debounce_ms = 200;

const usage =
    \\usage: omajot daemon [--hub <url>|--no-hub] [--data <dir>]
    \\
    \\  Speaks omajot's client protocol as JSON lines on stdin/stdout.
    \\  --hub   hub base URL (default: "hub" in the config file; without one the
    \\          daemon keeps notes locally and does not sync)
    \\  --data  replica directory (default: "data" in the config file, else
    \\          $XDG_DATA_HOME/omajot or ~/.local/share/omajot)
    \\
    \\  Config file: $XDG_CONFIG_HOME/omajot/config.json or ~/.config/omajot/config.json,
    \\  e.g. {"hub": "https://host.tailnet.ts.net:8443", "data": "~/.local/share/omajot"}
    \\
;

const SyncState = enum { connecting, online, offline };
const Reported = struct { state: SyncState, pending: usize, head: u64 };

const Daemon = struct {
    gpa: Allocator,
    io: Io,
    lock: Io.Mutex = .init,
    out_lock: Io.Mutex = .init,
    stdout: *Io.Writer,
    engine: core.Engine = undefined,
    engine_ready: bool = false,
    rep: replica.Replica = undefined,
    data_path: []const u8,
    att_dir: Io.Dir,
    hub: ?hubclient.Hub,
    wake: Io.Event = .unset,
    running: std.atomic.Value(bool) = .init(true),
    // Sync status, guarded by `lock`.
    state: SyncState = .connecting,
    head: u64 = 0,
    events_connected: bool = false,
    reported: ?Reported = null,
    /// Attachment names to fetch from the hub, guarded by `dl_lock` (never
    /// taken while waiting for `lock`, so it is safe under `lock`).
    dl_lock: Io.Mutex = .init,
    downloads: std.ArrayList([]u8) = .empty,

    // ------------------------------------------------------------ output

    fn emit(self: *Daemon, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.out_lock.lockUncancelable(self.io);
        defer self.out_lock.unlock(self.io);
        self.stdout.writeAll(bytes) catch {};
        self.stdout.flush() catch {};
    }

    fn emitValue(self: *Daemon, value: anytype) void {
        const line = std.json.Stringify.valueAlloc(self.gpa, value, .{ .emit_null_optional_fields = false }) catch return;
        defer self.gpa.free(line);
        self.out_lock.lockUncancelable(self.io);
        defer self.out_lock.unlock(self.io);
        self.stdout.writeAll(line) catch {};
        self.stdout.writeAll("\n") catch {};
        self.stdout.flush() catch {};
    }

    fn emitError(self: *Daemon, id: ?i64, message: []const u8) void {
        if (id) |i| {
            self.emitValue(.{ .re = i, .ok = false, .@"error" = message });
        } else {
            self.emitValue(.{ .ev = "error", .@"error" = message });
        }
    }

    /// Emit a `sync` event if state, pending count or head changed. Caller holds `lock`.
    fn syncChangedLocked(self: *Daemon) void {
        const now: Reported = .{ .state = self.state, .pending = self.rep.pending(), .head = self.head };
        if (self.reported) |r| if (r.state == now.state and r.pending == now.pending and r.head == now.head) return;
        self.reported = now;
        self.emitValue(.{ .ev = "sync", .state = @tagName(now.state), .pending = now.pending, .head = now.head });
    }

    fn syncChanged(self: *Daemon) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.syncChangedLocked();
    }

    // ------------------------------------------------------------ replay

    pub fn begin(self: *Daemon, id: u64) !void {
        self.engine = try core.Engine.init(self.gpa, id);
        self.engine_ready = true;
    }

    pub fn ops(self: *Daemon, line: []const u8) !void {
        var discard: std.ArrayList(u8) = .empty;
        defer discard.deinit(self.gpa);
        self.engine.ingest(line, &discard) catch |err| {
            std.log.warn("replay: skipping ops line ({s})", .{@errorName(err)});
        };
    }

    // ------------------------------------------------------------ requests

    fn handleLine(self: *Daemon, line: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, line, .{}) catch {
            self.emitError(null, "request is not valid JSON");
            return;
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |o| o,
            else => return self.emitError(null, "request is not a JSON object"),
        };
        const id: ?i64 = if (object.get("id")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;
        const cmd = if (object.get("cmd")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";

        if (std.mem.eql(u8, cmd, "status")) return self.status(id);
        if (std.mem.eql(u8, cmd, "paste")) return self.doPaste(id);
        if (std.mem.eql(u8, cmd, "attach")) return self.doAttach(id, object);
        self.forward(line, id, std.mem.eql(u8, cmd, "hello"));
    }

    fn status(self: *Daemon, id: ?i64) void {
        self.lock.lockUncancelable(self.io);
        const state = self.state;
        const pending = self.rep.pending();
        const head = self.head;
        self.lock.unlock(self.io);
        self.emitValue(.{
            .re = id orelse 0,
            .ok = true,
            .sync = @tagName(state),
            .hub = if (self.hub) |h| h.base else "",
            .pending = pending,
            .head = head,
        });
    }

    fn forward(self: *Daemon, line: []const u8, id: ?i64, is_hello: bool) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        const queued = self.callEngine(line, &out, is_hello) catch |err| {
            return self.emitError(id, @errorName(err));
        };
        self.queueMissingAttachments(out.items);
        if (queued) self.wake.set(self.io);
    }

    /// Run one request through the engine, persist the ops it created, and
    /// write its output, all under `lock`, so replies and patch events leave
    /// in exactly the engine's order (patches carry `pseq`, edits `ack`).
    /// Returns whether new ops were queued for the hub.
    fn callEngine(self: *Daemon, line: []const u8, out: *std.ArrayList(u8), is_hello: bool) !bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const now_ms = Io.Clock.real.now(self.io).toMilliseconds();
        try self.engine.call(line, now_ms, out);
        if (is_hello) self.augmentHello(out) catch {};
        var queued = false;
        const new_ops = try self.engine.takeNewOps(self.gpa);
        defer self.gpa.free(new_ops);
        if (!isEmptyArray(new_ops)) {
            if (self.rep.recordLocal(new_ops)) {
                queued = true;
            } else |err| {
                // Applied in memory but not durable: say so loudly.
                std.log.err("cannot persist local ops: {s}", .{@errorName(err)});
                try out.appendSlice(self.gpa, "{\"ev\":\"error\",\"error\":\"cannot save the last edit to disk\"}\n");
            }
        }
        self.emit(out.items);
        if (queued) self.syncChangedLocked();
        return queued;
    }

    /// Add `data` and `attachments` (absolute, trailing slash: the QML preview's
    /// baseUrl) to the engine's hello reply.
    fn augmentHello(self: *Daemon, out: *std.ArrayList(u8)) !void {
        const end = std.mem.findScalar(u8, out.items, '\n') orelse out.items.len;
        const reply = out.items[0..end];
        if (reply.len < 2 or reply[reply.len - 1] != '}' or std.mem.find(u8, reply, "\"ok\":true") == null) return;
        const extra = try std.fmt.allocPrint(self.gpa, ",\"data\":{f},\"attachments\":{f},\"hub\":{f},\"daemon\":\"{s}\"", .{
            std.json.fmt(self.data_path, .{}),
            std.json.fmt(try std.fmt.allocPrint(self.gpa, "{s}/{s}/", .{ self.data_path, attachments.dir_name }), .{}),
            std.json.fmt(if (self.hub) |h| h.base else "", .{}),
            version,
        });
        defer self.gpa.free(extra);
        try out.insertSlice(self.gpa, end - 1, extra);
    }

    fn doPaste(self: *Daemon, id: ?i64) void {
        var fallback_client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer fallback_client.deinit();
        var p: paste.Paster = .{
            .gpa = self.gpa,
            .io = self.io,
            .att_dir = self.att_dir,
            .http = if (self.hub) |*h| &h.client else &fallback_client,
        };
        defer p.deinit();
        const md = p.paste() catch |err| return self.emitError(id, @errorName(err));
        defer self.gpa.free(md);
        if (p.stored.items.len > 0) {
            self.lock.lockUncancelable(self.io);
            for (p.stored.items) |name| self.rep.addUpload(name) catch {};
            self.lock.unlock(self.io);
            self.wake.set(self.io);
        }
        self.emitValue(.{ .re = id orelse 0, .ok = true, .ins = md });
    }

    /// `attach {path}`: copy a local file into the attachments and queue its
    /// upload; reply `{name: "attachments/<sha256>.<ext>"}` for use in markdown.
    fn doAttach(self: *Daemon, id: ?i64, object: std.json.ObjectMap) void {
        const path = if (object.get("path")) |v| switch (v) {
            .string => |str| str,
            else => return self.emitError(id, "attach: path must be a string"),
        } else return self.emitError(id, "attach: path is required");
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(attachments.max_bytes)) catch |err|
            return self.emitError(id, @errorName(err));
        defer self.gpa.free(bytes);
        const dot_ext = std.fs.path.extension(path);
        const ext = if (dot_ext.len > 1) dot_ext[1..] else attachments.sniffExt(bytes) orelse "bin";
        const name = attachments.store(self.io, self.att_dir, bytes, ext) catch |err| return self.emitError(id, @errorName(err));
        self.lock.lockUncancelable(self.io);
        self.rep.addUpload(name.slice()) catch {};
        self.lock.unlock(self.io);
        self.wake.set(self.io);
        var buf: [attachments.dir_name.len + 1 + name.buf.len]u8 = undefined;
        const ref = std.fmt.bufPrint(&buf, attachments.dir_name ++ "/{s}", .{name.slice()}) catch unreachable;
        self.emitValue(.{ .re = id orelse 0, .ok = true, .name = ref });
    }

    fn queueMissingAttachments(self: *Daemon, text: []const u8) void {
        const Ctx = struct {
            d: *Daemon,
            added: bool = false,
            fn found(ctx: *@This(), name: []const u8) void {
                if (attachmentExists(ctx.d, name)) return;
                ctx.d.dl_lock.lockUncancelable(ctx.d.io);
                defer ctx.d.dl_lock.unlock(ctx.d.io);
                for (ctx.d.downloads.items) |q| if (std.mem.eql(u8, q, name)) return;
                const copy = ctx.d.gpa.dupe(u8, name) catch return;
                ctx.d.downloads.append(ctx.d.gpa, copy) catch {
                    ctx.d.gpa.free(copy);
                    return;
                };
                ctx.added = true;
            }
        };
        if (self.hub == null) return;
        var ctx: Ctx = .{ .d = self };
        attachments.scan(text, &ctx, Ctx.found);
        if (ctx.added) self.wake.set(self.io);
    }

    // ------------------------------------------------------------ sync

    fn syncLoop(self: *Daemon) void {
        var backoff_ms: i64 = 0;
        while (self.running.load(.acquire)) {
            const wait_ms: i64 = if (backoff_ms > 0) backoff_ms else idle_poll_ms;
            self.wake.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(wait_ms), .clock = .awake } }) catch {};
            self.wake.reset();
            if (!self.running.load(.acquire)) return;
            // Let a burst of keystrokes land in one batch.
            self.io.sleep(.fromMilliseconds(push_debounce_ms), .awake) catch {};
            self.round() catch |err| {
                std.log.warn("sync: {s}", .{@errorName(err)});
                self.lock.lockUncancelable(self.io);
                self.state = .offline;
                self.syncChangedLocked();
                self.lock.unlock(self.io);
                backoff_ms = std.math.clamp(backoff_ms * 2, 1000, max_backoff_ms);
                continue;
            };
            backoff_ms = 0;
            self.lock.lockUncancelable(self.io);
            self.state = .online;
            self.syncChangedLocked();
            self.lock.unlock(self.io);
        }
    }

    fn round(self: *Daemon) !void {
        const hub = if (self.hub) |*h| h else return;
        try self.push(hub);
        try self.pull(hub);
        try self.uploads(hub);
        try self.fetchDownloads(hub);
    }

    fn push(self: *Daemon, hub: *hubclient.Hub) !void {
        while (true) {
            const body = blk: {
                self.lock.lockUncancelable(self.io);
                defer self.lock.unlock(self.io);
                const next = (try self.rep.nextBatch()) orelse return;
                break :blk try self.gpa.dupe(u8, next);
            };
            defer self.gpa.free(body);
            const response = try hub.send(.POST, "/api/batches", body, "application/json");
            defer response.deinit(self.gpa);
            switch (response.status) {
                200 => {
                    const parsed = std.json.parseFromSlice(struct { seq: u64, head: u64 }, self.gpa, response.body, .{}) catch return error.BadHubResponse;
                    defer parsed.deinit();
                    self.lock.lockUncancelable(self.io);
                    defer self.lock.unlock(self.io);
                    try self.rep.ackInflight();
                    self.head = @max(self.head, parsed.value.head);
                    self.syncChangedLocked();
                },
                409 => {
                    // The hub has a different history for our bseq sequence
                    // (e.g. its data was reset). Needs a human; keep the ops.
                    self.emitValue(.{ .ev = "error", .@"error" = "hub rejected our batch sequence (409); local edits are kept but not synced" });
                    return error.BatchSequenceConflict;
                },
                else => {
                    std.log.warn("hub rejected batch: {d} {s}", .{ response.status, response.body[0..@min(response.body.len, 200)] });
                    return error.HubRejectedBatch;
                },
            }
        }
    }

    fn pull(self: *Daemon, hub: *hubclient.Hub) !void {
        while (true) {
            self.lock.lockUncancelable(self.io);
            const cursor = self.rep.cursor;
            const own = self.rep.id;
            self.lock.unlock(self.io);

            var path_buf: [96]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "/api/batches?after={d}&limit={d}", .{ cursor, page_limit });
            const response = try hub.send(.GET, path, null, null);
            defer response.deinit(self.gpa);
            if (response.status != 200) return error.PullFailed;
            const head_raw = (try rawjson.field(self.gpa, response.body, "head")) orelse return error.BadHubResponse;
            const head = std.fmt.parseInt(u64, head_raw, 10) catch return error.BadHubResponse;
            const batches_raw = (try rawjson.field(self.gpa, response.body, "batches")) orelse return error.BadHubResponse;
            const batches = try rawjson.elements(self.gpa, batches_raw);
            defer self.gpa.free(batches);

            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.gpa);
            {
                self.lock.lockUncancelable(self.io);
                defer self.lock.unlock(self.io);
                if (head < cursor) {
                    // The hub knows less than we do (reset or a different hub).
                    self.emitValue(.{ .ev = "error", .@"error" = "hub head is behind this replica's cursor; not pulling" });
                    return error.HubBehindCursor;
                }
                self.head = head;
                for (batches) |batch| {
                    const seq_raw = (try rawjson.field(self.gpa, batch, "seq")) orelse return error.BadHubResponse;
                    const seq = std.fmt.parseInt(u64, seq_raw, 10) catch return error.BadHubResponse;
                    if (seq <= self.rep.cursor) continue;
                    const replica_raw = (try rawjson.field(self.gpa, batch, "replica")) orelse return error.BadHubResponse;
                    const from = std.fmt.parseInt(u64, std.mem.trim(u8, replica_raw, "\""), 16) catch return error.BadHubResponse;
                    const batch_ops = (try rawjson.field(self.gpa, batch, "ops")) orelse return error.BadHubResponse;
                    self.engine.ingest(batch_ops, &out) catch |err| {
                        std.log.err("ingest seq {d}: {s}", .{ seq, @errorName(err) });
                        return err;
                    };
                    if (from != own) try self.rep.recordRemote(batch_ops);
                    try self.rep.setCursor(seq);
                }
                // Under the lock: patch events keep their order relative to replies.
                self.emit(out.items);
                self.syncChangedLocked();
            }
            self.queueMissingAttachments(out.items);
            self.lock.lockUncancelable(self.io);
            const done = self.rep.cursor >= head or batches.len == 0;
            self.lock.unlock(self.io);
            if (done) return;
        }
    }

    fn uploads(self: *Daemon, hub: *hubclient.Hub) !void {
        while (true) {
            const name = blk: {
                self.lock.lockUncancelable(self.io);
                defer self.lock.unlock(self.io);
                if (self.rep.uploads.items.len == 0) return;
                break :blk try self.gpa.dupe(u8, self.rep.uploads.items[0]);
            };
            defer self.gpa.free(name);
            const bytes = self.att_dir.readFileAlloc(self.io, name, self.gpa, .limited(attachments.max_bytes)) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (bytes) |b| {
                defer self.gpa.free(b);
                try hub.putBlob(name, b);
            }
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            try self.rep.removeUpload(name);
        }
    }

    fn fetchDownloads(self: *Daemon, hub: *hubclient.Hub) !void {
        while (true) {
            const name = blk: {
                self.dl_lock.lockUncancelable(self.io);
                defer self.dl_lock.unlock(self.io);
                if (self.downloads.items.len == 0) return;
                break :blk self.downloads.orderedRemove(0);
            };
            defer self.gpa.free(name);
            const bytes = (hub.getBlob(name) catch |err| {
                std.log.warn("download {s}: {s}", .{ name, @errorName(err) });
                continue;
            }) orelse continue; // not uploaded yet; the next reference retries
            defer self.gpa.free(bytes);
            attachments.storeVerified(self.io, self.att_dir, name, bytes) catch |err| {
                std.log.warn("attachment {s}: {s}", .{ name, @errorName(err) });
                continue;
            };
            // Tell the UI so an open preview can reload the image.
            self.emitValue(.{ .ev = "attachment", .name = name });
        }
    }

    fn doorbellLoop(self: *Daemon) void {
        const hub = if (self.hub) |*h| h else return;
        var backoff_ms: i64 = 1000;
        while (self.running.load(.acquire)) {
            self.lock.lockUncancelable(self.io);
            const cursor = self.rep.cursor;
            self.lock.unlock(self.io);
            const Handler = struct {
                fn connected(d: *Daemon) void {
                    d.lock.lockUncancelable(d.io);
                    d.events_connected = true;
                    d.lock.unlock(d.io);
                    // Catch up on anything missed while disconnected.
                    d.wake.set(d.io);
                }
                fn head(d: *Daemon, h: u64) void {
                    d.lock.lockUncancelable(d.io);
                    const behind = h != d.rep.cursor;
                    d.lock.unlock(d.io);
                    if (behind) d.wake.set(d.io);
                }
            };
            if (hub.followEvents(cursor, self, Handler.connected, Handler.head)) {
                backoff_ms = 1000; // clean end at the stream's planned lifetime
                self.io.sleep(.fromMilliseconds(100), .awake) catch {};
            } else |err| {
                // ReadFailed included: a cut stream is just a reconnect. Back off
                // only while connecting fails; a stream that was up (and then cut,
                // e.g. by the server deadline) reconnects at once.
                self.lock.lockUncancelable(self.io);
                const was_connected = self.events_connected;
                self.events_connected = false;
                self.lock.unlock(self.io);
                if (was_connected) backoff_ms = 1000;
                const delay_ms: i64 = if (was_connected) 250 else backoff_ms;
                std.log.info("events: {s}; reconnecting in {d} ms", .{ @errorName(err), delay_ms });
                self.io.sleep(.fromMilliseconds(delay_ms), .awake) catch {};
                if (!was_connected) backoff_ms = @min(backoff_ms * 2, max_backoff_ms);
            }
        }
    }
};

fn isEmptyArray(json: []const u8) bool {
    const t = std.mem.trim(u8, json, " \t\r\n");
    if (t.len < 2 or t[0] != '[') return false;
    return std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n").len == 0;
}

// Local check used by queueMissingAttachments.
fn attachmentExists(d: *Daemon, name: []const u8) bool {
    return @import("../hub/blobs.zig").exists(d.io, d.att_dir, name);
}

const Options = struct {
    /// Null: not given on the command line (then the config file; else no hub).
    hub: ?[]const u8 = null,
    no_hub: bool = false,
    data: ?[]const u8 = null,
};

/// `config.json` in `$XDG_CONFIG_HOME/omajot` or `~/.config/omajot`; every field optional.
pub const Config = struct {
    hub: ?[]const u8 = null,
    data: ?[]const u8 = null,
};

pub fn configPath(gpa: Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| if (xdg.len > 0) return std.fs.path.join(gpa, &.{ xdg, "omajot", "config.json" });
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".config", "omajot", "config.json" });
}

/// A missing file is an empty config; a malformed one is an error.
pub fn readConfig(arena: Allocator, io: Io, path: []const u8) !Config {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(Config, arena, bytes, .{ .ignore_unknown_fields = true });
}

/// Expand a leading `~/` against HOME.
fn expandHome(gpa: Allocator, env: *std.process.Environ.Map, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = env.get("HOME") orelse return error.NoHome;
        return std.fs.path.join(gpa, &.{ home, path[2..] });
    }
    return gpa.dupe(u8, path);
}

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
        if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) return error.Help;
        if (std.mem.eql(u8, name, "--no-hub")) {
            options.no_hub = true;
            continue;
        }
        const v = value orelse blk: {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            break :blk args[i];
        };
        if (std.mem.eql(u8, name, "--hub")) {
            if (v.len == 0) options.no_hub = true else options.hub = v;
        } else if (std.mem.eql(u8, name, "--data")) {
            options.data = v;
        } else return error.UnknownOption;
    }
    return options;
}

fn defaultDataDir(gpa: Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| if (xdg.len > 0) return std.fs.path.join(gpa, &.{ xdg, "omajot" });
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".local", "share", "omajot" });
}

pub fn main(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const gpa = init.gpa;
    const options = parseOptions(args) catch |err| {
        if (err != error.Help) std.debug.print("omajot daemon: {s}\n", .{@errorName(err)});
        std.debug.print("{s}", .{usage});
        std.process.exit(if (err == error.Help) 0 else 2);
    };

    var config_arena: std.heap.ArenaAllocator = .init(gpa);
    defer config_arena.deinit();
    const config_path = try configPath(config_arena.allocator(), init.environ_map);
    const config = readConfig(config_arena.allocator(), io, config_path) catch |err| {
        std.debug.print("omajot daemon: cannot read {s}: {s}\n", .{ config_path, @errorName(err) });
        std.process.exit(2);
    };
    const hub_url: ?[]const u8 = if (options.no_hub) null else options.hub orelse config.hub;

    const data_rel = if (options.data orelse config.data) |d| try expandHome(gpa, init.environ_map, d) else try defaultDataDir(gpa, init.environ_map);
    defer gpa.free(data_rel);
    try Io.Dir.cwd().createDirPath(io, data_rel);
    var data_dir = try Io.Dir.cwd().openDir(io, data_rel, .{});
    defer data_dir.close(io);
    const data_path = try data_dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(data_path);
    try data_dir.createDirPath(io, attachments.dir_name);
    var att_dir = try data_dir.openDir(io, attachments.dir_name, .{});
    defer att_dir.close(io);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);

    const d = try gpa.create(Daemon);
    defer gpa.destroy(d);
    d.* = .{
        .gpa = gpa,
        .io = io,
        .stdout = &stdout_writer.interface,
        .data_path = data_path,
        .att_dir = att_dir,
        .hub = if (hub_url) |url| hubclient.Hub.init(gpa, io, url) else null,
    };
    d.rep = try replica.Replica.open(gpa, io, data_dir, d);
    std.log.info("omajot daemon {s}: replica {s}, data {s}, hub {s}", .{ version, &d.rep.idHex(), data_path, hub_url orelse "(none)" });
    if (d.hub == null) {
        d.state = .offline;
        if (!options.no_hub) std.log.info("no hub configured: notes stay on this machine. Set \"hub\" in {s} to sync.", .{config_path});
    }
    d.syncChanged();

    if (d.hub != null) {
        const sync_thread = try std.Thread.spawn(.{}, Daemon.syncLoop, .{d});
        sync_thread.detach();
        const bell_thread = try std.Thread.spawn(.{}, Daemon.doorbellLoop, .{d});
        bell_thread.detach();
        d.wake.set(io);
    }

    const line_buffer = try gpa.alloc(u8, max_line_bytes);
    defer gpa.free(line_buffer);
    var stdin_reader = Io.File.stdin().reader(io, line_buffer);
    const stdin = &stdin_reader.interface;
    while (true) {
        const line = stdin.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                d.emitError(null, "request line too long");
                _ = stdin.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            error.ReadFailed => break,
        } orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        d.handleLine(trimmed);
    }
    // stdin closed: the plugin is gone. Leave without joining the network
    // threads (they may sit in a blocking read); everything is on disk.
    d.running.store(false, .release);
    std.process.exit(0);
}

test {
    _ = replica;
    _ = attachments;
    _ = hubclient;
    _ = paste;
}

test "parseOptions" {
    const o = try parseOptions(&.{ "--hub", "http://x:1/", "--data=/tmp/d" });
    try std.testing.expectEqualStrings("http://x:1/", o.hub.?);
    try std.testing.expectEqualStrings("/tmp/d", o.data.?);
    try std.testing.expect((try parseOptions(&.{"--no-hub"})).no_hub);
    try std.testing.expect((try parseOptions(&.{ "--hub", "" })).no_hub);
    try std.testing.expect((try parseOptions(&.{})).hub == null);
}

test "readConfig: missing file is empty, fields parse, unknown fields ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const missing = try readConfig(arena.allocator(), io, "/nonexistent/omajot/config.json");
    try std.testing.expect(missing.hub == null and missing.data == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = "{\"hub\":\"https://h:1\",\"data\":\"~/n\",\"theme\":1}" });
    const path = try tmp.dir.realPathFileAlloc(io, "config.json", arena.allocator());
    const c = try readConfig(arena.allocator(), io, path);
    try std.testing.expectEqualStrings("https://h:1", c.hub.?);
    try std.testing.expectEqualStrings("~/n", c.data.?);
}

test "isEmptyArray" {
    try std.testing.expect(isEmptyArray("[]"));
    try std.testing.expect(isEmptyArray(" [ ] "));
    try std.testing.expect(!isEmptyArray("[1]"));
}
