//! Mock data for the spike: the sample notes from examples/sample-notes,
//! shaped like the daemon's `list` reply (docs/PROTOCOL.md §1) so the real TUI
//! can swap this for the socket without touching the views.
const std = @import("std");

pub const Folder = struct { id: []const u8, name: []const u8, parent: ?[]const u8 = null, depth: u8 = 0, count: usize = 0 };

pub const Note = struct {
    path: []const u8, // for the spike: the sample file, relative to the notes dir
    folder: ?[]const u8,
    title: []const u8,
    body: []const u8,
    tags: []const []const u8,
    pinned: bool,
    trashed: bool,
    age_minutes: u32,
};

pub const SourceKind = enum { all, pinned, unfiled, folder, tag, trash, header };
pub const Source = struct { kind: SourceKind, label: []const u8, id: []const u8 = "", depth: u8 = 0, count: usize = 0 };

pub const Store = struct {
    dir: []const u8,
    folders: []Folder,
    notes: []Note,
    tags: []const []const u8,
};

const Manifest = struct {
    folders: []const struct { id: []const u8, name: []const u8, parent: ?[]const u8 = null },
    notes: []const struct {
        file: []const u8,
        folder: ?[]const u8 = null,
        updated_days_ago: u32 = 0,
        updated_minutes_ago: u32 = 0,
        pinned: bool = false,
        trashed: bool = false,
    },
};

/// Title = first line without heading marks (like the engine).
pub fn titleOf(body: []const u8) []const u8 {
    const nl = std.mem.findScalar(u8, body, '\n') orelse body.len;
    return std.mem.trim(u8, std.mem.trimStart(u8, body[0..nl], "# "), " \t\r");
}

fn isTagByte(b: u8) bool {
    return b >= 0x80 or std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b == '/';
}

/// Inline #tags (not headings, not inside code fences): lower-cased, unique.
pub fn tagsOf(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var fence = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
            fence = !fence;
            continue;
        }
        if (fence) continue;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (line[i] != '#' or (i > 0 and line[i - 1] != ' ')) continue;
            var j = i + 1;
            while (j < line.len and isTagByte(line[j])) j += 1;
            if (j == i + 1) continue; // "# heading" or a lone '#'
            const tag = try std.ascii.allocLowerString(arena, line[i + 1 .. j]);
            for (out.items) |t| {
                if (std.mem.eql(u8, t, tag)) break;
            } else try out.append(arena, tag);
            i = j;
        }
    }
    return out.items;
}

