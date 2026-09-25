//! Spike 0b: std.http.Client over TLS to the tailnet hub, then an SSE stream
//! read line by line as it arrives. Usage: client [base-url] [seconds]
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    const base = args.next() orelse "https://laptop.your-tailnet.ts.net:8443";
    const seconds = if (args.next()) |raw| try std.fmt.parseInt(u32, raw, 10) else 20;

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();

    // 1. Plain GET over TLS.
    var url_buffer: [256]u8 = undefined;
    const t0 = std.Io.Clock.awake.now(io);
    {
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/api/whoami", .{base});
        var body: std.Io.Writer.Allocating = .init(init.gpa);
        defer body.deinit();
        const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
        const ms = @divTrunc(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds, std.time.ns_per_ms);
        std.debug.print("whoami: status={d} in {d} ms (includes CA bundle scan + TLS)\n  {s}\n", .{ @intFromEnum(result.status), ms, body.written() });
    }

    // 2. SSE stream, printed per line with a timestamp relative to start.
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/api/events", .{base});
    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .extra_headers = &.{.{ .name = "Accept", .value = "text/event-stream" }},
    });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    std.debug.print("events: status={d} content-type={s}\n", .{ @intFromEnum(response.head.status), response.head.content_type orelse "?" });

    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(seconds));
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
        const line = reader.takeDelimiter('\n') catch |err| {
            std.debug.print("stream error: {s}\n", .{@errorName(err)});
            break;
        } orelse {
            std.debug.print("[{d:>6} ms] <end of stream>\n", .{@divTrunc(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds, std.time.ns_per_ms)});
            break;
        };
        const ms = @divTrunc(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds, std.time.ns_per_ms);
        std.debug.print("[{d:>6} ms] {s}\n", .{ ms, line });
    }
}
