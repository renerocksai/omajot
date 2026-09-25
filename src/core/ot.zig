//! Reference position transform between one client and the engine
//! (docs/PROTOCOL.md §1 "patch"). Two-party OT in the Jupiter style: the
//! engine transforms incoming edits over the patches the client had not yet
//! applied (`ack`), the client transforms incoming patches over its edits the
//! engine had not yet applied (`base`). Engine-side ops win ties, so both
//! sides place concurrent inserts at one position in the same order.
//!
//! The QML and JS ports mirror `xform` and `xformPrim` exactly.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { ins, del };

/// One primitive change on UTF-16 text. `tag` is caller bookkeeping (edit
/// `seq` or patch `pseq`) and is copied to both halves of a split.
pub const Prim = struct {
    kind: Kind,
    pos: usize,
    /// Units deleted (`del`); ignored for `ins`.
    len: usize = 0,
    /// Units inserted (`ins`); borrowed.
    text: []const u16 = &.{},
    tag: u64 = 0,

    pub fn ins(pos: usize, text: []const u16, tag: u64) Prim {
        return .{ .kind = .ins, .pos = pos, .text = text, .tag = tag };
    }

    pub fn del(pos: usize, len: usize, tag: u64) Prim {
        return .{ .kind = .del, .pos = pos, .len = len, .tag = tag };
    }

    fn empty(p: Prim) bool {
        return switch (p.kind) {
            .ins => p.text.len == 0,
            .del => p.len == 0,
        };
    }
};

/// A client edit `{pos, del, ins}` as primitives (delete first, then insert).
pub fn fromEdit(out: []Prim, pos: usize, del_len: usize, ins_text: []const u16, tag: u64) []Prim {
    var n: usize = 0;
    if (del_len > 0) {
        out[n] = Prim.del(pos, del_len, tag);
        n += 1;
    }
    if (ins_text.len > 0) {
        out[n] = Prim.ins(pos, ins_text, tag);
        n += 1;
    }
    return out[0..n];
}

pub const Pair = struct {
    /// `a` rewritten to apply after `b`.
    a: []Prim,
    /// `b` rewritten to apply after `a`.
    b: []Prim,
};

/// Transform two sequences that were made concurrently on the same text.
/// Allocates from `arena` and never frees; pass an arena.
pub fn xform(arena: Allocator, a: []const Prim, b: []const Prim, a_wins: bool) Allocator.Error!Pair {
    if (a.len == 0 or b.len == 0) return .{ .a = try arena.dupe(Prim, a), .b = try arena.dupe(Prim, b) };
    if (a.len == 1 and b.len == 1) return xformPrim(arena, a[0], b[0], a_wins);
    if (a.len > 1) {
        const first = try xform(arena, a[0..1], b, a_wins);
        const rest = try xform(arena, a[1..], first.b, a_wins);
        return .{ .a = try std.mem.concat(arena, Prim, &.{ first.a, rest.a }), .b = rest.b };
    }
    const first = try xform(arena, a, b[0..1], a_wins);
    const rest = try xform(arena, first.a, b[1..], a_wins);
    return .{ .a = rest.a, .b = try std.mem.concat(arena, Prim, &.{ first.b, rest.b }) };
}

fn one(arena: Allocator, p: Prim) Allocator.Error![]Prim {
    if (p.empty()) return &.{};
    const s = try arena.alloc(Prim, 1);
    s[0] = p;
    return s;
}

fn two(arena: Allocator, p: Prim, q: Prim) Allocator.Error![]Prim {
    if (p.empty()) return one(arena, q);
    if (q.empty()) return one(arena, p);
    const s = try arena.alloc(Prim, 2);
    s[0] = p;
    s[1] = q;
    return s;
}

