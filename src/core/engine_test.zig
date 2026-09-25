//! Engine tests: protocol behaviour, replay, multi-replica convergence
//! (property tests with seeded randomness), and patch delivery to a client
//! whose edits cross remote patches in flight.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const json = std.json;

const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const ot = @import("ot.zig");
const text = @import("text.zig");

/// Run one request and return (reply, events) lines; caller frees via the arena.
fn call(e: *Engine, arena: Allocator, now: i64, comptime fmt: []const u8, args: anytype) ![]const u8 {
    const req = try std.fmt.allocPrint(arena, fmt, args);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(e.gpa);
    try e.call(req, now, &out);
    return arena.dupe(u8, out.items);
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.findScalar(u8, s, '\n') orelse s.len];
}

fn replyValue(arena: Allocator, lines: []const u8) !json.ObjectMap {
    const v = try json.parseFromSliceLeaky(json.Value, arena, firstLine(lines), .{});
    const obj = v.object;
    if (obj.get("ok").?.bool != true) {
        std.debug.print("request failed: {s}\n", .{lines});
        return error.RequestFailed;
    }
    return obj;
}

fn textOf(e: *Engine, arena: Allocator, note: []const u8) ![]const u8 {
    const id = try engine_mod.parseNoteId(note);
    const n = e.notes.get(id).?;
    const units = try n.seq.toUtf16(arena);
    return text.toUtf8(arena, units);
}

test "protocol basics: create, edit, list, tags, folders, search" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e = try Engine.init(testing.allocator, 0xabc);
    defer e.deinit();

    const hello = try replyValue(arena, try call(&e, arena, 1000, "{{\"id\":1,\"cmd\":\"hello\",\"client\":\"qml\"}}", .{}));
    try testing.expectEqualStrings("0000000000000abc", hello.get("replica").?.string);

    const f = try replyValue(arena, try call(&e, arena, 1001, "{{\"id\":2,\"cmd\":\"folder.create\",\"name\":\"Work\",\"parent\":null}}", .{}));
    const folder = f.get("folder").?.string;
    const created = try call(&e, arena, 1002, "{{\"id\":3,\"cmd\":\"create\",\"folder\":\"{s}\",\"text\":\"# Plan\\nship #Omajot 🎉\"}}", .{folder});
    const note = (try replyValue(arena, created)).get("note").?.string;
    try testing.expect(std.mem.find(u8, created, "{\"ev\":\"notes\"") != null);

    const opened = try replyValue(arena, try call(&e, arena, 1003, "{{\"id\":4,\"cmd\":\"open\",\"note\":\"{s}\"}}", .{note}));
    try testing.expectEqualStrings("# Plan\nship #Omajot 🎉", opened.get("text").?.string);

    // Replace "ship" with "launch" (UTF-16 positions: "# Plan\n" = 7).
    _ = try replyValue(arena, try call(&e, arena, 1004, "{{\"id\":5,\"cmd\":\"edit\",\"note\":\"{s}\",\"seq\":1,\"pos\":7,\"del\":4,\"ins\":\"launch\"}}", .{note}));
    try testing.expectEqualStrings("# Plan\nlaunch #Omajot 🎉", try textOf(&e, arena, note));
    // A resend of seq 1 is ignored.
    _ = try replyValue(arena, try call(&e, arena, 1005, "{{\"id\":6,\"cmd\":\"edit\",\"note\":\"{s}\",\"seq\":1,\"pos\":0,\"del\":0,\"ins\":\"X\"}}", .{note}));
    try testing.expectEqualStrings("# Plan\nlaunch #Omajot 🎉", try textOf(&e, arena, note));
    // Splitting the emoji is rejected.
    const bad = try call(&e, arena, 1006, "{{\"id\":7,\"cmd\":\"edit\",\"note\":\"{s}\",\"seq\":2,\"pos\":23,\"del\":0,\"ins\":\"x\"}}", .{note});
    try testing.expect(std.mem.find(u8, bad, "surrogate") != null);

    const list = try replyValue(arena, try call(&e, arena, 1007, "{{\"id\":8,\"cmd\":\"list\"}}", .{}));
    const summary = list.get("notes").?.array.items[0].object;
    try testing.expectEqualStrings("Plan", summary.get("title").?.string);
    try testing.expectEqualStrings("launch #Omajot 🎉", summary.get("snippet").?.string);
    try testing.expectEqualStrings("omajot", summary.get("tags").?.array.items[0].string);
    try testing.expectEqualStrings(folder, summary.get("folder").?.string);

    const found = try replyValue(arena, try call(&e, arena, 1008, "{{\"id\":9,\"cmd\":\"search\",\"q\":\"LAUNCH\"}}", .{}));
    try testing.expectEqual(@as(usize, 1), found.get("ids").?.array.items.len);

    // Deleting the folder files its notes under null.
    _ = try replyValue(arena, try call(&e, arena, 1009, "{{\"id\":10,\"cmd\":\"folder.delete\",\"folder\":\"{s}\"}}", .{folder}));
    const list2 = try replyValue(arena, try call(&e, arena, 1010, "{{\"id\":11,\"cmd\":\"list\"}}", .{}));
    try testing.expect(list2.get("notes").?.array.items[0].object.get("folder").? == .null);
    try testing.expectEqual(@as(usize, 0), list2.get("folders").?.array.items.len);

    const unknown = try call(&e, arena, 1011, "{{\"id\":12,\"cmd\":\"nope\"}}", .{});
    try testing.expect(std.mem.startsWith(u8, unknown, "{\"re\":12,\"ok\":false"));
    const paste = try call(&e, arena, 1012, "{{\"id\":13,\"cmd\":\"paste\",\"note\":\"{s}\",\"pos\":0}}", .{note});
    try testing.expect(std.mem.find(u8, paste, "\"ok\":false") != null);
}

