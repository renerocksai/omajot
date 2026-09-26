//! Colours: the current Omarchy theme's colors.toml when there is one, else a
//! built-in dark palette. Omarchy writes semantic names (accent, selection,
//! muted, background, …) to ~/.local/state/omarchy/current/theme/colors.toml.
//! With NO_COLOR set (https://no-color.org), the terminal's own colours only:
//! the selection is then reverse video.
const std = @import("std");
const vaxis = @import("vaxis");

pub const Theme = struct {
    source: []const u8 = "built-in",
    bg: [3]u8 = .{ 0x16, 0x1a, 0x20 },
    bg_side: [3]u8 = .{ 0x0f, 0x13, 0x18 },
    bg_code: [3]u8 = .{ 0x22, 0x28, 0x31 },
    fg: [3]u8 = .{ 0xee, 0xf2, 0xf6 },
    muted: [3]u8 = .{ 0x98, 0xa1, 0xad },
    border: [3]u8 = .{ 0x3a, 0x44, 0x52 },
    accent: [3]u8 = .{ 0xff, 0xd6, 0x0a },
    selection: [3]u8 = .{ 0x5a, 0x4a, 0x12 },
    ok: [3]u8 = .{ 0x34, 0xc7, 0x59 },
    warn: [3]u8 = .{ 0xff, 0x6b, 0x5b },
    /// NO_COLOR: every colour is the terminal default.
    mono: bool = false,

    pub fn c(t: Theme, rgb: [3]u8) vaxis.Color {
        return if (t.mono) .default else .{ .rgb = rgb };
    }
};

fn hex(s: []const u8) ?[3]u8 {
    const t = std.mem.trim(u8, s, " \t\"'#");
    if (t.len != 6) return null;
    var out: [3]u8 = undefined;
    for (0..3) |i| out[i] = std.fmt.parseInt(u8, t[i * 2 .. i * 2 + 2], 16) catch return null;
    return out;
}

/// `key = "#rrggbb"` lines; everything else is ignored.
pub fn fromColorsToml(text: []const u8, source: []const u8) Theme {
    var t: Theme = .{ .source = source };
    var have_selection = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = hex(line[eq + 1 ..]) orelse continue;
        if (std.mem.eql(u8, key, "background")) t.bg = val;
        if (std.mem.eql(u8, key, "dark_background")) t.bg_side = val;
        if (std.mem.eql(u8, key, "lighter_background")) t.bg_code = val;
        if (std.mem.eql(u8, key, "foreground")) t.fg = val;
        if (std.mem.eql(u8, key, "dark_foreground")) t.muted = val;
        if (std.mem.eql(u8, key, "muted")) t.border = val;
        if (std.mem.eql(u8, key, "accent")) t.accent = val;
        if (std.mem.eql(u8, key, "green")) t.ok = val;
        if (std.mem.eql(u8, key, "red")) t.warn = val;
        if (std.mem.eql(u8, key, "selection")) {
            t.selection = val;
            have_selection = true;
        }
    }
    if (!have_selection) t.selection = t.bg_code;
    return t;
}

pub fn load(io: std.Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map) Theme {
    if (env.get("NO_COLOR")) |v| if (v.len > 0) return .{ .source = "NO_COLOR", .mono = true };
    const home = env.get("HOME") orelse return .{};
    const path = std.fs.path.join(arena, &.{ home, ".local/state/omarchy/current/theme/colors.toml" }) catch return .{};
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return .{};
    return fromColorsToml(text, "Omarchy theme");
}

test "colors.toml" {
    const t = fromColorsToml("mode = \"dark\"\naccent = \"#8bc9eb\"\nselection = \"#243d56\"\nbackground = \"#16242d\"\n", "x");
    try std.testing.expectEqual([3]u8{ 0x8b, 0xc9, 0xeb }, t.accent);
    try std.testing.expectEqual([3]u8{ 0x24, 0x3d, 0x56 }, t.selection);
    try std.testing.expectEqual([3]u8{ 0x16, 0x24, 0x2d }, t.bg);
}

test "NO_COLOR" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("NO_COLOR", "1");
    const t = load(std.testing.io, arena.allocator(), &env);
    try std.testing.expect(t.mono);
    try std.testing.expectEqual(vaxis.Color.default, t.c(t.accent));
}
