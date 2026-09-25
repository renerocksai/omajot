//! The desktop replica's files (docs/PROTOCOL.md §4):
//!
//!   replica.json    {"replica":"<hex16>","cursor":N,"next_bseq":K}
//!   ops.jsonl       every ops array this replica has applied, one per line
//!   outbox.jsonl    local ops arrays not yet acknowledged by the hub
//!   inflight.json   the Batch currently being sent, kept byte-identical
//!                   across retries so (replica, bseq) stays idempotent
//!   uploads.pending attachment names still to upload
//!
//! On start, ops.jsonl, then outbox.jsonl, then inflight.json are replayed
//! into the engine (ingest is idempotent), so a crash between writes can't
//! lose ops or make the engine reuse op counters. Everything that goes to
//! the hub is fsynced first. Not thread-safe; the daemon holds a lock.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const rawjson = @import("../hub/rawjson.zig");

/// Upper bound on the ops bytes merged into one Batch (hub accepts 1 MiB bodies).
pub const max_batch_ops_bytes: usize = 768 * 1024;
pub const max_file_bytes: usize = 1 << 30;

pub const Inflight = struct { bseq: u64, count: usize, body: []u8 };

pub const Replica = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    id: u64,
    cursor: u64 = 0,
    next_bseq: u64 = 1,
    outbox: std.ArrayList([]u8) = .empty,
    inflight: ?Inflight = null,
    uploads: std.ArrayList([]u8) = .empty,
    ops_file: Io.File,
    ops_end: u64,
    outbox_file: Io.File,
    outbox_end: u64,

    /// Open `dir` (created by the caller), creating a fresh replica id on first use.
    /// `replay.begin(id)` is called first (so the engine can be created for
    /// this id), then `replay.ops(line)` for every stored ops array in order.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, replay: anytype) !Replica {
        var id: u64 = 0;
        var cursor: u64 = 0;
        var next_bseq: u64 = 1;
        if (dir.readFileAlloc(io, "replica.json", gpa, .limited(4096))) |text| {
            defer gpa.free(text);
            const parsed = try std.json.parseFromSlice(struct { replica: []const u8, cursor: u64 = 0, next_bseq: u64 = 1 }, gpa, text, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            id = std.fmt.parseInt(u64, parsed.value.replica, 16) catch return error.CorruptReplica;
            cursor = parsed.value.cursor;
            next_bseq = parsed.value.next_bseq;
        } else |err| switch (err) {
            error.FileNotFound => {
                while (id == 0) {
                    var bytes: [8]u8 = undefined;
                    io.random(&bytes);
                    id = std.mem.readInt(u64, &bytes, .little);
                }
            },
            else => return err,
        }

        const ops_file = try dir.createFile(io, "ops.jsonl", .{ .read = true, .truncate = false });
        errdefer ops_file.close(io);
        const outbox_file = try dir.createFile(io, "outbox.jsonl", .{ .read = true, .truncate = false });
        errdefer outbox_file.close(io);

        var self: Replica = .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .id = id,
            .cursor = cursor,
            .next_bseq = next_bseq,
            .ops_file = ops_file,
            .ops_end = 0,
            .outbox_file = outbox_file,
            .outbox_end = 0,
        };
        errdefer self.freeMemory();

        try replay.begin(id);
        self.ops_end = try replayLines(gpa, io, dir, "ops.jsonl", replay, null);
        self.outbox_end = try replayLines(gpa, io, dir, "outbox.jsonl", replay, &self.outbox);
        if (dir.readFileAlloc(io, "inflight.json", gpa, .limited(max_file_bytes))) |body| {
            errdefer gpa.free(body);
            const parsed = try std.json.parseFromSlice(struct { bseq: u64, count: usize }, gpa, (try rawjson.field(gpa, body, "meta")) orelse return error.CorruptReplica, .{});
            defer parsed.deinit();
            const batch = (try rawjson.field(gpa, body, "batch")) orelse return error.CorruptReplica;
            const ops = (try rawjson.field(gpa, batch, "ops")) orelse return error.CorruptReplica;
            try replay.ops(ops);
            const batch_copy = try gpa.dupe(u8, batch);
            gpa.free(body);
            self.inflight = .{ .bseq = parsed.value.bseq, .count = parsed.value.count, .body = batch_copy };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        if (dir.readFileAlloc(io, "uploads.pending", gpa, .limited(max_file_bytes))) |text| {
            defer gpa.free(text);
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |line| try self.uploads.append(gpa, try gpa.dupe(u8, line));
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try self.saveState();
        return self;
    }

    pub fn deinit(self: *Replica) void {
        self.ops_file.close(self.io);
        self.outbox_file.close(self.io);
        self.freeMemory();
        self.* = undefined;
    }

    fn freeMemory(self: *Replica) void {
        for (self.outbox.items) |o| self.gpa.free(o);
        self.outbox.deinit(self.gpa);
        if (self.inflight) |f| self.gpa.free(f.body);
        for (self.uploads.items) |u| self.gpa.free(u);
        self.uploads.deinit(self.gpa);
    }

    pub fn idHex(self: *const Replica) [16]u8 {
        var buf: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{x:0>16}", .{self.id}) catch unreachable;
        return buf;
    }

    /// Batches not yet acknowledged: the inflight one plus queued ops arrays.
    pub fn pending(self: *const Replica) usize {
        return self.outbox.items.len + @intFromBool(self.inflight != null);
    }

    /// Ops produced locally: durable in ops.jsonl and queued in the outbox.
    pub fn recordLocal(self: *Replica, ops: []const u8) !void {
        const copy = try self.gpa.dupe(u8, ops);
        errdefer self.gpa.free(copy);
        try self.outbox.ensureUnusedCapacity(self.gpa, 1);
        // Outbox first: replay covers both files, so either order is safe.
        try appendLine(self.io, self.outbox_file, &self.outbox_end, ops);
        try appendLine(self.io, self.ops_file, &self.ops_end, ops);
        self.outbox.appendAssumeCapacity(copy);
    }

    /// Ops from another replica (via the hub).
    pub fn recordRemote(self: *Replica, ops: []const u8) !void {
        try appendLine(self.io, self.ops_file, &self.ops_end, ops);
    }

    /// The Batch to send next, or null if nothing is pending. The same bytes
    /// are returned until `ackInflight`, including after a restart.
    pub fn nextBatch(self: *Replica) !?[]const u8 {
        if (self.inflight) |f| return f.body;
        if (self.outbox.items.len == 0) return null;
        var count: usize = 0;
        var bytes: usize = 0;
        while (count < self.outbox.items.len) : (count += 1) {
            const len = self.outbox.items[count].len;
            if (count > 0 and bytes + len > max_batch_ops_bytes) break;
            bytes += len;
        }
        const ops = try rawjson.concatArrays(self.gpa, self.outbox.items[0..count]);
        defer self.gpa.free(ops);
        const hex = self.idHex();
        const body = try std.fmt.allocPrint(self.gpa, "{{\"replica\":\"{s}\",\"bseq\":{d},\"ops\":{s}}}", .{ &hex, self.next_bseq, ops });
        errdefer self.gpa.free(body);
        // Everything the hub may acknowledge must already be durable here.
        try self.ops_file.sync(self.io);
        try self.outbox_file.sync(self.io);
        const record = try std.fmt.allocPrint(self.gpa, "{{\"meta\":{{\"bseq\":{d},\"count\":{d}}},\"batch\":{s}}}", .{ self.next_bseq, count, body });
        defer self.gpa.free(record);
        try writeAtomic(self.io, self.dir, "inflight.json", record);
        self.inflight = .{ .bseq = self.next_bseq, .count = count, .body = body };
        return body;
    }

    /// The hub stored the inflight batch.
    pub fn ackInflight(self: *Replica) !void {
        const f = self.inflight orelse return;
        const count = @min(f.count, self.outbox.items.len);
        for (self.outbox.items[0..count]) |o| self.gpa.free(o);
        self.outbox.replaceRangeAssumeCapacity(0, count, &.{});
        try self.rewriteOutbox();
        self.next_bseq = f.bseq + 1;
        try self.saveState();
        self.dir.deleteFile(self.io, "inflight.json") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        self.gpa.free(f.body);
        self.inflight = null;
    }

    pub fn setCursor(self: *Replica, cursor: u64) !void {
        if (cursor == self.cursor) return;
        self.cursor = cursor;
        try self.saveState();
    }

    pub fn addUpload(self: *Replica, name: []const u8) !void {
        for (self.uploads.items) |u| if (std.mem.eql(u8, u, name)) return;
        try self.uploads.append(self.gpa, try self.gpa.dupe(u8, name));
        try self.saveUploads();
    }

    pub fn removeUpload(self: *Replica, name: []const u8) !void {
        for (self.uploads.items, 0..) |u, i| if (std.mem.eql(u8, u, name)) {
            self.gpa.free(self.uploads.orderedRemove(i));
            return self.saveUploads();
        };
    }

    fn saveUploads(self: *Replica) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        for (self.uploads.items) |u| {
            try text.appendSlice(self.gpa, u);
            try text.append(self.gpa, '\n');
        }
        try writeAtomic(self.io, self.dir, "uploads.pending", text.items);
    }

    fn saveState(self: *Replica) !void {
        var buf: [128]u8 = undefined;
        const hex = self.idHex();
        const text = try std.fmt.bufPrint(&buf, "{{\"replica\":\"{s}\",\"cursor\":{d},\"next_bseq\":{d}}}\n", .{ &hex, self.cursor, self.next_bseq });
        try writeAtomic(self.io, self.dir, "replica.json", text);
    }

    fn rewriteOutbox(self: *Replica) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        for (self.outbox.items) |o| {
            try text.appendSlice(self.gpa, o);
            try text.append(self.gpa, '\n');
        }
        self.outbox_file.close(self.io);
        try writeAtomic(self.io, self.dir, "outbox.jsonl", text.items);
        self.outbox_file = try self.dir.openFile(self.io, "outbox.jsonl", .{ .mode = .read_write });
        self.outbox_end = text.items.len;
    }
};