test "folder moves into a descendant are rejected locally" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e = try Engine.init(testing.allocator, 1);
    defer e.deinit();
    const a = (try replyValue(arena, try call(&e, arena, 1, "{{\"id\":1,\"cmd\":\"folder.create\",\"name\":\"a\",\"parent\":null}}", .{}))).get("folder").?.string;
    const b = (try replyValue(arena, try call(&e, arena, 2, "{{\"id\":2,\"cmd\":\"folder.create\",\"name\":\"b\",\"parent\":\"{s}\"}}", .{a}))).get("folder").?.string;
    const r = try call(&e, arena, 3, "{{\"id\":3,\"cmd\":\"folder.move\",\"folder\":\"{s}\",\"parent\":\"{s}\"}}", .{ a, b });
    try testing.expect(std.mem.find(u8, r, "\"ok\":false") != null);
}

// ------------------------------------------------------ simulated replicas

const Sim = struct {
    gpa: Allocator,
    arena: Allocator,
    rnd: std.Random,
    engines: []Engine,
    batches: std.ArrayList([]const u8) = .empty,
    /// Per replica: every batch it produced or ingested, in order (replay test).
    logs: []std.ArrayList([]const u8),
    now: i64 = 1_700_000_000_000,
    next_id: i64 = 1,

    fn init(gpa: Allocator, arena: Allocator, rnd: std.Random, n: usize) !Sim {
        const engines = try arena.alloc(Engine, n);
        const logs = try arena.alloc(std.ArrayList([]const u8), n);
        for (engines, logs, 0..) |*e, *l, i| {
            e.* = try Engine.init(gpa, 0x1000 + i);
            l.* = .empty;
        }
        return .{ .gpa = gpa, .arena = arena, .rnd = rnd, .engines = engines, .logs = logs };
    }

    fn deinit(s: *Sim) void {
        for (s.engines) |*e| e.deinit();
    }

    fn req(s: *Sim, i: usize, comptime fmt: []const u8, args: anytype) ![]const u8 {
        // Skewed clocks: replica i runs i*7 ms ahead; time sometimes stalls.
        if (s.rnd.boolean()) s.now += 1;
        const lines = try call(&s.engines[i], s.arena, s.now + @as(i64, @intCast(i)) * 7, fmt, args);
        try s.collect(i);
        return lines;
    }

    fn collect(s: *Sim, i: usize) !void {
        const ops = try s.engines[i].takeNewOps(s.arena);
        if (ops.len > 2) {
            try s.batches.append(s.arena, ops);
            try s.logs[i].append(s.arena, ops);
        }
    }

    fn deliver(s: *Sim, i: usize, batch: []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(s.gpa);
        try s.engines[i].ingest(batch, &out);
        try testing.expect(std.mem.find(u8, out.items, "\"ev\":\"error\"") == null);
        try s.logs[i].append(s.arena, batch);
    }

    fn noteIds(s: *Sim, i: usize) ![]const []const u8 {
        var ids: std.ArrayList([]const u8) = .empty;
        var aw = std.Io.Writer.Allocating.init(s.arena);
        for (s.engines[i].notes.keys()) |id| {
            aw.clearRetainingCapacity();
            try aw.writer.print("n-{x:0>16}-{d}", .{ id.r, id.c });
            try ids.append(s.arena, try s.arena.dupe(u8, aw.written()));
        }
        return ids.items;
    }

    fn folderIds(s: *Sim, i: usize) ![]const []const u8 {
        const lines = try call(&s.engines[i], s.arena, s.now, "{{\"id\":0,\"cmd\":\"list\"}}", .{});
        const obj = try replyValue(s.arena, lines);
        var ids: std.ArrayList([]const u8) = .empty;
        for (obj.get("folders").?.array.items) |f| try ids.append(s.arena, f.object.get("id").?.string);
        return ids.items;
    }

    fn pick(s: *Sim, items: []const []const u8) ?[]const u8 {
        if (items.len == 0) return null;
        return items[s.rnd.uintLessThan(usize, items.len)];
    }

    /// A random boundary-aligned edit on replica i's note.
    fn randomEdit(s: *Sim, i: usize, note: []const u8, seq: u64) !void {
        const n = s.engines[i].notes.get(try engine_mod.parseNoteId(note)).?;
        const vis = n.seq.visible;
        var pos = s.rnd.uintLessThan(usize, vis + 1);
        if (pos > 0 and pos < vis and text.isLow(n.seq.unitAt(pos))) pos -= 1;
        var del: usize = 0;
        if (vis > pos and s.rnd.uintLessThan(u8, 3) == 0) {
            del = 1 + s.rnd.uintLessThan(usize, @min(vis - pos, 6));
            if (pos + del < vis and text.isLow(n.seq.unitAt(pos + del))) del += 1;
        }
        const words = [_][]const u8{ "a", "bc", "Grüße ", "🎉", "#tag ", "\\n", "x#y ", "" };
        const ins = words[s.rnd.uintLessThan(usize, words.len)];
        _ = try s.req(i, "{{\"id\":1,\"cmd\":\"edit\",\"note\":\"{s}\",\"seq\":{d},\"pos\":{d},\"del\":{d},\"ins\":\"{s}\"}}", .{ note, seq, pos, del, ins });
    }

    fn randomAction(s: *Sim, i: usize) !void {
        const notes = try s.noteIds(i);
        const folders = try s.folderIds(i);
        switch (s.rnd.uintLessThan(u8, 20)) {
            0, 1 => {
                if (s.pick(folders)) |f| {
                    _ = try s.req(i, "{{\"id\":1,\"cmd\":\"create\",\"folder\":\"{s}\",\"text\":\"Note {d}\\nbody\"}}", .{ f, s.next_id });
                } else {
                    _ = try s.req(i, "{{\"id\":1,\"cmd\":\"create\",\"folder\":null,\"text\":\"Note {d}\"}}", .{s.next_id});
                }
                s.next_id += 1;
            },
            2...11 => if (s.pick(notes)) |n| {
                // Seq numbers only matter for open notes; use a fresh high one.
                s.next_id += 1;
                try s.randomEdit(i, n, @intCast(s.next_id));
            },
            12 => if (s.pick(notes)) |n| {
                _ = try s.req(i, "{{\"id\":1,\"cmd\":\"set\",\"note\":\"{s}\",\"pinned\":{}}}", .{ n, s.rnd.boolean() });
            },
            13 => if (s.pick(notes)) |n| {
                _ = try s.req(i, "{{\"id\":1,\"cmd\":\"set\",\"note\":\"{s}\",\"trashed\":{}}}", .{ n, s.rnd.boolean() });
            },
            14 => if (s.pick(notes)) |n| {
                if (s.pick(folders)) |f| {
                    _ = try s.req(i, "{{\"id\":1,\"cmd\":\"set\",\"note\":\"{s}\",\"folder\":\"{s}\"}}", .{ n, f });
                } else {
                    _ = try s.req(i, "{{\"id\":1,\"cmd\":\"set\",\"note\":\"{s}\",\"folder\":null}}", .{n});
                }
            },
            15 => {
                if (s.pick(folders)) |p| {
                    _ = try s.req(i, "{{\"id\":1,\"cmd\":\"folder.create\",\"name\":\"F{d}\",\"parent\":\"{s}\"}}", .{ s.next_id, p });
                } else {
                    _ = try s.req(i, "{{\"id\":1,\"cmd\":\"folder.create\",\"name\":\"F{d}\",\"parent\":null}}", .{s.next_id});
                }
                s.next_id += 1;
            },
            16 => if (s.pick(folders)) |f| {
                _ = try s.req(i, "{{\"id\":1,\"cmd\":\"folder.rename\",\"folder\":\"{s}\",\"name\":\"R{d}\"}}", .{ f, s.next_id });
                s.next_id += 1;
            },
            17 => if (s.pick(folders)) |f| {
                // May be rejected locally (cycle); concurrent moves can still
                // create cycles across replicas, which the tree rule resolves.
                if (s.pick(folders)) |p| {
                    _ = try s.req(i, "{{\"id\":1,\"cmd\":\"folder.move\",\"folder\":\"{s}\",\"parent\":\"{s}\"}}", .{ f, p });
                } else {
                    _ = try s.req(i, "{{\"id\":1,\"cmd\":\"folder.move\",\"folder\":\"{s}\",\"parent\":null}}", .{f});
                }
            },
            18 => if (s.rnd.uintLessThan(u8, 3) == 0) if (s.pick(folders)) |f| {
                _ = try s.req(i, "{{\"id\":1,\"cmd\":\"folder.delete\",\"folder\":\"{s}\"}}", .{f});
            },
            else => { // partial, out-of-order, duplicated delivery
                const k = s.rnd.uintLessThan(usize, @min(s.batches.items.len, 6) + 1);
                var j: usize = 0;
                while (j < k) : (j += 1) {
                    const b = s.batches.items[s.rnd.uintLessThan(usize, s.batches.items.len)];
                    try s.deliver(i, b);
                }
            },
        }
    }

    fn syncAll(s: *Sim) !void {
        for (0..s.engines.len) |i| {
            const order = try s.arena.dupe([]const u8, s.batches.items);
            s.rnd.shuffle([]const u8, order);
            for (order) |b| try s.deliver(i, b);
            for (order[0 .. order.len / 2]) |b| try s.deliver(i, b); // duplicates
        }
    }

    fn expectConverged(s: *Sim, seed: u64) !void {
        const first = firstLine(try call(&s.engines[0], s.arena, s.now, "{{\"id\":9,\"cmd\":\"list\"}}", .{}));
        for (s.engines, 0..) |*e, i| {
            if (e.pendingCount() != 0) {
                std.debug.print("seed {d}: replica {d} has {d} pending ops\n", .{ seed, i, e.pendingCount() });
                return error.PendingOps;
            }
            const l = firstLine(try call(e, s.arena, s.now, "{{\"id\":9,\"cmd\":\"list\"}}", .{}));
            if (!std.mem.eql(u8, first, l)) {
                std.debug.print("seed {d}: list differs on replica {d}\n{s}\n{s}\n", .{ seed, i, first, l });
                return error.Diverged;
            }
            for (e.notes.keys()) |id| {
                const a = try s.engines[0].notes.get(id).?.seq.toUtf16(s.arena);
                const b = try e.notes.get(id).?.seq.toUtf16(s.arena);
                if (!std.mem.eql(u16, a, b)) {
                    std.debug.print("seed {d}: note text differs on replica {d}\n", .{ seed, i });
                    return error.Diverged;
                }
            }
        }
    }
};

