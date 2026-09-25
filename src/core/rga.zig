//! Sequence CRDT for one note body: RGA (replicated growable array) with
//! run-length encoded items.
//!
//! Every UTF-16 code unit has an id `(replica, counter)`. Counters are Lamport
//! clocks, so a unit's id is greater than the id of the unit it was inserted
//! after. An insert names only its left origin; concurrent inserts after the
//! same origin are ordered by descending id `(counter, replica)`. Items are
//! runs of consecutively numbered units from one insert, split on demand.
//! Deleted units stay as tombstones.
//!
//! Lookups are linear in the number of items. That is fine for notes; a
//! counted tree can replace the array later without changing the interface.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Id = struct {
    r: u64,
    c: u64,

    pub fn eql(a: Id, b: Id) bool {
        return a.r == b.r and a.c == b.c;
    }

    /// RGA sibling order: larger (counter, replica) first.
    pub fn greater(a: Id, b: Id) bool {
        return a.c > b.c or (a.c == b.c and a.r > b.r);
    }
};

/// A run of ids `(r, c .. c+n-1)`.
pub const Range = struct { r: u64, c: u64, n: u64 };

/// A visible span that became hidden, in the order the patches apply.
pub const Seg = struct { pos: usize, len: usize };

const Item = struct {
    id: Id,
    units: std.ArrayList(u16),
    deleted: bool,

    fn len(it: Item) u64 {
        return it.units.items.len;
    }

    fn contains(it: Item, id: Id) bool {
        return it.id.r == id.r and id.c >= it.id.c and id.c < it.id.c + it.len();
    }
};

pub const Seq = struct {
    items: std.ArrayList(Item) = .empty,
    visible: usize = 0,

    pub fn deinit(self: *Seq, gpa: Allocator) void {
        for (self.items.items) |*it| it.units.deinit(gpa);
        self.items.deinit(gpa);
        self.* = undefined;
    }

    const Loc = struct { index: usize, offset: u64 };

    fn locate(self: *const Seq, id: Id) ?Loc {
        for (self.items.items, 0..) |it, i| {
            if (it.contains(id)) return .{ .index = i, .offset = id.c - it.id.c };
        }
        return null;
    }

    pub fn has(self: *const Seq, id: Id) bool {
        return self.locate(id) != null;
    }

    /// True when every id of the range exists (inserted, possibly deleted).
    pub fn covers(self: *const Seq, range: Range) bool {
        var found: u64 = 0;
        const end = range.c + range.n;
        for (self.items.items) |it| {
            if (it.id.r != range.r) continue;
            const lo = @max(it.id.c, range.c);
            const hi = @min(it.id.c + it.len(), end);
            if (hi > lo) found += hi - lo;
        }
        return found == range.n;
    }

    /// Split `items[index]` so that a new item starts at `offset`.
    fn split(self: *Seq, gpa: Allocator, index: usize, offset: u64) !void {
        const it = &self.items.items[index];
        std.debug.assert(offset > 0 and offset < it.len());
        var tail: std.ArrayList(u16) = .empty;
        errdefer tail.deinit(gpa);
        try tail.appendSlice(gpa, it.units.items[@intCast(offset)..]);
        const right: Item = .{ .id = .{ .r = it.id.r, .c = it.id.c + offset }, .units = tail, .deleted = it.deleted };
        try self.items.insert(gpa, index + 1, right);
        self.items.items[index].units.shrinkRetainingCapacity(@intCast(offset));
    }

    fn visibleBefore(self: *const Seq, index: usize) usize {
        var n: usize = 0;
        for (self.items.items[0..index]) |it| {
            if (!it.deleted) n += it.units.items.len;
        }
        return n;
    }

    /// Integrate an insert whose first unit has `id`. `origin` must exist
    /// (check with `has`). Returns the visible position of the new text.
    pub fn integrate(self: *Seq, gpa: Allocator, id: Id, origin: ?Id, units: []const u16) !usize {
        std.debug.assert(units.len > 0);
        var idx: usize = 0;
        if (origin) |o| {
            const loc = self.locate(o) orelse return error.MissingOrigin;
            if (loc.offset + 1 < self.items.items[loc.index].len()) try self.split(gpa, loc.index, loc.offset + 1);
            idx = loc.index + 1;
        }
        const scan_start = idx;
        while (idx < self.items.items.len and self.items.items[idx].id.greater(id)) idx += 1;

        // Typing continues a run: extend the item instead of adding one.
        if (origin) |o| if (idx == scan_start and idx > 0) {
            const prev = &self.items.items[idx - 1];
            if (!prev.deleted and prev.id.r == id.r and prev.id.c + prev.len() == id.c and
                o.r == prev.id.r and o.c == prev.id.c + prev.len() - 1)
            {
                const pos = self.visibleBefore(idx - 1) + prev.units.items.len;
                try prev.units.appendSlice(gpa, units);
                self.visible += units.len;
                return pos;
            }
        };

        var owned: std.ArrayList(u16) = .empty;
        errdefer owned.deinit(gpa);
        try owned.appendSlice(gpa, units);
        try self.items.insert(gpa, idx, .{ .id = id, .units = owned, .deleted = false });
        self.visible += units.len;
        return self.visibleBefore(idx);
    }

    /// Delete the ids of `range` (already-deleted units are skipped). Appends
    /// the visible spans that disappear to `segs`, positioned for sequential
    /// application. Caller ensures `covers(range)`.
    pub fn delete(self: *Seq, gpa: Allocator, range: Range, segs: *std.ArrayList(Seg)) !void {
        const end = range.c + range.n;
        var i: usize = 0;
        while (i < self.items.items.len) : (i += 1) {
            const it = self.items.items[i];
            if (it.id.r != range.r) continue;
            const lo = @max(it.id.c, range.c);
            const hi = @min(it.id.c + it.len(), end);
            if (hi <= lo) continue;
            if (lo > it.id.c) {
                try self.split(gpa, i, lo - it.id.c);
                continue; // items[i+1] now starts at lo
            }
            if (hi < it.id.c + it.len()) try self.split(gpa, i, hi - it.id.c);
            const cur = &self.items.items[i];
            if (!cur.deleted) {
                const pos = self.visibleBefore(i);
                const n: usize = @intCast(hi - lo);
                cur.deleted = true;
                self.visible -= n;
                if (segs.items.len > 0 and segs.items[segs.items.len - 1].pos == pos) {
                    segs.items[segs.items.len - 1].len += n;
                } else {
                    try segs.append(gpa, .{ .pos = pos, .len = n });
                }
            }
        }
    }

    /// Id of the visible unit at `pos - 1`, i.e. the origin for an insert at `pos`.
    pub fn originFor(self: *const Seq, pos: usize) ?Id {
        if (pos == 0) return null;
        var seen: usize = 0;
        for (self.items.items) |it| {
            if (it.deleted) continue;
            const n = it.units.items.len;
            if (pos - 1 < seen + n) return .{ .r = it.id.r, .c = it.id.c + (pos - 1 - seen) };
            seen += n;
        }
        unreachable; // caller validated pos <= visible
    }

    pub fn unitAt(self: *const Seq, pos: usize) u16 {
        var seen: usize = 0;
        for (self.items.items) |it| {
            if (it.deleted) continue;
            const n = it.units.items.len;
            if (pos < seen + n) return it.units.items[pos - seen];
            seen += n;
        }
        unreachable;
    }

    /// Id ranges of the visible units `[pos, pos+len)`.
    pub fn rangesOf(self: *const Seq, gpa: Allocator, pos: usize, len: usize, out: *std.ArrayList(Range)) !void {
        if (len == 0) return;
        const end = pos + len;
        var seen: usize = 0;
        for (self.items.items) |it| {
            if (it.deleted) continue;
            const n = it.units.items.len;
            const lo = @max(seen, pos);
            const hi = @min(seen + n, end);
            if (hi > lo) {
                const r: Range = .{ .r = it.id.r, .c = it.id.c + (lo - seen), .n = hi - lo };
                if (out.items.len > 0) {
                    const last = &out.items[out.items.len - 1];
                    if (last.r == r.r and last.c + last.n == r.c) {
                        last.n += r.n;
                    } else try out.append(gpa, r);
                } else try out.append(gpa, r);
            }
            seen += n;
            if (seen >= end) break;
        }
    }

    pub fn toUtf16(self: *const Seq, gpa: Allocator) ![]u16 {
        var out = try gpa.alloc(u16, self.visible);
        var n: usize = 0;
        for (self.items.items) |it| {
            if (it.deleted) continue;
            @memcpy(out[n..][0..it.units.items.len], it.units.items);
            n += it.units.items.len;
        }
        return out;
    }
};

