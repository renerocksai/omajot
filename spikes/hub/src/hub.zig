//! Spike 0a: a throwaway omajot hub on baz. In-memory op log, SSE doorbell,
//! identity echo, and a self-reporting browser test page. Not production code.
const std = @import("std");
const web = @import("baz");

const max_ops = 4096;
const max_op_bytes = 1024;
const max_subscribers = 32;

const Subscription = struct {
    active: std.atomic.Value(bool) = .init(false),
    notification: web.continuation.Notification = undefined,
};

const Shared = struct {
    busy: std.atomic.Value(bool) = .init(false),
    head: std.atomic.Value(u64) = .init(0),
    ops: [max_ops][max_op_bytes]u8 = undefined,
    op_lens: [max_ops]u16 = @splat(0),
    subscriptions: [max_subscribers]Subscription = @splat(.{}),
    reports_path: []const u8,
    streams_started: std.atomic.Value(u64) = .init(0),
};

const Application = web.App(Shared);
const Context = Application.Context;
const Step = web.continuation.Step;

const State = struct {
    cursor: u64 = 0,
    subscription: ?u8 = null,

    pub fn deinit(self: *State, ctx: *Context) void {
        if (self.subscription) |slot| {
            ctx.shared.subscriptions[slot].active.store(false, .release);
            self.subscription = null;
        }
    }
};

fn page(ctx: *Context) !void {
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.borrowBody(200, "text/html; charset=utf-8", @embedFile("test.html"));
}

fn whoami(ctx: *Context) !void {
    const login = ctx.request.header("Tailscale-User-Login");
    const name = ctx.request.header("Tailscale-User-Name");
    const node = ctx.request.header("Tailscale-Headers-Info");
    const forwarded = ctx.request.header("X-Forwarded-For");
    try ctx.response.header("Cache-Control", "no-store");
    try ctx.response.jsonValue(200, .{
        .tailscale_user_login = login,
        .tailscale_user_name = name,
        .tailscale_headers_info = node,
        .x_forwarded_for = forwarded,
        .head = ctx.shared.head.load(.acquire),
    });
}

fn postOps(ctx: *Context) !void {
    var buffer: [max_op_bytes]u8 = undefined;
    const body = ctx.request.body().copyTo(&buffer) catch return ctx.response.text(413, "op too large");
    var notifications: [max_subscribers]web.continuation.Notification = undefined;
    var count: usize = 0;
    const head = blk: {
        if (ctx.shared.busy.swap(true, .acquire)) return ctx.response.text(503, "busy");
        defer ctx.shared.busy.store(false, .release);
        const current = ctx.shared.head.load(.acquire);
        if (current >= max_ops) return ctx.response.text(507, "spike log full");
        @memcpy(ctx.shared.ops[current][0..body.len], body);
        ctx.shared.op_lens[current] = @intCast(body.len);
        ctx.shared.head.store(current + 1, .release);
        for (&ctx.shared.subscriptions) |*subscription| {
            if (!subscription.active.load(.acquire)) continue;
            notifications[count] = subscription.notification;
            count += 1;
        }
        break :blk current + 1;
    };
    // Signal after releasing the guard, as in baz's jobs example.
    for (notifications[0..count]) |notification| _ = notification.signal();
    try ctx.response.jsonValue(200, .{ .head = head, .signalled = count });
}

fn getOps(ctx: *Context) !void {
    const query = ctx.request.query() catch return ctx.response.text(400, "bad query");
    const after = if (query.firstRaw("after")) |raw| std.fmt.parseInt(u64, raw.value_raw, 10) catch return ctx.response.text(400, "bad after") else 0;
    const head = ctx.shared.head.load(.acquire);
    var out = try ctx.response.stream(200, "application/json", .{});
    try out.writeAll("{\"ops\":[");
    var i = after;
    while (i < head and i < after + 64) : (i += 1) {
        if (i != after) try out.writeAll(",");
        try out.print("{{\"seq\":{d},\"len\":{d}}}", .{ i + 1, ctx.shared.op_lens[i] });
    }
    try out.print("],\"head\":{d}}}", .{head});
    try out.finish();
}

