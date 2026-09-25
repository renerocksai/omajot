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