fn appendLine(io: Io, file: Io.File, end: *u64, line: []const u8) !void {
    try file.writePositionalAll(io, line, end.*);
    try file.writePositionalAll(io, "\n", end.* + line.len);
    end.* += line.len + 1;
}

/// Replay complete lines; a torn last line (crash mid-append) is cut off.
/// Returns the byte length of the valid prefix.
fn replayLines(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8, replay: anytype, keep: ?*std.ArrayList([]u8)) !u64 {
    const contents = try dir.readFileAlloc(io, name, gpa, .limited(max_file_bytes));
    defer gpa.free(contents);
    var start: usize = 0;
    while (std.mem.findScalarPos(u8, contents, start, '\n')) |newline| {
        const line = contents[start..newline];
        start = newline + 1;
        if (line.len == 0) continue;
        try replay.ops(line);
        if (keep) |list| try list.append(gpa, try gpa.dupe(u8, line));
    }
    if (start != contents.len) {
        const file = try dir.openFile(io, name, .{ .mode = .read_write });
        defer file.close(io);
        try file.setLength(io, start);
    }
    return start;
}

pub fn writeAtomic(io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    var tmp_buf: [64]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name});
    {
        const file = try dir.createFile(io, tmp, .{});
        defer file.close(io);
        try file.writePositionalAll(io, data, 0);
        try file.sync(io);
    }
    try dir.rename(tmp, dir, name, io);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Recorder = struct {
    seen: std.ArrayList([]const u8) = .empty,
    arena: std.heap.ArenaAllocator = .init(testing.allocator),
    fn begin(_: *Recorder, _: u64) !void {}
    fn ops(self: *Recorder, line: []const u8) !void {
        try self.seen.append(self.arena.allocator(), try self.arena.allocator().dupe(u8, line));
    }
    fn deinit(self: *Recorder) void {
        self.arena.deinit();
    }
};