test "property: replicas converge under random concurrent edits and delivery" {
    const replicas = 4;
    const steps = 150;
    const seeds = 30;
    var seed: u64 = 1;
    while (seed <= seeds) : (seed += 1) {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var prng = std.Random.DefaultPrng.init(seed);
        var sim = try Sim.init(testing.allocator, arena_state.allocator(), prng.random(), replicas);
        defer sim.deinit();
        var step: usize = 0;
        while (step < steps) : (step += 1) try sim.randomAction(sim.rnd.uintLessThan(usize, replicas));
        try sim.syncAll();
        try sim.expectConverged(seed);
    }
}

test "replaying a replica's own log restores its state and continues its counter" {
    var seed: u64 = 100;
    while (seed < 110) : (seed += 1) {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        var sim = try Sim.init(testing.allocator, arena, prng.random(), 3);
        defer sim.deinit();
        var step: usize = 0;
        while (step < 120) : (step += 1) try sim.randomAction(sim.rnd.uintLessThan(usize, 3));

        var fresh = try Engine.init(testing.allocator, sim.engines[0].replica);
        defer fresh.deinit();
        for (sim.logs[0].items) |b| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(testing.allocator);
            try fresh.ingest(b, &out);
        }
        const want = firstLine(try call(&sim.engines[0], arena, sim.now, "{{\"id\":1,\"cmd\":\"list\"}}", .{}));
        const got = firstLine(try call(&fresh, arena, sim.now, "{{\"id\":1,\"cmd\":\"list\"}}", .{}));
        try testing.expectEqualStrings(want, got);
        try testing.expectEqual(sim.engines[0].clock, fresh.clock);
        try testing.expectEqual(sim.engines[0].pendingCount(), fresh.pendingCount());

        // New local ops after replay never reuse an id.
        const created = try replyValue(arena, try call(&fresh, arena, sim.now, "{{\"id\":2,\"cmd\":\"create\",\"folder\":null,\"text\":\"after\"}}", .{}));
        const id = try engine_mod.parseNoteId(created.get("note").?.string);
        try testing.expect(id.c > sim.engines[0].clock);
    }
}

