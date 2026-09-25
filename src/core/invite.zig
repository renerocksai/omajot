//! The invitation shown wherever omajot shows a QR code: how to run your own
//! hub and reach it from a phone with Tailscale. One source for the CLI, the
//! hub, the plugin and the web app (the UIs get it through the engine).
//! Simplified Technical English: short sentences, one step per sentence.
const std = @import("std");

pub const title = "Use omajot on your phone:";

pub const steps = [_][]const u8{
    "Run `omajot hub` on a computer that is always on.",
    "Install Tailscale on that computer and on your phone. Tailscale is free for personal use: https://tailscale.com",
    "On the hub computer, run `tailscale serve --bg --https=8443 http://127.0.0.1:8787`.",
    "Put the hub URL in ~/.config/omajot/config.json, for example {\"hub\": \"https://your-mac.your-tailnet.ts.net:8443\"}.",
};

/// Shown instead of a QR code when the URL only works on this computer.
pub const loopback_note = "This hub address works only on this computer. A phone cannot open it.";

/// True when `url` points at this computer (localhost, 127.0.0.0/8, ::1,
/// 0.0.0.0): a QR code of it is useless on a phone.
pub fn isLoopback(url: []const u8) bool {
    const scheme_end = std.mem.find(u8, url, "://") orelse return false;
    var host = url[scheme_end + 3 ..];
    if (std.mem.findAny(u8, host, "/?#")) |end| host = host[0..end];
    if (std.mem.findScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (std.mem.startsWith(u8, host, "[")) {
        const close = std.mem.findScalar(u8, host, ']') orelse return false;
        const v6 = host[1..close];
        return std.mem.eql(u8, v6, "::1") or std.mem.eql(u8, v6, "::");
    }
    if (std.mem.findScalar(u8, host, ':')) |colon| host = host[0..colon];
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.endsWith(u8, host, ".localhost") or
        std.mem.startsWith(u8, host, "127.") or std.mem.eql(u8, host, "0.0.0.0");
}

/// Under a QR code: the phone still needs Tailscale to open the hub URL.
pub const footer = "Your phone needs Tailscale. It is free for personal use: https://tailscale.com/download";

/// The title and numbered steps as plain text lines.
pub fn writeText(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("{s}\n", .{title});
    for (steps, 1..) |step, i| try out.print("  {d}. {s}\n", .{ i, step });
}

/// `"title":…,"steps":[…],"footer":…` for the §1 `invite` reply.
pub fn writeJson(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.writeAll("\"title\":");
    try std.json.Stringify.encodeJsonString(title, .{}, out);
    try out.writeAll(",\"steps\":[");
    for (steps, 0..) |step, i| {
        if (i > 0) try out.writeByte(',');
        try std.json.Stringify.encodeJsonString(step, .{}, out);
    }
    try out.writeAll("],\"footer\":");
    try std.json.Stringify.encodeJsonString(footer, .{}, out);
}

test "isLoopback" {
    for ([_][]const u8{ "http://127.0.0.1:8797", "http://localhost:8787/", "https://LOCALHOST", "http://[::1]:8787", "http://0.0.0.0:1", "http://127.1.2.3", "http://x.localhost" }) |u|
        try std.testing.expect(isLoopback(u));
    for ([_][]const u8{ "https://your-mac.your-tailnet.ts.net:8443", "http://100.64.0.1:8787", "https://localhost.example.com", "not a url" }) |u|
        try std.testing.expect(!isLoopback(u));
}

test "invitation JSON parses and keeps every step" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeByte('{');
    try writeJson(&w);
    try w.writeByte('}');
    const parsed = try std.json.parseFromSlice(struct { title: []const u8, steps: []const []const u8, footer: []const u8 }, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(steps.len, parsed.value.steps.len);
    try std.testing.expectEqualStrings(steps[3], parsed.value.steps[3]);
}
