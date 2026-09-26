//! The TUI's view of the notes: the daemon's `list` reply (docs/PROTOCOL.md
//! §1, NoteSummary and Folder), turned into the sources column (All, Pinned,
//! Notes, the folder tree, tags, Trash) and the note list of a source. Pure:
//! no terminal, no socket, so the tests run anywhere.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Note = struct {
    id: []const u8,
    title: []const u8 = "",
    snippet: []const u8 = "",
    folder: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    pinned: bool = false,
    trashed: bool = false,
    created: i64 = 0,
    updated: i64 = 0,
};

pub const Folder = struct {
    id: []const u8,
    name: []const u8,
    parent: ?[]const u8 = null,
};

pub const SourceKind = enum { all, pinned, unfiled, folder, tag, trash, header };

pub const Source = struct {
    kind: SourceKind,
    label: []const u8,
    /// Folder id or tag.
    id: []const u8 = "",
    depth: u8 = 0,
    count: usize = 0,

    /// Same source after a refresh (labels and counts may change).
    pub fn same(a: Source, b: Source) bool {
        return a.kind == b.kind and std.mem.eql(u8, a.id, b.id);
    }
};

/// One `list` reply. Everything lives in the arena of the caller.
pub const Store = struct {
    notes: []const Note = &.{},
    folders: []const Folder = &.{},

    pub fn folder(s: Store, id: []const u8) ?Folder {
        for (s.folders) |f| if (std.mem.eql(u8, f.id, id)) return f;
        return null;
    }

    pub fn note(s: Store, id: []const u8) ?usize {
        for (s.notes, 0..) |n, i| if (std.mem.eql(u8, n.id, id)) return i;
        return null;
    }

    /// "Home/Garden"; "Notes" for no folder.
    pub fn folderPath(s: Store, arena: Allocator, id: ?[]const u8) ![]const u8 {
        var cur = id orelse return "Notes";
        var parts: std.ArrayList([]const u8) = .empty;
        var guard: usize = 0;
        while (s.folder(cur)) |f| : (guard += 1) {
            if (guard > s.folders.len) break; // a parent cycle
            try parts.append(arena, f.name);
            cur = f.parent orelse break;
        }
        if (parts.items.len == 0) return "Notes";
        std.mem.reverse([]const u8, parts.items);
        return std.mem.join(arena, "/", parts.items);
    }

    /// Is `folder_id` `root` or inside it?
    pub fn inTree(s: Store, folder_id: ?[]const u8, root: []const u8) bool {
        var cur = folder_id;
        var guard: usize = 0;
        while (cur) |id| : (guard += 1) {
            if (std.mem.eql(u8, id, root)) return true;
            if (guard > s.folders.len) return false;
            cur = if (s.folder(id)) |f| f.parent else null;
        }
        return false;
    }
};

fn lessName(_: void, a: Folder, b: Folder) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

/// Folders in tree order (parents before children, siblings by name).
fn appendTree(arena: Allocator, s: Store, out: *std.ArrayList(Source), parent: ?[]const u8, depth: u8) !void {
    var kids: std.ArrayList(Folder) = .empty;
    for (s.folders) |f| {
        const same = if (parent) |p| (f.parent != null and std.mem.eql(u8, f.parent.?, p)) else (f.parent == null or s.folder(f.parent.?) == null);
        if (same) try kids.append(arena, f);
    }
    std.mem.sort(Folder, kids.items, {}, lessName);
    for (kids.items) |f| {
        var count: usize = 0;
        for (s.notes) |n| {
            if (!n.trashed and n.folder != null and s.inTree(n.folder, f.id)) count += 1;
        }
        try out.append(arena, .{ .kind = .folder, .label = f.name, .id = f.id, .depth = depth, .count = count });
        if (depth < 16) try appendTree(arena, s, out, f.id, depth + 1);
    }
}

