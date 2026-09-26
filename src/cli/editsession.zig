//! One round trip through the user's text editor, shared by `omajot edit` and
//! `omajot tui`. The note goes to a private file; while the editor runs, a
//! watcher applies every save with `put`, based on the text of the previous
//! save, so the daemon merges changes made elsewhere in the meantime
//! (docs/PROTOCOL.md §1, `put` with `base`). The file goes away at the end,
//! unless a save could not be applied.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const client = @import("client.zig");
const editor = @import("editor.zig");

pub const max_text_bytes: usize = 15 << 20;

pub const Session = struct {
    gpa: Allocator,
    io: Io,
    c: *client.Client,
    note: []u8,
    dir: []u8,
    file: []u8,
    /// What the editor last saved (and was applied).
    last: []u8,
    mtime: i96 = 0,
    size: u64 = 0,
    saves: usize = 0,
    /// Why a save could not be applied; the file then stays.
    failed: ?[]u8 = null,
    stop: std.atomic.Value(bool) = .init(false),

    /// Write `text` to `<private dir>/<title>.md`. The private directory is in
    /// $XDG_RUNTIME_DIR, else $TMPDIR, else /tmp.
    pub fn begin(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, c: *client.Client, note: []const u8, title: []const u8, text: []const u8) !*Session {
        const base = env.get("XDG_RUNTIME_DIR") orelse env.get("TMPDIR") orelse "/tmp";
        var rnd: [4]u8 = undefined;
        io.random(&rnd);
        const dir = try std.fmt.allocPrint(gpa, "{s}/omajot-edit-{x}", .{ std.mem.trimEnd(u8, base, "/"), std.mem.readInt(u32, &rnd, .little) });
        errdefer gpa.free(dir);
        try Io.Dir.cwd().createDir(io, dir, private(0o700));
        errdefer Io.Dir.cwd().deleteTree(io, dir) catch {};
        var name_arena: std.heap.ArenaAllocator = .init(gpa);
        defer name_arena.deinit();
        const file = try std.fmt.allocPrint(gpa, "{s}/{s}.md", .{ dir, try safeName(name_arena.allocator(), title) });
        errdefer gpa.free(file);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = text, .flags = .{ .permissions = private(0o600) } });

        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        const note_copy = try gpa.dupe(u8, note);
        errdefer gpa.free(note_copy);
        s.* = .{ .gpa = gpa, .io = io, .c = c, .note = note_copy, .dir = dir, .file = file, .last = try gpa.dupe(u8, text) };
        if (Io.Dir.cwd().statFile(io, file, .{})) |st| {
            s.mtime = st.mtime.nanoseconds;
            s.size = st.size;
        } else |_| {}
        return s;
    }

    /// Remove the file (kept when a save failed, so no text is lost).
    pub fn deinit(s: *Session) void {
        if (s.failed == null) Io.Dir.cwd().deleteTree(s.io, s.dir) catch {};
        if (s.failed) |f| s.gpa.free(f);
        s.gpa.free(s.last);
        s.gpa.free(s.file);
        s.gpa.free(s.dir);
        s.gpa.free(s.note);
        s.gpa.destroy(s);
    }

    /// Run the editor until it exits, applying saves as they happen. Returns
    /// its exit code (255: killed by a signal). An error: it did not start.
    pub fn run(s: *Session, arena: Allocator, choice: editor.Choice) !u8 {
        var child = try editor.spawn(arena, s.io, choice, s.file);
        const watcher = try std.Thread.spawn(.{}, loop, .{s});
        const term = child.wait(s.io) catch null;
        s.stop.store(true, .release);
        watcher.join();
        // The last save, if the watcher did not see it yet.
        s.mtime = 0;
        s.check() catch {};
        return if (term) |t| switch (t) {
            .exited => |code| code,
            else => 255,
        } else 255;
    }

    fn check(s: *Session) !void {
        const io = s.io;
        const st = Io.Dir.cwd().statFile(io, s.file, .{}) catch return; // mid-save rename
        if (st.mtime.nanoseconds == s.mtime and st.size == s.size) return;
        // Let the editor finish writing: read only a file that stays the same for 100 ms.
        io.sleep(.fromMilliseconds(100), .awake) catch {};
        const again = Io.Dir.cwd().statFile(io, s.file, .{}) catch return;
        if (again.mtime.nanoseconds != st.mtime.nanoseconds or again.size != st.size) return;
        const now_text = Io.Dir.cwd().readFileAlloc(io, s.file, s.gpa, .limited(max_text_bytes)) catch return;
        s.mtime = st.mtime.nanoseconds;
        s.size = st.size;
        if (std.mem.eql(u8, now_text, s.last)) {
            s.gpa.free(now_text);
            return;
        }
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        _ = s.c.call(arena_state.allocator(), "put", .{ .note = s.note, .base = s.last, .text = now_text }) catch |err| {
            s.gpa.free(now_text);
            if (s.failed == null) s.failed = s.gpa.dupe(u8, if (err == error.Refused) s.c.last_error else @errorName(err)) catch null;
            return err;
        };
        s.gpa.free(s.last);
        s.last = now_text;
        s.saves += 1;
    }

    fn loop(s: *Session) void {
        while (!s.stop.load(.acquire)) {
            s.io.sleep(.fromMilliseconds(250), .awake) catch {};
            s.check() catch {};
        }
    }
};

/// A file name from a note title: no path or control characters, at most
/// 100 bytes, never a name Windows reserves.
pub fn safeName(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |b| {
        const bad = b < 0x20 or b == 0x7f or std.mem.findScalar(u8, "/\\:*?\"<>|", b) != null;
        if (bad) {
            if (out.items.len == 0 or out.items[out.items.len - 1] != '-') try out.append(arena, '-');
        } else try out.append(arena, b);
    }
    var name: []const u8 = std.mem.trim(u8, out.items, " .-");
    // At most 100 bytes, cut at a UTF-8 boundary.
    if (name.len > 100) {
        var cut: usize = 100;
        while (cut > 0 and (name[cut] & 0xC0) == 0x80) cut -= 1;
        name = std.mem.trimEnd(u8, name[0..cut], " .");
    }
    if (name.len == 0) return "Untitled";
    // Names Windows reserves.
    const reserved = [_][]const u8{ "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9" };
    const stem = name[0 .. std.mem.findScalar(u8, name, '.') orelse name.len];
    for (reserved) |r| if (std.ascii.eqlIgnoreCase(stem, r)) return std.fmt.allocPrint(arena, "{s}_", .{name});
    return name;
}

/// Owner-only permissions (Windows: the default).
fn private(comptime mode: u32) Io.File.Permissions {
    if (@import("builtin").os.tag == .windows) return .default_file;
    return .fromMode(mode);
}