/// Insert `i` against delete `d`, both on the same text.
fn insVsDel(arena: Allocator, i: Prim, d: Prim) Allocator.Error!struct { i: []Prim, d: []Prim } {
    const d_end = d.pos + d.len;
    var moved = i;
    if (i.pos <= d.pos) {
        var d2 = d;
        d2.pos += i.text.len;
        return .{ .i = try one(arena, moved), .d = try one(arena, d2) };
    }
    if (i.pos >= d_end) {
        moved.pos -= d.len;
        return .{ .i = try one(arena, moved), .d = try one(arena, d) };
    }
    // Insert inside the deleted range: the text survives at the range start,
    // the delete splits around it.
    moved.pos = d.pos;
    const before = Prim.del(d.pos, i.pos - d.pos, d.tag);
    const after = Prim.del(d.pos + i.text.len, d_end - i.pos, d.tag);
    return .{ .i = try one(arena, moved), .d = try two(arena, before, after) };
}

fn delVsDel(a: Prim, b: Prim) Prim {
    const a_end = a.pos + a.len;
    const b_end = b.pos + b.len;
    const lo = @max(a.pos, b.pos);
    const hi = @min(a_end, b_end);
    const overlap = if (hi > lo) hi - lo else 0;
    var r = a;
    r.len = a.len - overlap;
    r.pos = if (a.pos <= b.pos) a.pos else if (a.pos >= b_end) a.pos - b.len else b.pos;
    return r;
}

pub fn xformPrim(arena: Allocator, a: Prim, b: Prim, a_wins: bool) Allocator.Error!Pair {
    switch (a.kind) {
        .ins => switch (b.kind) {
            .ins => {
                var a2 = a;
                var b2 = b;
                if (a.pos < b.pos or (a.pos == b.pos and a_wins)) {
                    b2.pos += a.text.len;
                } else {
                    a2.pos += b.text.len;
                }
                return .{ .a = try one(arena, a2), .b = try one(arena, b2) };
            },
            .del => {
                const r = try insVsDel(arena, a, b);
                return .{ .a = r.i, .b = r.d };
            },
        },
        .del => switch (b.kind) {
            .ins => {
                const r = try insVsDel(arena, b, a);
                return .{ .a = r.d, .b = r.i };
            },
            .del => return .{ .a = try one(arena, delVsDel(a, b)), .b = try one(arena, delVsDel(b, a)) },
        },
    }
}

/// Apply one primitive to a UTF-16 buffer (tests and reference clients).
pub fn apply(gpa: Allocator, text: *std.ArrayList(u16), p: Prim) !void {
    switch (p.kind) {
        .ins => try text.insertSlice(gpa, p.pos, p.text),
        .del => text.replaceRangeAssumeCapacity(p.pos, p.len, &.{}),
    }
}

const testing = std.testing;

fn u(comptime s: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

test "concurrent inserts at one position: the winner goes first on both sides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = u("ab");
    const p = Prim.ins(1, u("P"), 0);
    const l = Prim.ins(1, u("L"), 0);
    const r = try xformPrim(arena, p, l, true);

    var server: std.ArrayList(u16) = .empty;
    defer server.deinit(testing.allocator);
    try server.appendSlice(testing.allocator, base);
    try apply(testing.allocator, &server, p);
    for (r.b) |x| try apply(testing.allocator, &server, x);

    var client: std.ArrayList(u16) = .empty;
    defer client.deinit(testing.allocator);
    try client.appendSlice(testing.allocator, base);
    try apply(testing.allocator, &client, l);
    for (r.a) |x| try apply(testing.allocator, &client, x);

    try testing.expectEqualSlices(u16, u("aPLb"), server.items);
    try testing.expectEqualSlices(u16, server.items, client.items);
}

test "insert inside a concurrent delete survives and splits the delete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try xformPrim(arena, Prim.ins(3, u("X"), 0), Prim.del(1, 4, 7), false);
    try testing.expectEqual(@as(usize, 1), r.a[0].pos);
    try testing.expectEqual(@as(usize, 2), r.b.len);
    try testing.expectEqual(@as(u64, 7), r.b[1].tag);
}

const Rand = std.Random;

