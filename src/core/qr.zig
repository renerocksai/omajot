//! QR codes for "open this on your phone": the hub URL shown by the CLI, the
//! hub, the plugin and the PWA. Encoding is qrgen.zig (byte mode, level M,
//! versions 1–10, no allocation); this file adds the two renderings omajot
//! needs. Pure: writers only, no std.Io.
const std = @import("std");
const qrgen = @import("qrgen.zig");

pub const QrCode = qrgen.QrCode;
pub const Error = qrgen.Error;
pub const encode = qrgen.encode;

/// Quiet zone around the code, in modules (the spec's recommendation).
pub const quiet = 4;

fn dark(code: *const QrCode, x: isize, y: isize) bool {
    if (x < 0 or y < 0) return false;
    const size: isize = @intCast(code.size);
    if (x >= size or y >= size) return false;
    return code.get(@intCast(x), @intCast(y));
}

/// Two modules per character cell with half blocks, black on bright white
/// whatever the terminal theme, so phones scan it from a dark terminal too.
pub fn renderTerminal(out: *std.Io.Writer, code: *const QrCode) std.Io.Writer.Error!void {
    const total: usize = code.size + 2 * quiet;
    var row: usize = 0;
    while (row < total) : (row += 2) {
        try out.writeAll("\x1b[30;107m");
        for (0..total) |col| {
            const x = @as(isize, @intCast(col)) - quiet;
            const top = dark(code, x, @as(isize, @intCast(row)) - quiet);
            const bottom = row + 1 < total and dark(code, x, @as(isize, @intCast(row + 1)) - quiet);
            try out.writeAll(if (top and bottom) "\u{2588}" else if (top) "\u{2580}" else if (bottom) "\u{2584}" else " ");
        }
        try out.writeAll("\x1b[0m\n");
    }
}

/// `"size":N,"rows":["0101…",…]`: one string per row, `1` = dark, no quiet
/// zone (the UI adds its own margin). For the §1 `qr` reply.
pub fn writeRowsJson(out: *std.Io.Writer, code: *const QrCode) std.Io.Writer.Error!void {
    try out.print("\"size\":{d},\"rows\":[", .{code.size});
    for (0..code.size) |y| {
        if (y > 0) try out.writeByte(',');
        try out.writeByte('"');
        for (0..code.size) |x| try out.writeByte(if (code.get(x, y)) '1' else '0');
        try out.writeByte('"');
    }
    try out.writeByte(']');
}

test "rows JSON is square and matches the code" {
    const code = try encode("https://host.tailnet.ts.net:8443");
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRowsJson(&w, &code);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const object = try std.fmt.allocPrint(arena.allocator(), "{{{s}}}", .{w.buffered()});
    const value = try std.json.parseFromSliceLeaky(struct { size: usize, rows: []const []const u8 }, arena.allocator(), object, .{});
    try std.testing.expectEqual(code.size, value.size);
    try std.testing.expectEqual(code.size, value.rows.len);
    for (value.rows, 0..) |row, y| {
        try std.testing.expectEqual(code.size, row.len);
        for (row, 0..) |c, x| try std.testing.expectEqual(code.get(x, y), c == '1');
    }
    // Finder pattern: the top row of the top-left corner is dark.
    try std.testing.expectEqualStrings("1111111", value.rows[0][0..7]);
}

test "terminal rendering has one line per two module rows" {
    const code = try encode("https://x.example");
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderTerminal(&w, &code);
    const lines = std.mem.count(u8, w.buffered(), "\n");
    try std.testing.expectEqual((code.size + 2 * quiet + 1) / 2, lines);
}
