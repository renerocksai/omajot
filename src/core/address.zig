//! Note and folder addresses for the command line: `Folder/Sub/Title` (the
//! title is the note's first line) or an exact id (`n-…`, `f-…`). Pure: works
//! on the `list` reply.
//!
//! Note lookup, first stage with a match wins:
//!   1. exact id;
//!   2. exact path `Folder/Sub/Title` (a note outside folders: `Title`);
//!   3. exact title, in any folder;
//!   4. stages 2 and 3 again, ignoring case.
//! In each stage, notes in the Trash count only when no live note matches.
//! One match: found. More: ambiguous (the caller lists them with ids).
const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");

pub const NoteRef = struct {
    id: []const u8,
    title: []const u8,
    folder: ?[]const u8,
    trashed: bool,
};

pub const FolderRef = struct {
    id: []const u8,
    name: []const u8,
    parent: ?[]const u8,
};

pub const Result = union(enum) {
    found: usize,
    not_found,
    /// Indexes of the candidates.
    ambiguous: []const usize,
};

pub const Index = struct {
    notes: []const NoteRef,
    folders: []const FolderRef,

    pub fn folderIndex(self: Index, id: []const u8) ?usize {
        for (self.folders, 0..) |f, i| if (std.mem.eql(u8, f.id, id)) return i;
        return null;
    }

    /// "A/B" for a folder id, "" for null (no folder).
    pub fn folderPath(self: Index, arena: Allocator, folder: ?[]const u8) ![]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        var cur = folder;
        var guard: usize = 0;
        while (cur) |id| : (guard += 1) {
            if (guard > self.folders.len) break; // the engine never returns cycles
            const i = self.folderIndex(id) orelse break;
            try parts.append(arena, self.folders[i].name);
            cur = self.folders[i].parent;
        }
        std.mem.reverse([]const u8, parts.items);
        return std.mem.join(arena, "/", parts.items);
    }

    /// "A/B/Title", or "Title" outside folders.
    pub fn notePath(self: Index, arena: Allocator, i: usize) ![]const u8 {
        const n = self.notes[i];
        const dir = try self.folderPath(arena, n.folder);
        if (dir.len == 0) return n.title;
        return std.mem.concat(arena, u8, &.{ dir, "/", n.title });
    }

    pub fn resolveNote(self: Index, arena: Allocator, query: []const u8) !Result {
        if (std.mem.startsWith(u8, query, "n-")) {
            for (self.notes, 0..) |n, i| if (std.mem.eql(u8, n.id, query)) return .{ .found = i };
        }
        const q = std.mem.trim(u8, query, "/");
        const paths = try arena.alloc([]const u8, self.notes.len);
        for (paths, 0..) |*p, i| p.* = try self.notePath(arena, i);
        const q_folded = try folded(arena, q);
        for ([_]bool{ false, true }) |ignore_case| {
            for ([_]bool{ true, false }) |by_path| {
                var live: std.ArrayList(usize) = .empty;
                var trash: std.ArrayList(usize) = .empty;
                for (self.notes, 0..) |n, i| {
                    const key = if (by_path) paths[i] else n.title;
                    const hit = if (ignore_case)
                        std.mem.eql(u8, try folded(arena, key), q_folded)
                    else
                        std.mem.eql(u8, key, q);
                    if (!hit) continue;
                    try (if (n.trashed) &trash else &live).append(arena, i);
                }
                const set = if (live.items.len > 0) live.items else trash.items;
                if (set.len == 1) return .{ .found = set[0] };
                if (set.len > 1) return .{ .ambiguous = set };
            }
        }
        return .not_found;
    }

    /// A folder path `A/B` (or an `f-…` id). Empty path: the top level (null).
    pub fn resolveFolder(self: Index, arena: Allocator, query: []const u8) !FolderResult {
        if (std.mem.startsWith(u8, query, "f-")) {
            if (self.folderIndex(query)) |i| return .{ .found = i };
        }
        const q = std.mem.trim(u8, query, "/");
        if (q.len == 0) return .top;
        var exact: std.ArrayList(usize) = .empty;
        var loose: std.ArrayList(usize) = .empty;
        const q_folded = try folded(arena, q);
        for (self.folders, 0..) |f, i| {
            const p = try self.folderPath(arena, f.id);
            if (std.mem.eql(u8, p, q)) try exact.append(arena, i) else if (std.mem.eql(u8, try folded(arena, p), q_folded)) try loose.append(arena, i);
        }
        const set = if (exact.items.len > 0) exact.items else loose.items;
        if (set.len == 1) return .{ .found = set[0] };
        if (set.len > 1) return .{ .ambiguous = set };
        return .not_found;
    }
};

