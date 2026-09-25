//! Minimal edits between two texts (UTF-16 code units), as `ot.Prim`s that
//! apply one after another: each position refers to the text after the
//! previous primitives. Used for whole-text writes (`put`), so that writing a
//! note back only changes what differs, and a three-way merge (`ot.xform`)
//! keeps concurrent edits that touch other places.
//!
//! Method: trim the common prefix and suffix, run Myers' O(ND) diff over the
//! remaining lines, then trim each changed line range by characters, so a
//! typo fix inside a long line is one small delete and insert. Bounded: past
//! `max_d` differing lines the middle becomes one replacement. Never splits a
//! surrogate pair.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("ot.zig");

/// Differing lines beyond which the middle becomes a single replacement.
pub const max_d: usize = 1000;
/// Lines beyond which Myers is skipped (one replacement).
pub const max_lines: usize = 100_000;

fn isHigh(u: u16) bool {
    return u >= 0xD800 and u <= 0xDBFF;
}
fn isLow(u: u16) bool {
    return u >= 0xDC00 and u <= 0xDFFF;
}

/// Common prefix length that does not end between a surrogate pair.
fn prefixLen(a: []const u16, b: []const u16) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;
    if (i > 0 and isHigh(a[i - 1]) and i < a.len and isLow(a[i])) i -= 1;
    return i;
}

/// Common suffix length (after `skip` prefix units) that does not start inside a surrogate pair.
fn suffixLen(a: []const u16, b: []const u16, skip: usize) usize {
    const n = @min(a.len, b.len) - skip;
    var i: usize = 0;
    while (i < n and a[a.len - 1 - i] == b[b.len - 1 - i]) i += 1;
    if (i > 0 and a.len - i < a.len and isLow(a[a.len - i]) and a.len - i > 0 and isHigh(a[a.len - i - 1])) i -= 1;
    return i;
}

const Line = struct { start: usize, end: usize, hash: u64 };

fn splitLines(arena: Allocator, t: []const u16) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    for (t, 0..) |u, i| {
        if (u == '\n') {
            try lines.append(arena, .{ .start = start, .end = i + 1, .hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(t[start .. i + 1])) });
            start = i + 1;
        }
    }
    if (start < t.len) try lines.append(arena, .{ .start = start, .end = t.len, .hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(t[start..])) });
    return lines.items;
}

const Hunk = struct { a0: usize, a1: usize, b0: usize, b1: usize };