const testing = std.testing;

fn u(comptime s: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}


test "typing extends one run; inserts and deletes land where expected" {
    const gpa = testing.allocator;
    var s: Seq = .{};
    defer s.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), try s.integrate(gpa, .{ .r = 1, .c = 1 }, null, u("ab")));
    try testing.expectEqual(@as(usize, 2), try s.integrate(gpa, .{ .r = 1, .c = 3 }, .{ .r = 1, .c = 2 }, u("c")));
    try testing.expectEqual(@as(usize, 1), s.items.items.len);
    try testing.expectEqual(@as(usize, 1), try s.integrate(gpa, .{ .r = 1, .c = 4 }, .{ .r = 1, .c = 1 }, u("X")));

    var segs: std.ArrayList(Seg) = .empty;
    defer segs.deinit(gpa);
    try s.delete(gpa, .{ .r = 1, .c = 2, .n = 2 }, &segs);
    try testing.expectEqual(@as(usize, 1), segs.items.len);
    try testing.expectEqual(Seg{ .pos = 2, .len = 2 }, segs.items[0]);
    const got = try s.toUtf16(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u16, u("aX"), got);
}

test "concurrent inserts after one origin converge regardless of order" {
    const gpa = testing.allocator;
    const base_id: Id = .{ .r = 9, .c = 1 };
    const a: Id = .{ .r = 1, .c = 5 };
    const b: Id = .{ .r = 2, .c = 5 };
    var s1: Seq = .{};
    defer s1.deinit(gpa);
    var s2: Seq = .{};
    defer s2.deinit(gpa);
    for ([_]*Seq{ &s1, &s2 }) |s| _ = try s.integrate(gpa, base_id, null, u("xy"));
    _ = try s1.integrate(gpa, a, base_id, u("A"));
    _ = try s1.integrate(gpa, b, base_id, u("B"));
    _ = try s2.integrate(gpa, b, base_id, u("B"));
    _ = try s2.integrate(gpa, a, base_id, u("A"));
    const t1 = try s1.toUtf16(gpa);
    defer gpa.free(t1);
    const t2 = try s2.toUtf16(gpa);
    defer gpa.free(t2);
    try testing.expectEqualSlices(u16, t1, t2);
    try testing.expectEqualSlices(u16, u("xBAy"), t1);
}