pub fn load(io: std.Io, arena: std.mem.Allocator, dir: []const u8) !Store {
    const cwd = std.Io.Dir.cwd();
    const mpath = try std.fs.path.join(arena, &.{ dir, "manifest.json" });
    const mtext = try cwd.readFileAlloc(io, mpath, arena, .limited(1 << 20));
    const m = try std.json.parseFromSliceLeaky(Manifest, arena, mtext, .{ .ignore_unknown_fields = true });

    var folders: std.ArrayList(Folder) = .empty;
    for (m.folders) |f| try folders.append(arena, .{ .id = f.id, .name = f.name, .parent = f.parent });
    // depth from the parent chain
    for (folders.items) |*f| {
        var p = f.parent;
        while (p) |pid| : (f.depth += 1) {
            p = for (folders.items) |g| {
                if (std.mem.eql(u8, g.id, pid)) break g.parent;
            } else null;
        }
    }

    var notes: std.ArrayList(Note) = .empty;
    var all_tags: std.ArrayList([]const u8) = .empty;
    for (m.notes) |n| {
        const path = try std.fs.path.join(arena, &.{ dir, n.file });
        const body = try cwd.readFileAlloc(io, path, arena, .limited(1 << 20));
        const tags = try tagsOf(arena, body);
        for (tags) |t| {
            for (all_tags.items) |x| {
                if (std.mem.eql(u8, x, t)) break;
            } else try all_tags.append(arena, t);
        }
        try notes.append(arena, .{
            .path = n.file,
            .folder = n.folder,
            .title = titleOf(body),
            .body = body,
            .tags = tags,
            .pinned = n.pinned,
            .trashed = n.trashed,
            .age_minutes = n.updated_days_ago * 1440 + n.updated_minutes_ago,
        });
    }
    std.mem.sort([]const u8, all_tags.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    std.mem.sort(Note, notes.items, {}, struct {
        fn lt(_: void, a: Note, b: Note) bool {
            if (a.pinned != b.pinned) return a.pinned;
            return a.age_minutes < b.age_minutes;
        }
    }.lt);
    return .{ .dir = dir, .folders = folders.items, .notes = notes.items, .tags = all_tags.items };
}

/// Folders in tree order (parents before their children).
fn appendTree(arena: std.mem.Allocator, s: *const Store, out: *std.ArrayList(Source), parent: ?[]const u8) !void {
    for (s.folders) |f| {
        const same = if (parent) |p| (f.parent != null and std.mem.eql(u8, f.parent.?, p)) else f.parent == null;
        if (!same) continue;
        var count: usize = 0;
        for (s.notes) |n| {
            if (!n.trashed and n.folder != null and std.mem.eql(u8, n.folder.?, f.id)) count += 1;
        }
        try out.append(arena, .{ .kind = .folder, .label = f.name, .id = f.id, .depth = f.depth, .count = count });
        try appendTree(arena, s, out, f.id);
    }
}

pub fn sources(arena: std.mem.Allocator, s: *const Store) ![]Source {
    var out: std.ArrayList(Source) = .empty;
    var live: usize = 0;
    var pinned: usize = 0;
    var unfiled: usize = 0;
    var trashed: usize = 0;
    for (s.notes) |n| {
        if (n.trashed) {
            trashed += 1;
            continue;
        }
        live += 1;
        if (n.pinned) pinned += 1;
        if (n.folder == null) unfiled += 1;
    }
    try out.append(arena, .{ .kind = .all, .label = "All notes", .count = live });
    try out.append(arena, .{ .kind = .pinned, .label = "Pinned", .count = pinned });
    try out.append(arena, .{ .kind = .unfiled, .label = "Notes", .count = unfiled });
    try out.append(arena, .{ .kind = .header, .label = "FOLDERS" });
    try appendTree(arena, s, &out, null);
    try out.append(arena, .{ .kind = .header, .label = "TAGS" });
    for (s.tags) |t| {
        var count: usize = 0;
        for (s.notes) |n| {
            if (n.trashed) continue;
            for (n.tags) |x| {
                if (std.mem.eql(u8, x, t)) {
                    count += 1;
                    break;
                }
            }
        }
        try out.append(arena, .{ .kind = .tag, .label = t, .id = t, .count = count });
    }
    try out.append(arena, .{ .kind = .header, .label = "" });
    try out.append(arena, .{ .kind = .trash, .label = "Trash", .count = trashed });
    return out.items;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn inFolderTree(s: *const Store, folder: ?[]const u8, root: []const u8) bool {
    var cur = folder;
    while (cur) |id| {
        if (std.mem.eql(u8, id, root)) return true;
        cur = for (s.folders) |f| {
            if (std.mem.eql(u8, f.id, id)) break f.parent;
        } else null;
    }
    return false;
}

/// Indices into s.notes for a source and a search query (title and body).
pub fn filter(arena: std.mem.Allocator, s: *const Store, src: Source, query: []const u8) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    for (s.notes, 0..) |n, i| {
        const keep = switch (src.kind) {
            .trash => n.trashed,
            .all, .header => !n.trashed,
            .pinned => !n.trashed and n.pinned,
            .unfiled => !n.trashed and n.folder == null,
            .folder => !n.trashed and inFolderTree(s, n.folder, src.id),
            .tag => !n.trashed and for (n.tags) |t| {
                if (std.mem.eql(u8, t, src.id)) break true;
            } else false,
        };
        if (keep and containsIgnoreCase(n.body, query)) try out.append(arena, i);
    }
    return out.items;
}

pub fn folderName(s: *const Store, id: ?[]const u8) []const u8 {
    const fid = id orelse return "Notes";
    for (s.folders) |f| {
        if (std.mem.eql(u8, f.id, fid)) return f.name;
    }
    return "Notes";
}

/// "4m ago", "3h ago", "yesterday", "12d ago"
pub fn ago(buf: []u8, minutes: u32) []const u8 {
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "";
    if (minutes < 1440) return std.fmt.bufPrint(buf, "{d}h ago", .{minutes / 60}) catch "";
    if (minutes < 2880) return "yesterday";
    return std.fmt.bufPrint(buf, "{d}d ago", .{minutes / 1440}) catch "";
}

test "title and tags" {
    try std.testing.expectEqualStrings("Lisbon in October", titleOf("# Lisbon in October\n\nbody"));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tags = try tagsOf(arena.allocator(), "# Title\nsee #Travel and #lisbon\n```\n#notatag\n```\nx#no #travel\n");
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("travel", tags[0]);
}