/// Line hunks (in line indexes) that turn `la` into `lb`, or null past `max_d`.
fn myers(arena: Allocator, a: []const u16, la: []const Line, b: []const u16, lb: []const Line) !?[]Hunk {
    const n = la.len;
    const m = lb.len;
    const eq = struct {
        fn f(ta: []const u16, x: Line, tb: []const u16, y: Line) bool {
            return x.hash == y.hash and std.mem.eql(u16, ta[x.start..x.end], tb[y.start..y.end]);
        }
    }.f;
    const limit = @min(n + m, max_d);
    const off: isize = @intCast(limit + 1);
    const width = 2 * (limit + 1) + 1;
    var v = try arena.alloc(isize, width);
    @memset(v, 0);
    var trace: std.ArrayList([]isize) = .empty;

    var found = false;
    var d: usize = 0;
    outer: while (d <= limit) : (d += 1) {
        try trace.append(arena, try arena.dupe(isize, v));
        const di: isize = @intCast(d);
        var k: isize = -di;
        while (k <= di) : (k += 2) {
            var x: isize = if (k == -di or (k != di and v[@intCast(k - 1 + off)] < v[@intCast(k + 1 + off)]))
                v[@intCast(k + 1 + off)]
            else
                v[@intCast(k - 1 + off)] + 1;
            var y = x - k;
            while (x < n and y < m and y >= 0 and eq(a, la[@intCast(x)], b, lb[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[@intCast(k + off)] = x;
            if (x >= n and y >= m) {
                found = true;
                break :outer;
            }
        }
    }
    if (!found) return null;

    // Backtrack into per-line steps, then group non-equal runs into hunks.
    const Step = enum { eq, del, ins };
    var steps: std.ArrayList(Step) = .empty;
    var x: isize = @intCast(n);
    var y: isize = @intCast(m);
    var di: isize = @intCast(trace.items.len - 1);
    while (di >= 0) : (di -= 1) {
        const vv = trace.items[@intCast(di)];
        const k = x - y;
        const prev_k: isize = if (k == -di or (k != di and vv[@intCast(k - 1 + off)] < vv[@intCast(k + 1 + off)])) k + 1 else k - 1;
        const prev_x = vv[@intCast(prev_k + off)];
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) {
            try steps.append(arena, .eq);
            x -= 1;
            y -= 1;
        }
        if (di > 0) try steps.append(arena, if (x == prev_x) .ins else .del);
        x = prev_x;
        y = prev_y;
    }
    std.mem.reverse(Step, steps.items);

    var hunks: std.ArrayList(Hunk) = .empty;
    var ia: usize = 0;
    var ib: usize = 0;
    var i: usize = 0;
    while (i < steps.items.len) {
        if (steps.items[i] == .eq) {
            ia += 1;
            ib += 1;
            i += 1;
            continue;
        }
        var h: Hunk = .{ .a0 = ia, .a1 = ia, .b0 = ib, .b1 = ib };
        while (i < steps.items.len and steps.items[i] != .eq) : (i += 1) switch (steps.items[i]) {
            .del => h.a1 += 1,
            .ins => h.b1 += 1,
            .eq => unreachable,
        };
        ia = h.a1;
        ib = h.b1;
        try hunks.append(arena, h);
    }
    return hunks.items;
}

/// Primitives that turn `a` into `b` (texts borrow from `b`). Arena-allocated.
pub fn edits(arena: Allocator, a: []const u16, b: []const u16) ![]ot.Prim {
    var out: std.ArrayList(ot.Prim) = .empty;
    const pre = prefixLen(a, b);
    const suf = suffixLen(a, b, pre);
    const am = a[pre .. a.len - suf];
    const bm = b[pre .. b.len - suf];
    if (am.len == 0 and bm.len == 0) return out.items;

    const la = try splitLines(arena, am);
    const lb = try splitLines(arena, bm);
    const hunks: []const Hunk = blk: {
        if (la.len + lb.len <= max_lines) if (try myers(arena, am, la, bm, lb)) |h| break :blk h;
        const one = try arena.alloc(Hunk, 1);
        one[0] = .{ .a0 = 0, .a1 = la.len, .b0 = 0, .b1 = lb.len };
        break :blk one;
    };

    // `delta`: how far positions in `a` have moved in the text being built.
    var delta: isize = 0;
    for (hunks) |h| {
        const as = if (h.a0 < la.len) la[h.a0].start else am.len;
        const ae = if (h.a1 > h.a0) la[h.a1 - 1].end else as;
        const bs = if (h.b0 < lb.len) lb[h.b0].start else bm.len;
        const be = if (h.b1 > h.b0) lb[h.b1 - 1].end else bs;
        const ha = am[as..ae];
        const hb = bm[bs..be];
        const p = prefixLen(ha, hb);
        const s = suffixLen(ha, hb, p);
        const del_len = ha.len - p - s;
        const ins = hb[p .. hb.len - s];
        const pos: usize = @intCast(@as(isize, @intCast(pre + as + p)) + delta);
        if (del_len > 0) try out.append(arena, ot.Prim.del(pos, del_len, 0));
        if (ins.len > 0) try out.append(arena, ot.Prim.ins(pos, ins, 0));
        delta += @as(isize, @intCast(ins.len)) - @as(isize, @intCast(del_len));
    }
    return out.items;
}

/// Apply primitives to `t` (tests and the three-way merge check).
pub fn apply(gpa: Allocator, t: []const u16, prims: []const ot.Prim) ![]u16 {
    var cur: std.ArrayList(u16) = .empty;
    errdefer cur.deinit(gpa);
    try cur.appendSlice(gpa, t);
    for (prims) |p| switch (p.kind) {
        .ins => try cur.insertSlice(gpa, p.pos, p.text),
        .del => cur.replaceRangeAssumeCapacity(p.pos, p.len, &.{}),
    };
    return cur.toOwnedSlice(gpa);
}

const testing = std.testing;

fn u16s(arena: Allocator, s: []const u8) ![]u16 {
    return std.unicode.utf8ToUtf16LeAlloc(arena, s);
}

fn check(a8: []const u8, b8: []const u8) !usize {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try u16s(arena, a8);
    const b = try u16s(arena, b8);
    const prims = try edits(arena, a, b);
    const got = try apply(arena, a, prims);
    try testing.expectEqualSlices(u16, b, got);
    var changed: usize = 0;
    for (prims) |p| changed += if (p.kind == .ins) p.text.len else p.len;
    return changed;
}

test "edits turn a into b, and stay small" {
    try testing.expectEqual(@as(usize, 0), try check("same\ntext\n", "same\ntext\n"));
    try testing.expectEqual(@as(usize, 2), try check("the cat sat\n", "the bat sat\n"));
    _ = try check("", "new note\n");
    _ = try check("gone\n", "");
    // Two distant changes are two small edits, not one big replacement.
    const changed = try check("A x B\nkeep\nkeep\nkeep\nC y D\n", "A X B\nkeep\nkeep\nkeep\nC Y D\n");
    try testing.expectEqual(@as(usize, 4), changed);
    _ = try check("l1\nl2\nl3\n", "l0\nl1\nl3\nl4\n");
    _ = try check("no newline at end", "no newline at the end");
}

test "edits never split a surrogate pair" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 🎉 and 🎊 share their high surrogate.
    const a = try u16s(arena, "x🎉y");
    const b = try u16s(arena, "x🎊y");
    const prims = try edits(arena, a, b);
    for (prims) |p| {
        try testing.expect(p.pos == 0 or !isLow(a[@min(p.pos, a.len - 1)]) or p.pos >= a.len);
        if (p.kind == .ins) try testing.expect(!isLow(p.text[0]));
    }
    try testing.expectEqualSlices(u16, b, try apply(arena, a, prims));
}

test "edits: random texts round-trip" {
    var prng = std.Random.DefaultPrng.init(0x0a1);
    const r = prng.random();
    const alphabet = "ab\n cde\n🎉ü";
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var a8: [80]u8 = undefined;
        var b8: [80]u8 = undefined;
        const na = gen(r, alphabet, &a8);
        const nb = gen(r, alphabet, &b8);
        _ = try check(a8[0..na], b8[0..nb]);
    }
}

fn gen(r: std.Random, alphabet: []const u8, buf: []u8) usize {
    // Whole code points only, so the text stays valid UTF-8.
    var view = (std.unicode.Utf8View.init(alphabet) catch unreachable).iterator();
    var cps: [16][]const u8 = undefined;
    var n: usize = 0;
    while (view.nextCodepointSlice()) |cp| : (n += 1) cps[n] = cp;
    var len: usize = 0;
    const count = r.uintLessThan(usize, 20);
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const cp = cps[r.uintLessThan(usize, n)];
        if (len + cp.len > buf.len) break;
        @memcpy(buf[len .. len + cp.len], cp);
        len += cp.len;
    }
    return len;
}