// ------------------------------------------------ client + remote patches

/// A reference client (what QML and the PWA implement): keeps its own text,
/// numbers its edits, transforms incoming patches over unacknowledged edits.
const Client = struct {
    gpa: Allocator,
    arena: Allocator,
    note: []const u8,
    text: std.ArrayList(u16) = .empty,
    seq: u64 = 0,
    last_pseq: u64 = 0,
    pending: []ot.Prim = &.{},

    fn edit(c: *Client, rnd: std.Random) ![]const u8 {
        const vis = c.text.items.len;
        var pos = rnd.uintLessThan(usize, vis + 1);
        if (pos > 0 and pos < vis and text.isLow(c.text.items[pos])) pos -= 1;
        var del: usize = 0;
        if (vis > pos and rnd.boolean()) {
            del = 1 + rnd.uintLessThan(usize, @min(vis - pos, 3));
            if (pos + del < vis and text.isLow(c.text.items[pos + del])) del += 1;
        }
        const choices = [_][]const u8{ "k", "ü", "🎉", "" };
        const ins = choices[rnd.uintLessThan(usize, choices.len)];
        const units = try text.toUtf16(c.arena, ins);
        c.seq += 1;
        var buf: [2]ot.Prim = undefined;
        const prims = ot.fromEdit(&buf, pos, del, units, c.seq);
        for (prims) |p| try ot.apply(c.gpa, &c.text, p);
        c.pending = try std.mem.concat(c.arena, ot.Prim, &.{ c.pending, prims });
        return std.fmt.allocPrint(c.arena, "{{\"id\":1,\"cmd\":\"edit\",\"note\":\"{s}\",\"seq\":{d},\"ack\":{d},\"pos\":{d},\"del\":{d},\"ins\":\"{s}\"}}", .{ c.note, c.seq, c.last_pseq, pos, del, ins });
    }

    fn onPatch(c: *Client, ev: json.ObjectMap) !void {
        const base: u64 = @intCast(ev.get("base").?.integer);
        const pseq: u64 = @intCast(ev.get("pseq").?.integer);
        const pos: usize = @intCast(ev.get("pos").?.integer);
        const del: usize = @intCast(ev.get("del").?.integer);
        const units = try text.toUtf16(c.arena, ev.get("ins").?.string);
        var keep: std.ArrayList(ot.Prim) = .empty;
        for (c.pending) |p| if (p.tag > base) try keep.append(c.arena, p);
        var buf: [2]ot.Prim = undefined;
        const patch = ot.fromEdit(&buf, pos, del, units, pseq);
        const r = try ot.xform(c.arena, patch, keep.items, true);
        c.pending = r.b;
        for (r.a) |p| try ot.apply(c.gpa, &c.text, p);
        c.last_pseq = pseq;
    }
};

