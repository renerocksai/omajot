//! The hub's public URL, as `tailscale serve` publishes it: the HTTPS entry
//! whose handler proxies to this hub's loopback port.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Ask `tailscale serve status --json`. Null when tailscale is missing, not
/// serving this port, or answers something unexpected: the URL is a nicety.
pub fn detect(gpa: Allocator, io: Io, port: u16) ?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "tailscale", "serve", "status", "--json" },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return null;
    return fromServeStatus(gpa, result.stdout, port) catch null;
}

/// `"Web": {"host:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8787"}}}}`
/// → `https://host` (port 443 omitted) or `https://host:8443`.
pub fn fromServeStatus(gpa: Allocator, json: []const u8, port: u16) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const web = switch (root.get("Web") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    var suffix_buf: [16]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&suffix_buf, ":{d}", .{port});
    var it = web.iterator();
    while (it.next()) |entry| {
        const handlers = switch (entry.value_ptr.*) {
            .object => |o| switch (o.get("Handlers") orelse continue) {
                .object => |h| h,
                else => continue,
            },
            else => continue,
        };
        var hit = handlers.iterator();
        while (hit.next()) |handler| {
            const proxy = switch (handler.value_ptr.*) {
                .object => |o| switch (o.get("Proxy") orelse continue) {
                    .string => |s| s,
                    else => continue,
                },
                else => continue,
            };
            const target = std.mem.trimEnd(u8, proxy, "/");
            if (!std.mem.endsWith(u8, target, suffix)) continue;
            if (!std.mem.startsWith(u8, target, "http://127.0.0.1") and !std.mem.startsWith(u8, target, "http://localhost")) continue;
            const host_port = entry.key_ptr.*;
            if (std.mem.endsWith(u8, host_port, ":443"))
                return try std.fmt.allocPrint(gpa, "https://{s}", .{host_port[0 .. host_port.len - 4]});
            return try std.fmt.allocPrint(gpa, "https://{s}", .{host_port});
        }
    }
    return null;
}

test "fromServeStatus finds the entry that proxies to this port" {
    const gpa = std.testing.allocator;
    const status =
        \\{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},
        \\ "Web":{"m3.tail.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:18789"}}},
        \\        "m3.tail.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}
    ;
    const url = (try fromServeStatus(gpa, status, 8787)).?;
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://m3.tail.ts.net:8443", url);
    const other = (try fromServeStatus(gpa, status, 18789)).?;
    defer gpa.free(other);
    try std.testing.expectEqualStrings("https://m3.tail.ts.net", other);
    try std.testing.expect((try fromServeStatus(gpa, status, 9999)) == null);
    try std.testing.expect((try fromServeStatus(gpa, "{}", 8787)) == null);
}
