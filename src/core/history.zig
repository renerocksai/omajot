//! A note's history, read from a replica's op log (ops.jsonl: one JSON array
//! of ops per line, every op the replica applied). Pure: the caller reads the
//! file.
//!
//! Time filter: an op's `t` is a hybrid logical clock, so an op made after
//! seeing another op has a larger `t`. The ops with `t ≤ T` are therefore a
//! causally complete set, and replaying them gives the text as it was at T.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const engine = @import("engine.zig");
const text = @import("text.zig");

/// Ops closer together than this (same replica) form one version.
pub const group_ms: i64 = 60_000;

pub const Version = struct {
    /// Time of the first and last op in the group (HLC ms, about wall time).
    t_first: i64,
    t_last: i64,
    replica: u64,
    /// UTF-16 units inserted and deleted.
    inserted: u64 = 0,
    deleted: u64 = 0,
    /// The group holds the note's creation.
    created: bool = false,
    /// Folder, pin and trash changes.
    other: u64 = 0,
};

const Op = struct { t: i64, r: u64, kind: enum { nc, ins, del, ns }, units: u64 };

fn noteIdString(buf: []u8, note: engine.Id) []const u8 {
    return std.fmt.bufPrint(buf, "n-{x:0>16}-{d}", .{ note.r, note.c }) catch unreachable;
}

/// Iterate over the ops of one note in `log`; calls `f(ctx, op_value, op)`.
fn eachOp(gpa: Allocator, log: []const u8, note: engine.Id, ctx: anytype, comptime f: anytype) !void {
    var idbuf: [48]u8 = undefined;
    const id = noteIdString(&idbuf, note);
    var rbuf: [24]u8 = undefined;
    const rhex = std.fmt.bufPrint(&rbuf, "\"{x:0>16}\"", .{note.r}) catch unreachable;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Cheap filter before parsing: the note id, or a note creation by its replica.
        if (std.mem.find(u8, line, id) == null and
            (std.mem.find(u8, line, "\"k\":\"nc\"") == null or std.mem.find(u8, line, rhex) == null)) continue;
        const parsed = json.parseFromSlice(json.Value, gpa, line, .{}) catch continue;
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => continue,
        };
        for (arr.items) |v| {
            const obj = switch (v) {
                .object => |o| o,
                else => continue,
            };
            const op = parseOp(obj, id, note) orelse continue;
            try f(ctx, v, op);
        }
    }
}

fn parseOp(obj: json.ObjectMap, id: []const u8, note: engine.Id) ?Op {
    const k = str(obj, "k") orelse return null;
    const t = switch (obj.get("t") orelse return null) {
        .integer => |i| i,
        else => return null,
    };
    const r = std.fmt.parseInt(u64, str(obj, "r") orelse return null, 16) catch return null;
    const c: u64 = switch (obj.get("c") orelse return null) {
        .integer => |i| if (i >= 0) @intCast(i) else return null,
        else => return null,
    };
    const eql = std.mem.eql;
    if (eql(u8, k, "nc")) {
        if (r != note.r or c != note.c) return null;
        return .{ .t = t, .r = r, .kind = .nc, .units = 0 };
    }
    if (!eql(u8, str(obj, "n") orelse return null, id)) return null;
    if (eql(u8, k, "ins")) {
        const s = str(obj, "s") orelse return null;
        return .{ .t = t, .r = r, .kind = .ins, .units = text.utf16Len(s) catch return null };
    }
    if (eql(u8, k, "del")) {
        var n: u64 = 0;
        const d = switch (obj.get("d") orelse return null) {
            .array => |a| a,
            else => return null,
        };
        for (d.items) |pair| switch (pair) {
            .array => |a| if (a.items.len == 2 and a.items[1] == .integer and a.items[1].integer > 0) {
                n += @intCast(a.items[1].integer);
            },
            else => {},
        };
        return .{ .t = t, .r = r, .kind = .del, .units = n };
    }
    if (eql(u8, k, "ns")) return .{ .t = t, .r = r, .kind = .ns, .units = 0 };
    return null;
}