pub const FolderResult = union(enum) {
    found: usize,
    /// The top level (no folder).
    top,
    not_found,
    ambiguous: []const usize,
};

fn folded(arena: Allocator, s: []const u8) ![]u8 {
    const c = try arena.dupe(u8, s);
    text.foldCase(c);
    return c;
}

/// Split `A/B/C` into its parent path `A/B` and last part `C`.
pub fn splitLast(path: []const u8) struct { parent: []const u8, name: []const u8 } {
    const p = std.mem.trim(u8, path, "/");
    const slash = std.mem.findScalarLast(u8, p, '/') orelse return .{ .parent = "", .name = p };
    return .{ .parent = p[0..slash], .name = p[slash + 1 ..] };
}

const testing = std.testing;

test "resolve notes by path, title, id, case; trash only as a fallback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const folders = [_]FolderRef{
        .{ .id = "f-1", .name = "Work", .parent = null },
        .{ .id = "f-2", .name = "Plans", .parent = "f-1" },
        .{ .id = "f-3", .name = "Home", .parent = null },
    };
    const notes = [_]NoteRef{
        .{ .id = "n-1", .title = "Todo", .folder = "f-2", .trashed = false },
        .{ .id = "n-2", .title = "Todo", .folder = "f-3", .trashed = false },
        .{ .id = "n-3", .title = "Ideas", .folder = null, .trashed = false },
        .{ .id = "n-4", .title = "Ideas", .folder = null, .trashed = true },
        .{ .id = "n-5", .title = "Old", .folder = "f-3", .trashed = true },
    };
    const ix: Index = .{ .notes = &notes, .folders = &folders };

    try testing.expectEqualStrings("Work/Plans/Todo", try ix.notePath(arena, 0));
    try testing.expectEqual(Result{ .found = 0 }, try ix.resolveNote(arena, "Work/Plans/Todo"));
    try testing.expectEqual(Result{ .found = 1 }, try ix.resolveNote(arena, "home/todo"));
    try testing.expectEqual(Result{ .found = 1 }, try ix.resolveNote(arena, "n-2"));
    const amb = try ix.resolveNote(arena, "Todo");
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, amb.ambiguous);
    try testing.expectEqual(Result{ .found = 2 }, try ix.resolveNote(arena, "Ideas"));
    try testing.expectEqual(Result{ .found = 4 }, try ix.resolveNote(arena, "Old"));
    try testing.expectEqual(Result.not_found, try ix.resolveNote(arena, "Nope"));

    try testing.expectEqual(FolderResult{ .found = 1 }, try ix.resolveFolder(arena, "Work/Plans/"));
    try testing.expectEqual(FolderResult{ .found = 2 }, try ix.resolveFolder(arena, "home"));
    try testing.expectEqual(FolderResult.top, try ix.resolveFolder(arena, "/"));
    try testing.expectEqual(FolderResult.not_found, try ix.resolveFolder(arena, "Plans"));
    const s = splitLast("Work/Plans/New");
    try testing.expectEqualStrings("Work/Plans", s.parent);
    try testing.expectEqualStrings("New", s.name);
}