test "property: a client's text matches the engine while edits and remote patches cross" {
    const gpa = testing.allocator;
    var total_patches: usize = 0;
    var total_crossed: usize = 0;
    var seed: u64 = 1;
    while (seed <= 100) : (seed += 1) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();

        var local = try Engine.init(gpa, 1);
        defer local.deinit();
        var remote = try Engine.init(gpa, 2);
        defer remote.deinit();

        const created = try replyValue(arena, try call(&remote, arena, 10, "{{\"id\":1,\"cmd\":\"create\",\"folder\":null,\"text\":\"shared 🎉 text\"}}", .{}));
        const note = created.get("note").?.string;
        var shuttle: std.ArrayList(u8) = .empty;
        defer shuttle.deinit(gpa);
        try local.ingest(try remote.takeNewOps(arena), &shuttle);

        const opened = try replyValue(arena, try call(&local, arena, 11, "{{\"id\":1,\"cmd\":\"open\",\"note\":\"{s}\"}}", .{note}));
        var client: Client = .{ .gpa = gpa, .arena = arena, .note = note };
        defer client.text.deinit(gpa);
        try client.text.appendSlice(gpa, try text.toUtf16(arena, opened.get("text").?.string));
        client.last_pseq = @intCast(opened.get("pseq").?.integer);

        var to_engine: std.ArrayList([]const u8) = .empty; // edit requests in flight
        var to_client: std.ArrayList(json.ObjectMap) = .empty; // patches in flight
        var remote_batches: std.ArrayList([]const u8) = .empty; // remote ops not yet ingested
        var local_batches: std.ArrayList([]const u8) = .empty; // local ops not yet at remote
        var now: i64 = 100;
        var patches_seen: usize = 0;
        var crossed: usize = 0;
        var step: usize = 0;
        while (step < 80 or to_engine.items.len + to_client.items.len + remote_batches.items.len > 0) : (step += 1) {
            now += 1;
            const choice = if (step < 80) rnd.uintLessThan(u8, 5) else 2 + rnd.uintLessThan(u8, 3);
            switch (choice) {
                0 => try to_engine.append(arena, try client.edit(rnd)),
                1 => { // the remote replica edits the same note
                    const n = remote.notes.get(try engine_mod.parseNoteId(note)).?;
                    const vis = n.seq.visible;
                    var pos = rnd.uintLessThan(usize, vis + 1);
                    if (pos > 0 and pos < vis and text.isLow(n.seq.unitAt(pos))) pos -= 1;
                    const del: usize = if (vis > pos and rnd.boolean()) 1 else 0;
                    const del2 = if (del == 1 and pos + 1 < vis and text.isLow(n.seq.unitAt(pos + 1))) @as(usize, 2) else del;
                    _ = try call(&remote, arena, now, "{{\"id\":1,\"cmd\":\"edit\",\"note\":\"{s}\",\"seq\":{d},\"pos\":{d},\"del\":{d},\"ins\":\"R\"}}", .{ note, step + 1, pos, del2 });
                    try remote_batches.append(arena, try remote.takeNewOps(arena));
                },
                2 => if (to_engine.items.len > 0) {
                    const r = to_engine.orderedRemove(0);
                    const lines = try call(&local, arena, now, "{s}", .{r});
                    _ = try replyValue(arena, lines);
                    const ops = try local.takeNewOps(arena);
                    if (ops.len > 2) try local_batches.append(arena, ops);
                },
                3 => if (remote_batches.items.len > 0) {
                    const b = remote_batches.orderedRemove(0);
                    var out: std.ArrayList(u8) = .empty;
                    defer out.deinit(gpa);
                    try local.ingest(b, &out);
                    var it = std.mem.splitScalar(u8, out.items, '\n');
                    while (it.next()) |line| {
                        if (line.len == 0) continue;
                        const v = try json.parseFromSliceLeaky(json.Value, arena, try arena.dupe(u8, line), .{});
                        if (std.mem.eql(u8, v.object.get("ev").?.string, "patch")) try to_client.append(arena, v.object);
                    }
                },
                else => if (to_client.items.len > 0) {
                    try client.onPatch(to_client.orderedRemove(0));
                    patches_seen += 1;
                    if (client.pending.len > 0) crossed += 1;
                },
            }
        }
        total_patches += patches_seen;
        total_crossed += crossed;
        const engine_text = try local.notes.get(try engine_mod.parseNoteId(note)).?.seq.toUtf16(arena);
        testing.expectEqualSlices(u16, engine_text, client.text.items) catch |err| {
            std.debug.print("client diverged from engine, seed {d}\n", .{seed});
            return err;
        };
        // And the two replicas converge.
        for (local_batches.items) |b| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            try remote.ingest(b, &out);
        }
        const remote_text = try remote.notes.get(try engine_mod.parseNoteId(note)).?.seq.toUtf16(arena);
        try testing.expectEqualSlices(u16, engine_text, remote_text);
    }
    // Coverage guard (seeds 1–100 must keep exercising crossing edits and patches).
    try testing.expect(total_patches > 1000);
    try testing.expect(total_crossed > 1000);
}