/// The sources column: All, Pinned, Notes, FOLDERS, the tree, TAGS, the
/// tags, Trash. Headers are not selectable.
pub fn sources(arena: Allocator, s: Store) ![]Source {
    var out: std.ArrayList(Source) = .empty;
    var live: usize = 0;
    var pinned: usize = 0;
    var unfiled: usize = 0;
    var trashed: usize = 0;
    var tags: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (s.notes) |n| {
        if (n.trashed) {
            trashed += 1;
            continue;
        }
        live += 1;
        if (n.pinned) pinned += 1;
        if (n.folder == null or s.folder(n.folder.?) == null) unfiled += 1;
        for (n.tags) |t| {
            const gop = try tags.getOrPut(arena, t);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
    }
    try out.append(arena, .{ .kind = .all, .label = "All notes", .count = live });
    try out.append(arena, .{ .kind = .pinned, .label = "Pinned", .count = pinned });
    try out.append(arena, .{ .kind = .unfiled, .label = "Notes", .count = unfiled });
    if (s.folders.len > 0) {
        try out.append(arena, .{ .kind = .header, .label = "FOLDERS" });
        try appendTree(arena, s, &out, null, 0);
    }
    if (tags.count() > 0) {
        try out.append(arena, .{ .kind = .header, .label = "TAGS" });
        const keys = tags.keys();
        const Ctx = struct {
            k: []const []const u8,
            pub fn lessThan(c: @This(), a: usize, b: usize) bool {
                return std.mem.order(u8, c.k[a], c.k[b]) == .lt;
            }
        };
        tags.sort(Ctx{ .k = keys });
        for (tags.keys(), tags.values()) |t, count| try out.append(arena, .{ .kind = .tag, .label = t, .id = t, .count = count });
    }
    try out.append(arena, .{ .kind = .header, .label = "" });
    try out.append(arena, .{ .kind = .trash, .label = "Trash", .count = trashed });
    return out.items;
}

/// Is `n` in source `src`?
pub fn contains(s: Store, src: Source, n: Note) bool {
    return switch (src.kind) {
        .trash => n.trashed,
        .all, .header => !n.trashed,
        .pinned => !n.trashed and n.pinned,
        .unfiled => !n.trashed and (n.folder == null or s.folder(n.folder.?) == null),
        .folder => !n.trashed and s.inTree(n.folder, src.id),
        .tag => !n.trashed and for (n.tags) |t| {
            if (std.mem.eql(u8, t, src.id)) break true;
        } else false,
    };
}

const Order = struct {
    notes: []const Note,
    pinned_first: bool,
    fn less(o: Order, a: usize, b: usize) bool {
        const na = o.notes[a];
        const nb = o.notes[b];
        if (o.pinned_first and na.pinned != nb.pinned) return na.pinned;
        if (na.updated != nb.updated) return na.updated > nb.updated;
        return std.mem.order(u8, na.id, nb.id) == .lt;
    }
};

/// The notes of a source, as indices into `s.notes`: pinned first (not in
/// the Trash), then the most recently changed. With `hits` (a server-side
/// search), only the notes it found.
pub fn filter(arena: Allocator, s: Store, src: Source, hits: ?*const std.StringHashMapUnmanaged(void)) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    for (s.notes, 0..) |n, i| {
        if (!contains(s, src, n)) continue;
        if (hits) |h| if (!h.contains(n.id)) continue;
        try out.append(arena, i);
    }
    std.mem.sort(usize, out.items, Order{ .notes = s.notes, .pinned_first = src.kind != .trash }, Order.less);
    return out.items;
}

/// The move-to-folder picker: no folder first, then the tree.
pub const Target = struct { id: ?[]const u8, label: []const u8, depth: u8 };

pub fn targets(arena: Allocator, s: Store) ![]Target {
    var tree: std.ArrayList(Source) = .empty;
    try appendTree(arena, s, &tree, null, 0);
    const out = try arena.alloc(Target, tree.items.len + 1);
    out[0] = .{ .id = null, .label = "Notes (no folder)", .depth = 0 };
    for (tree.items, out[1..]) |f, *t| t.* = .{ .id = f.id, .label = f.label, .depth = f.depth };
    return out;
}

/// The daemon's snippet (the text after the title, whitespace collapsed)
/// without markdown marks: list and task marks, quote and heading marks,
/// table pipes and rules, emphasis, code ticks; links and pictures keep
/// their text.
pub fn plainSnippet(arena: Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, raw, ' ');
    while (words.next()) |word| {
        // Tokens that are only markup: "-", "[x]", "|", "##", ":--", "```".
        const only_marks = for (word) |b| {
            if (std.mem.findScalar(u8, "-*+>|#:[]`=~", b) == null) break false;
        } else true;
        if (only_marks or std.mem.eql(u8, word, "[x]") or std.mem.eql(u8, word, "[X]")) continue;
        if (out.items.len > 0) try out.append(arena, ' ');
        var i: usize = 0;
        while (i < word.len) : (i += 1) {
            const b = word[i];
            switch (b) {
                '*', '`', '~' => {},
                '!' => if (i + 1 < word.len and word[i + 1] == '[') {} else try out.append(arena, b),
                '[' => {},
                ']' => if (i + 1 < word.len and word[i + 1] == '(') {
                    // "](url)": drop the URL (it may continue in the next word).
                    const close = std.mem.findScalarPos(u8, word, i, ')') orelse word.len;
                    i = close;
                },
                '_' => if ((i == 0 or i + 1 == word.len)) {} else try out.append(arena, b),
                else => try out.append(arena, b),
            }
        }
    }
    return std.mem.trim(u8, out.items, " ");
}