test "first open creates an id; batches are stable until acked; state survives restarts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var first_id: u64 = 0;
    var first_body: []u8 = undefined;
    {
        var rec: Recorder = .{};
        defer rec.deinit();
        var r = try Replica.open(testing.allocator, testing.io, tmp.dir, &rec);
        defer r.deinit();
        first_id = r.id;
        try testing.expect(r.id != 0);
        try r.recordLocal("[1]");
        try r.recordLocal("[2,3]");
        try r.recordRemote("[\"remote\"]");
        const body = (try r.nextBatch()).?;
        first_body = try testing.allocator.dupe(u8, body);
        try testing.expect(std.mem.endsWith(u8, body, "\"bseq\":1,\"ops\":[1,2,3]}"));
        // Another local edit while the batch is in flight stays queued.
        try r.recordLocal("[4]");
        try testing.expectEqualStrings(body, (try r.nextBatch()).?);
    }
    defer testing.allocator.free(first_body);
    {
        // Crash before the ack: same batch again, all ops replayed.
        var rec: Recorder = .{};
        defer rec.deinit();
        var r = try Replica.open(testing.allocator, testing.io, tmp.dir, &rec);
        defer r.deinit();
        try testing.expectEqual(first_id, r.id);
        try testing.expectEqualStrings(first_body, (try r.nextBatch()).?);
        try testing.expectEqual(@as(usize, 8), rec.seen.items.len); // 4 ops lines + 3 outbox lines + inflight
        try r.ackInflight();
        try testing.expectEqual(@as(usize, 1), r.pending());
        const next = (try r.nextBatch()).?;
        try testing.expect(std.mem.endsWith(u8, next, "\"bseq\":2,\"ops\":[4]}"));
        try r.ackInflight();
        try testing.expectEqual(@as(usize, 0), r.pending());
        try testing.expect(try r.nextBatch() == null);
        try r.setCursor(42);
    }
    {
        var rec: Recorder = .{};
        defer rec.deinit();
        var r = try Replica.open(testing.allocator, testing.io, tmp.dir, &rec);
        defer r.deinit();
        try testing.expectEqual(@as(u64, 42), r.cursor);
        try testing.expectEqual(@as(u64, 3), r.next_bseq);
        try testing.expectEqual(@as(usize, 0), r.pending());
        try testing.expectEqual(@as(usize, 4), rec.seen.items.len);
    }
}