fn noteTimes(e: *Engine, arena: Allocator, now: i64, note: []const u8) ![2]i64 {
    const list = try replyValue(arena, try call(e, arena, now, "{{\"id\":90,\"cmd\":\"list\"}}", .{}));
    for (list.get("notes").?.array.items) |item| {
        const o = item.object;
        if (std.mem.eql(u8, o.get("id").?.string, note)) return .{ o.get("created").?.integer, o.get("updated").?.integer };
    }
    return error.NoteMissing;
}

test "create keeps imported created/updated times, on every replica" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var a = try Engine.init(testing.allocator, 0xa);
    defer a.deinit();
    var b = try Engine.init(testing.allocator, 0xb);
    defer b.deinit();

    const now: i64 = 1_790_000_000_000;
    const reply = try call(&a, arena, now, "{{\"id\":1,\"cmd\":\"create\",\"folder\":null,\"text\":\"Old note\\nbody\",\"created\":1000,\"updated\":5000}}", .{});
    const note = (try replyValue(arena, reply)).get("note").?.string;
    try testing.expectEqual([2]i64{ 1000, 5000 }, try noteTimes(&a, arena, now, note));

    const ops = try a.takeNewOps(testing.allocator);
    defer testing.allocator.free(ops);
    var events: std.ArrayList(u8) = .empty;
    defer events.deinit(testing.allocator);
    try b.ingest(ops, &events);
    try testing.expectEqual([2]i64{ 1000, 5000 }, try noteTimes(&b, arena, now, note));

    // The past stamps do not hold back the clock: the next edit is "now".
    _ = try replyValue(arena, try call(&a, arena, now, "{{\"id\":2,\"cmd\":\"open\",\"note\":\"{s}\"}}", .{note}));
    _ = try replyValue(arena, try call(&a, arena, now + 1, "{{\"id\":3,\"cmd\":\"edit\",\"note\":\"{s}\",\"seq\":1,\"pos\":0,\"del\":0,\"ins\":\"x\"}}", .{note}));
    try testing.expectEqual([2]i64{ 1000, now + 1 }, try noteTimes(&a, arena, now + 1, note));

    // Invalid combinations are ordinary request errors.
    const bad = [_][]const u8{
        "{\"id\":4,\"cmd\":\"create\",\"created\":6000,\"updated\":5000}",
        "{\"id\":5,\"cmd\":\"create\",\"created\":1000,\"updated\":1790000000001}",
        "{\"id\":6,\"cmd\":\"create\",\"updated\":5000}",
        "{\"id\":7,\"cmd\":\"create\",\"created\":0}",
    };
    for (bad) |req| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try a.call(req, now, &out);
        try testing.expect(std.mem.find(u8, out.items, "\"ok\":false") != null);
    }
}