/// "now", "4m ago", "3h ago", "yesterday", "12d ago", "2025-11-03".
pub fn ago(buf: []u8, now_ms: i64, t_ms: i64) []const u8 {
    const minutes: i64 = @divFloor(@max(now_ms - t_ms, 0), 60_000);
    if (t_ms <= 0) return "";
    if (minutes < 1) return "now";
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "";
    if (minutes < 1440) return std.fmt.bufPrint(buf, "{d}h ago", .{@divFloor(minutes, 60)}) catch "";
    if (minutes < 2880) return "yesterday";
    if (minutes < 60 * 24 * 60) return std.fmt.bufPrint(buf, "{d}d ago", .{@divFloor(minutes, 1440)}) catch "";
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(t_ms, 1000)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch "";
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn sample() Store {
    const S = struct {
        const folders = [_]Folder{
            .{ .id = "f-work", .name = "Work" },
            .{ .id = "f-home", .name = "Home" },
            .{ .id = "f-garden", .name = "Garden", .parent = "f-home" },
        };
        const notes = [_]Note{
            .{ .id = "n-1", .title = "Old", .updated = 100 },
            .{ .id = "n-2", .title = "Pinned", .pinned = true, .updated = 50, .folder = "f-work", .tags = &.{"idea"} },
            .{ .id = "n-3", .title = "Beds", .updated = 300, .folder = "f-garden", .tags = &.{ "garden", "idea" } },
            .{ .id = "n-4", .title = "Gone", .trashed = true, .pinned = true, .updated = 400, .folder = "f-home" },
            .{ .id = "n-5", .title = "Orphan", .updated = 200, .folder = "f-deleted" },
        };
    };
    return .{ .notes = &S.notes, .folders = &S.folders };
}

test "sources: counts, tree order, tags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = sample();
    const src = try sources(arena.allocator(), s);
    const labels = [_][]const u8{ "All notes", "Pinned", "Notes", "FOLDERS", "Home", "Garden", "Work", "TAGS", "garden", "idea", "", "Trash" };
    try testing.expectEqual(labels.len, src.len);
    for (labels, src) |l, x| try testing.expectEqualStrings(l, x.label);
    try testing.expectEqual(@as(usize, 4), src[0].count); // trashed not counted
    try testing.expectEqual(@as(usize, 1), src[1].count);
    try testing.expectEqual(@as(usize, 2), src[2].count); // n-1 and the orphan
    try testing.expectEqual(@as(usize, 1), src[4].count); // Home counts Garden's note
    try testing.expectEqual(@as(u8, 1), src[5].depth);
    try testing.expectEqual(@as(usize, 2), src[9].count);
    try testing.expectEqual(@as(usize, 1), src[11].count);
}

test "filter: pinned first, newest first, search hits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = sample();
    const all = try filter(a, s, .{ .kind = .all, .label = "" }, null);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 4, 0 }, all);
    const home = try filter(a, s, .{ .kind = .folder, .label = "", .id = "f-home" }, null);
    try testing.expectEqualSlices(usize, &.{2}, home);
    const trash = try filter(a, s, .{ .kind = .trash, .label = "" }, null);
    try testing.expectEqualSlices(usize, &.{3}, trash);
    var hits: std.StringHashMapUnmanaged(void) = .empty;
    try hits.put(a, "n-1", {});
    try hits.put(a, "n-3", {});
    const found = try filter(a, s, .{ .kind = .all, .label = "" }, &hits);
    try testing.expectEqualSlices(usize, &.{ 2, 0 }, found);
    const tag = try filter(a, s, .{ .kind = .tag, .label = "", .id = "idea" }, null);
    try testing.expectEqualSlices(usize, &.{ 1, 2 }, tag);
}

test "plain snippets" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("omajot keeps your notes in markdown, on", try plainSnippet(a, "omajot keeps your notes in **markdown**, on"));
    try testing.expectEqualStrings("Oat milk Coffee beans", try plainSnippet(a, "- [x] Oat milk - [ ] Coffee beans"));
    try testing.expectEqualStrings("Tram 28 Day Plan Thu Arrive", try plainSnippet(a, "![Tram 28](attachments/ab.png) | Day | Plan | | :-- | :-- | | Thu | Arrive |"));
    try testing.expectEqualStrings("see the docs and snake_case", try plainSnippet(a, "see [the docs](https://x.y/z) and `snake_case`"));
    try testing.expectEqualStrings("Present: Mia", try plainSnippet(a, "**Present:** Mia"));
    try testing.expectEqualStrings("Heading text x marks xx", try plainSnippet(a, "## Heading text x marks xx"));
}

test "folder paths, picker targets, ago" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = sample();
    try testing.expectEqualStrings("Home/Garden", try s.folderPath(a, "f-garden"));
    try testing.expectEqualStrings("Notes", try s.folderPath(a, null));
    const t = try targets(a, s);
    try testing.expectEqual(@as(usize, 4), t.len);
    try testing.expect(t[0].id == null);
    try testing.expectEqualStrings("Garden", t[2].label);
    var buf: [32]u8 = undefined;
    const min: i64 = 60_000;
    const now: i64 = 1_790_000_000_000;
    try testing.expectEqualStrings("now", ago(&buf, now, now - 10));
    try testing.expectEqualStrings("4m ago", ago(&buf, now, now - 4 * min));
    try testing.expectEqualStrings("3h ago", ago(&buf, now, now - 180 * min));
    try testing.expectEqualStrings("yesterday", ago(&buf, now, now - 1500 * min));
    try testing.expectEqualStrings("12d ago", ago(&buf, now, now - 12 * 1440 * min));
    try testing.expectEqualStrings("2025-11-03", ago(&buf, now, 1_762_128_000_000));
}