fn str(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn opLess(_: void, a: Op, b: Op) bool {
    if (a.t != b.t) return a.t < b.t;
    return a.r < b.r;
}

/// The note's versions, oldest first. Caller frees the slice.
pub fn versions(gpa: Allocator, log: []const u8, note: engine.Id) ![]Version {
    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(gpa);
    const Ctx = struct {
        gpa: Allocator,
        ops: *std.ArrayList(Op),
        fn add(ctx: @This(), _: json.Value, op: Op) !void {
            try ctx.ops.append(ctx.gpa, op);
        }
    };
    try eachOp(gpa, log, note, Ctx{ .gpa = gpa, .ops = &ops }, Ctx.add);
    std.mem.sort(Op, ops.items, {}, opLess);

    var out: std.ArrayList(Version) = .empty;
    errdefer out.deinit(gpa);
    for (ops.items) |op| {
        const last = if (out.items.len > 0) &out.items[out.items.len - 1] else null;
        const v = if (last != null and last.?.replica == op.r and op.t - last.?.t_last <= group_ms) last.? else blk: {
            try out.append(gpa, .{ .t_first = op.t, .t_last = op.t, .replica = op.r });
            break :blk &out.items[out.items.len - 1];
        };
        v.t_last = op.t;
        switch (op.kind) {
            .nc => v.created = true,
            .ins => v.inserted += op.units,
            .del => v.deleted += op.units,
            .ns => v.other += 1,
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The note's text at time `at` (HLC ms): its ops with `t ≤ at` replayed
/// into a scratch engine. error.NoteDidNotExist if it was created later.
pub fn textAt(gpa: Allocator, log: []const u8, note: engine.Id, at: i64) ![]u8 {
    var batch: std.Io.Writer.Allocating = .init(gpa);
    defer batch.deinit();
    try batch.writer.writeByte('[');
    const Ctx = struct {
        w: *std.Io.Writer,
        at: i64,
        first: *bool,
        fn add(ctx: @This(), v: json.Value, op: Op) !void {
            if (op.t > ctx.at) return;
            if (!ctx.first.*) try ctx.w.writeByte(',');
            ctx.first.* = false;
            try json.Stringify.value(v, .{}, ctx.w);
        }
    };
    var first = true;
    try eachOp(gpa, log, note, Ctx{ .w = &batch.writer, .at = at, .first = &first }, Ctx.add);
    try batch.writer.writeByte(']');

    var e = try engine.Engine.init(gpa, 0);
    defer e.deinit();
    var events: std.ArrayList(u8) = .empty;
    defer events.deinit(gpa);
    try e.ingest(batch.written(), &events);
    const t = (try e.noteText(note)) orelse return error.NoteDidNotExist;
    return gpa.dupe(u8, t);
}

const testing = std.testing;

test "versions group a replica's edits; textAt replays up to a time" {
    const gpa = testing.allocator;
    var a = try engine.Engine.init(gpa, 0xa);
    defer a.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const Step = struct {
        fn run(e: *engine.Engine, l: *std.ArrayList(u8), o: *std.ArrayList(u8), now: i64, req: []const u8) !void {
            o.clearRetainingCapacity();
            try e.call(req, now, o);
            const ops = try e.takeNewOps(e.gpa);
            defer e.gpa.free(ops);
            try l.appendSlice(e.gpa, ops);
            try l.append(e.gpa, '\n');
        }
    };
    try Step.run(&a, &log, &out, 1_000_000, "{\"id\":1,\"cmd\":\"create\",\"text\":\"v1\\n\"}");
    const reply = try json.parseFromSlice(json.Value, gpa, out.items[0 .. std.mem.findScalar(u8, out.items, '\n').?], .{});
    defer reply.deinit();
    const nid = reply.value.object.get("note").?.string;
    const note = try engine.parseNoteId(nid);
    var buf: [256]u8 = undefined;
    // Same minute: same version.
    try Step.run(&a, &log, &out, 1_010_000, try std.fmt.bufPrint(&buf, "{{\"id\":2,\"cmd\":\"put\",\"note\":\"{s}\",\"text\":\"v2\\n\"}}", .{nid}));
    // Much later: a new version.
    try Step.run(&a, &log, &out, 2_000_000, try std.fmt.bufPrint(&buf, "{{\"id\":3,\"cmd\":\"put\",\"note\":\"{s}\",\"text\":\"v3 🎉\\n\"}}", .{nid}));
    // An unrelated note does not show up.
    try Step.run(&a, &log, &out, 2_000_100, "{\"id\":4,\"cmd\":\"create\",\"text\":\"other\"}");

    const vs = try versions(gpa, log.items, note);
    defer gpa.free(vs);
    try testing.expectEqual(@as(usize, 2), vs.len);
    try testing.expect(vs[0].created);
    try testing.expectEqual(@as(u64, 0xa), vs[0].replica);
    try testing.expectEqual(@as(u64, 4), vs[0].inserted); // "v1\n" + "2"
    try testing.expectEqual(@as(u64, 1), vs[0].deleted);
    try testing.expect(vs[1].t_first >= 2_000_000);

    // Creation and first insert are two ops, 1 ms apart.
    const t1 = try textAt(gpa, log.items, note, vs[0].t_first + 1);
    defer gpa.free(t1);
    try testing.expectEqualStrings("v1\n", t1);
    const t2 = try textAt(gpa, log.items, note, vs[0].t_last);
    defer gpa.free(t2);
    try testing.expectEqualStrings("v2\n", t2);
    const t3 = try textAt(gpa, log.items, note, vs[1].t_last);
    defer gpa.free(t3);
    try testing.expectEqualStrings("v3 🎉\n", t3);
    try testing.expectError(error.NoteDidNotExist, textAt(gpa, log.items, note, 999_999));
}