test "a torn ops line is dropped on open" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ops.jsonl", .data = "[1]\n[2]\n[3" });
    var rec: Recorder = .{};
    defer rec.deinit();
    var r = try Replica.open(testing.allocator, testing.io, tmp.dir, &rec);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), rec.seen.items.len);
    try r.recordRemote("[9]");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("[1]\n[2]\n[9]\n", try tmp.dir.readFile(testing.io, "ops.jsonl", &buf));
}

test "batches respect the size cap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rec: Recorder = .{};
    defer rec.deinit();
    var r = try Replica.open(testing.allocator, testing.io, tmp.dir, &rec);
    defer r.deinit();
    const big = try testing.allocator.alloc(u8, 500 * 1024);
    defer testing.allocator.free(big);
    @memset(big, '1');
    big[0] = '[';
    big[big.len - 1] = ']';
    try r.recordLocal(big);
    try r.recordLocal(big);
    try r.recordLocal("[7]");
    _ = (try r.nextBatch()).?;
    try testing.expectEqual(@as(usize, 1), r.inflight.?.count);
    try r.ackInflight();
    _ = (try r.nextBatch()).?;
    try testing.expectEqual(@as(usize, 2), r.inflight.?.count);
}

test "uploads persist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var rec: Recorder = .{};
        defer rec.deinit();
        var r = try Replica.open(testing.allocator, testing.io, tmp.dir, &rec);
        defer r.deinit();
        try r.addUpload("a.png");
        try r.addUpload("b.png");
        try r.addUpload("a.png");
        try r.removeUpload("a.png");
    }
    var rec: Recorder = .{};
    defer rec.deinit();
    var r = try Replica.open(testing.allocator, testing.io, tmp.dir, &rec);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.uploads.items.len);
    try testing.expectEqualStrings("b.png", r.uploads.items[0]);
}