fn randomPrim(rnd: Rand, len: usize, tag: u64) Prim {
    const alphabet = u("xyzü🎉");
    if (len > 0 and rnd.boolean()) {
        const pos = rnd.uintLessThan(usize, len);
        const n = 1 + rnd.uintLessThan(usize, @min(len - pos, 4));
        return Prim.del(pos, n, tag);
    }
    const pos = rnd.uintLessThan(usize, len + 1);
    const pick = rnd.uintLessThan(usize, 4);
    const slices = [_][]const u16{ alphabet[0..1], alphabet[1..2], alphabet[3..4], alphabet[4..6] };
    return Prim.ins(pos, slices[pick], tag);
}

// Surrogate-agnostic property test: a server generating patches and a client
// generating edits, with random in-flight delays in both directions, must
// end with identical text.
test "jupiter convergence under random delays" {
    const gpa = testing.allocator;
    var seed: u64 = 1;
    while (seed <= 300) : (seed += 1) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();

        var server: std.ArrayList(u16) = .empty;
        var client: std.ArrayList(u16) = .empty;
        try server.appendSlice(arena, u("hello"));
        try client.appendSlice(arena, u("hello"));

        const Msg = struct { seq_or_pseq: u64, ack_or_base: u64, prims: []Prim };
        var to_client: std.ArrayList(Msg) = .empty;
        var to_server: std.ArrayList(Msg) = .empty;

        var last_seq: u64 = 0; // server: last client edit applied
        var pseq: u64 = 0; // server: patches sent
        var unacked: []Prim = &.{};
        var seq: u64 = 0; // client: edits sent
        var last_pseq: u64 = 0; // client: patches applied
        var pending: []Prim = &.{};

        var step: usize = 0;
        while (step < 60 or to_client.items.len > 0 or to_server.items.len > 0) : (step += 1) {
            const choice = if (step < 60) rnd.uintLessThan(u8, 4) else 2 + rnd.uintLessThan(u8, 2);
            switch (choice) {
                0 => { // server makes a remote change
                    pseq += 1;
                    const p = randomPrim(rnd, server.items.len, pseq);
                    try apply(arena, &server, p);
                    unacked = try std.mem.concat(arena, Prim, &.{ unacked, &.{p} });
                    const ps = try arena.alloc(Prim, 1);
                    ps[0] = p;
                    try to_client.append(arena, .{ .seq_or_pseq = pseq, .ack_or_base = last_seq, .prims = ps });
                },
                1 => { // client types
                    seq += 1;
                    const e = randomPrim(rnd, client.items.len, seq);
                    try apply(arena, &client, e);
                    pending = try std.mem.concat(arena, Prim, &.{ pending, &.{e} });
                    const es = try arena.alloc(Prim, 1);
                    es[0] = e;
                    try to_server.append(arena, .{ .seq_or_pseq = seq, .ack_or_base = last_pseq, .prims = es });
                },
                2 => if (to_server.items.len > 0) { // server receives an edit
                    const m = to_server.orderedRemove(0);
                    var keep: std.ArrayList(Prim) = .empty;
                    for (unacked) |p| if (p.tag > m.ack_or_base) try keep.append(arena, p);
                    const r = try xform(arena, m.prims, keep.items, false);
                    unacked = r.b;
                    for (r.a) |p| try apply(arena, &server, p);
                    last_seq = m.seq_or_pseq;
                },
                else => if (to_client.items.len > 0) { // client receives a patch
                    const m = to_client.orderedRemove(0);
                    var keep: std.ArrayList(Prim) = .empty;
                    for (pending) |p| if (p.tag > m.ack_or_base) try keep.append(arena, p);
                    const r = try xform(arena, m.prims, keep.items, true);
                    pending = r.b;
                    for (r.a) |p| try apply(arena, &client, p);
                    last_pseq = m.seq_or_pseq;
                },
            }
        }
        testing.expectEqualSlices(u16, server.items, client.items) catch |err| {
            std.debug.print("jupiter diverged, seed {d}\n", .{seed});
            return err;
        };
    }
}