fn report(ctx: *Context) !void {
    var buffer: [8192]u8 = undefined;
    const body = ctx.request.body().copyTo(&buffer) catch return ctx.response.text(413, "report too large");
    const io = ctx.app.io;
    const file = try std.Io.Dir.cwd().createFile(io, ctx.shared.reports_path, .{ .truncate = false });
    defer file.close(io);
    const end = try file.length(io);
    var line: [8300]u8 = undefined;
    const ua = ctx.request.header("User-Agent") orelse "?";
    const text = std.fmt.bufPrint(&line, "{s}\n", .{body}) catch body;
    _ = ua;
    try file.writePositionalAll(io, text, end);
    std.debug.print("REPORT {s}\n", .{body});
    try ctx.response.text(200, "recorded");
}

fn lastEventId(request: web.Request) !u64 {
    const raw = request.header("Last-Event-ID") orelse return 0;
    return std.fmt.parseInt(u64, raw, 10);
}

fn startEvents(ctx: *Context, state: *State) !Step {
    state.cursor = lastEventId(ctx.request) catch {
        try ctx.response.text(400, "bad Last-Event-ID");
        return .finish;
    };
    if (state.cursor > ctx.shared.head.load(.acquire)) {
        try ctx.response.text(409, "cursor ahead of head");
        return .finish;
    }
    {
        if (ctx.shared.busy.swap(true, .acquire)) {
            try ctx.response.text(503, "busy");
            return .finish;
        }
        defer ctx.shared.busy.store(false, .release);
        for (&ctx.shared.subscriptions, 0..) |*subscription, index| {
            if (subscription.active.load(.acquire)) continue;
            subscription.notification = try ctx.notification();
            subscription.active.store(true, .release);
            state.subscription = @intCast(index);
            break;
        }
    }
    if (state.subscription == null) {
        try ctx.response.text(503, "subscriber slots full");
        return .finish;
    }
    const n = ctx.shared.streams_started.fetchAdd(1, .monotonic) + 1;
    std.debug.print("SSE start #{d} Last-Event-ID={d} head={d}\n", .{ n, state.cursor, ctx.shared.head.load(.acquire) });
    try ctx.response.header("Cache-Control", "no-store");
    var out = try ctx.response.snapshot(200, web.sse.content_type, .{});
    // Tell the browser to reconnect quickly after the server deadline closes the stream.
    try web.sse.write(out.writer(), .{ .event = "hello", .data = "{}", .retry_ms = 1000 });
    return .flush;
}

fn resumeEvents(ctx: *Context, state: *State, event: web.continuation.Event) !Step {
    const head = ctx.shared.head.load(.acquire);
    if (head > state.cursor) {
        var id_buffer: [20]u8 = undefined;
        var data_buffer: [48]u8 = undefined;
        var out = try ctx.response.resumeSnapshot();
        const id = try std.fmt.bufPrint(&id_buffer, "{d}", .{head});
        const data = try std.fmt.bufPrint(&data_buffer, "{{\"head\":{d}}}", .{head});
        try web.sse.write(out.writer(), .{ .event = "head", .id = id, .data = data });
        state.cursor = head;
        return .flush;
    }
    if (event == .timer) {
        var out = try ctx.response.resumeSnapshot();
        try web.sse.heartbeat(out.writer());
        return .flush;
    }
    return .{ .await_notification = 3 * std.time.ns_per_s };
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8787;
    var timeout_ms: u32 = 15000;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) port = try std.fmt.parseInt(u16, arg[7..], 10);
        if (std.mem.startsWith(u8, arg, "--timeout-ms=")) timeout_ms = try std.fmt.parseInt(u32, arg[13..], 10);
    }
    const shared = try init.gpa.create(Shared);
    defer init.gpa.destroy(shared);
    shared.* = .{ .reports_path = "reports.log" };

    const app = try Application.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .shared = shared,
        .server = .{
            .port = port,
            .bind_address = .{ 127, 0, 0, 1 },
            .execution = .workers,
            .workers = 2,
            .connections = 64,
            .shards = 1,
            .timeout_ms = timeout_ms,
            .max_body = 16 * 1024,
            .shutdown_ms = 1000,
        },
        .response = .{ .body_bytes = 8192 },
        .max_continuations = max_subscribers,
    });
    defer app.deinit();
    try app.route("GET", "/", page);
    try app.route("GET", "/api/whoami", whoami);
    try app.route("POST", "/api/ops", postOps);
    try app.route("GET", "/api/ops", getOps);
    try app.route("POST", "/api/report", report);
    try app.routeContinuation("GET", "/api/events", State, startEvents, resumeEvents, .{});

    try app.start();
    std.debug.print("READY port={d} backend={s} timeout_ms={d}\n", .{ app.port(), web.backend_name, timeout_ms });
    try app.run();
}
