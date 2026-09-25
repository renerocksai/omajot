//! Which text editor `omajot edit` (and the TUI) opens, and how.
//!
//! Order: $VISUAL, then $EDITOR, then `vi`. The value is a shell command line
//! and can have arguments (`code --wait`, `nvim -u NONE`), so it runs as
//! `sh -c '<editor> "$1"' omajot <file>`: the shell splits the words, and the
//! file name stays one argument.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Source = enum { visual, editor, fallback };

pub const Choice = struct {
    /// Shell command line, e.g. "code --wait".
    command: []const u8,
    source: Source,
};

pub const fallback = "vi";

/// The editor to use. error.NoEditor when neither $VISUAL nor $EDITOR is set
/// and `vi` is not on PATH.
pub fn choose(io: Io, env: *const std.process.Environ.Map) error{NoEditor}!Choice {
    if (env.get("VISUAL")) |v| if (std.mem.trim(u8, v, " \t").len > 0) return .{ .command = v, .source = .visual };
    if (env.get("EDITOR")) |v| if (std.mem.trim(u8, v, " \t").len > 0) return .{ .command = v, .source = .editor };
    if (onPath(io, env, fallback)) return .{ .command = fallback, .source = .fallback };
    return error.NoEditor;
}

pub const no_editor_message = "no text editor: set $EDITOR (for example: export EDITOR=nvim), or install vi";

fn onPath(io: Io, env: *const std.process.Environ.Map, name: []const u8) bool {
    const path = env.get("PATH") orelse return false;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    var buf: [4096]u8 = undefined;
    while (it.next()) |dir| {
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        Io.Dir.cwd().access(io, full, .{ .execute = true }) catch continue;
        return true;
    }
    return false;
}

/// The argv that opens `file` in `choice`. Allocates from `arena`.
pub fn argv(arena: Allocator, choice: Choice, file: []const u8) ![]const []const u8 {
    if (builtin.os.tag == .windows) {
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, choice.command, ' ');
        while (it.next()) |w| try list.append(arena, w);
        try list.append(arena, file);
        return list.items;
    }
    const script = try std.fmt.allocPrint(arena, "{s} \"$1\"", .{choice.command});
    return arena.dupe([]const u8, &.{ "sh", "-c", script, "omajot", file });
}

/// Start the editor on `file` with the terminal (stdin/stdout/stderr inherited).
pub fn spawn(arena: Allocator, io: Io, choice: Choice, file: []const u8) !std.process.Child {
    return std.process.spawn(io, .{ .argv = try argv(arena, choice, file) });
}

const testing = std.testing;

test "choose: VISUAL, then EDITOR; the command keeps its arguments" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "");
    try env.put("EDITOR", "nvim -u NONE");
    try testing.expectEqualStrings("nvim -u NONE", (try choose(testing.io, &env)).command);
    try env.put("VISUAL", "code --wait");
    const c = try choose(testing.io, &env);
    try testing.expectEqual(Source.visual, c.source);
    _ = env.swapRemove("VISUAL");
    _ = env.swapRemove("EDITOR");
    try testing.expectError(error.NoEditor, choose(testing.io, &env));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    if (builtin.os.tag != .windows) {
        const a = try argv(arena.allocator(), .{ .command = "code --wait", .source = .visual }, "/tmp/a b.md");
        try testing.expectEqualStrings("code --wait \"$1\"", a[2]);
        try testing.expectEqualStrings("/tmp/a b.md", a[4]);
    }
}
