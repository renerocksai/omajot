//! The hub's durable batch log (docs/PROTOCOL.md §2): an append-only
//! `batches.jsonl`, one Stored batch per line, fsynced before a batch is
//! acknowledged. The whole log is indexed in memory at open; ops stay opaque
//! and are stored byte-for-byte as the client sent them.
//! Not thread-safe: the hub serializes calls with a mutex.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const rawjson = @import("rawjson.zig");

pub const file_name = "batches.jsonl";
/// Largest accepted POST /api/batches body.
pub const max_batch_bytes: usize = 1 << 20;
/// Soft cap on one GET /api/batches response body (one batch may exceed it alone).
pub const max_page_bytes: usize = 1 << 20;
pub const max_page_limit: u32 = 1000;
pub const default_page_limit: u32 = 200;
/// Largest log the hub loads at start.
pub const max_log_bytes: usize = 4 << 30;

pub const Appended = struct { seq: u64, head: u64, duplicate: bool };

const Key = struct { replica: u64, bseq: u64 };

pub const Store = struct {
    gpa: Allocator,
    io: Io,
    file: Io.File,
    end: u64,
    /// lines.items[i] is the Stored JSON of seq i+1, without the newline.
    /// Line bytes never move once appended, so slices of them stay valid.
    lines: std.ArrayList([]u8) = .empty,
    seen: std.AutoHashMapUnmanaged(Key, u64) = .empty,
    last_bseq: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// Bytes of a torn final line cut off by `open` (the caller logs it).
    dropped_bytes: usize = 0,

    /// Open (or create) the log in `dir` and index it. A torn final line from
    /// a crash mid-append is cut off; any other malformed line is an error.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir) !Store {
        const file = try dir.createFile(io, file_name, .{ .read = true, .truncate = false });
        errdefer file.close(io);
        var self: Store = .{ .gpa = gpa, .io = io, .file = file, .end = 0 };
        errdefer self.freeIndex();

        const contents = try dir.readFileAlloc(io, file_name, gpa, .limited(max_log_bytes));
        defer gpa.free(contents);
        var start: usize = 0;
        while (std.mem.findScalarPos(u8, contents, start, '\n')) |newline| {
            try self.index(contents[start..newline]);
            start = newline + 1;
        }
        self.end = start;
        if (start != contents.len) {
            self.dropped_bytes = contents.len - start;
            try file.setLength(io, start);
            try file.sync(io);
        }
        return self;
    }

    pub fn deinit(self: *Store) void {
        self.file.close(self.io);
        self.freeIndex();
        self.* = undefined;
    }

    fn freeIndex(self: *Store) void {
        for (self.lines.items) |line| self.gpa.free(line);
        self.lines.deinit(self.gpa);
        self.seen.deinit(self.gpa);
        self.last_bseq.deinit(self.gpa);
    }

    pub fn head(self: *const Store) u64 {
        return self.lines.items.len;
    }

    fn index(self: *Store, line: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, line, .{}) catch return error.CorruptStore;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |o| o,
            else => return error.CorruptStore,
        };
        const seq = intField(object, "seq") orelse return error.CorruptStore;
        if (seq != self.lines.items.len + 1) return error.CorruptStore;
        const header = parseHeader(object) catch return error.CorruptStore;
        try self.remember(header, try self.gpa.dupe(u8, line));
    }

    fn remember(self: *Store, header: Header, line: []u8) !void {
        errdefer self.gpa.free(line);
        try self.lines.ensureUnusedCapacity(self.gpa, 1);
        try self.seen.ensureUnusedCapacity(self.gpa, 1);
        try self.last_bseq.ensureUnusedCapacity(self.gpa, 1);
        self.lines.appendAssumeCapacity(line);
        const seq: u64 = self.lines.items.len;
        self.seen.putAssumeCapacity(.{ .replica = header.replica, .bseq = header.bseq }, seq);
        self.last_bseq.putAssumeCapacity(header.replica, header.bseq);
    }

    /// Validate and durably append one Batch. A repeated (replica, bseq)
    /// returns the original seq without writing.
    pub fn append(self: *Store, body: []const u8) !Appended {
        if (body.len > max_batch_bytes) return error.BatchTooLarge;
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch return error.InvalidBatch;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidBatch,
        };
        const header = try parseHeader(object);
        if (object.get("ops")) |ops| {
            if (ops != .array) return error.InvalidBatch;
        } else return error.InvalidBatch;

        if (self.seen.get(.{ .replica = header.replica, .bseq = header.bseq })) |seq|
            return .{ .seq = seq, .head = self.head(), .duplicate = true };
        const expected = (self.last_bseq.get(header.replica) orelse 0) + 1;
        if (header.bseq != expected) return error.OutOfOrder;

        const ops = (try rawjson.field(self.gpa, body, "ops")) orelse return error.InvalidBatch;
        const seq = self.head() + 1;
        const line = try std.fmt.allocPrint(self.gpa, "{{\"seq\":{d},\"replica\":\"{x:0>16}\",\"bseq\":{d},\"ops\":{s}}}\n", .{ seq, header.replica, header.bseq, ops });
        errdefer self.gpa.free(line);
        try self.file.writePositionalAll(self.io, line, self.end);
        try self.file.sync(self.io);
        self.end += line.len;
        // The newline is only on disk; memory keeps the bare JSON object.
        const bare = try self.gpa.realloc(line, line.len - 1);
        try self.remember(header, bare);
        return .{ .seq = seq, .head = self.head(), .duplicate = false };
    }

    /// Borrow up to `limit` Stored lines after `after`, stopping early once
    /// `max_page_bytes` would be exceeded (always at least one line if any).
    /// The slices stay valid for the Store's lifetime.
    pub fn page(self: *const Store, after: u64, limit: u32, out: *std.ArrayList([]const u8), gpa: Allocator) !void {
        const count = @min(limit, max_page_limit);
        var bytes: usize = 0;
        var seq = after;
        while (seq < self.head() and out.items.len < count) : (seq += 1) {
            const line = self.lines.items[seq];
            if (out.items.len > 0 and bytes + line.len > max_page_bytes) break;
            try out.append(gpa, line);
            bytes += line.len + 1;
        }
    }
};

const Header = struct { replica: u64, bseq: u64 };

fn parseHeader(object: std.json.ObjectMap) error{InvalidBatch}!Header {
    const replica_text = switch (object.get("replica") orelse return error.InvalidBatch) {
        .string => |s| s,
        else => return error.InvalidBatch,
    };
    const replica = parseReplica(replica_text) orelse return error.InvalidBatch;
    const bseq = intField(object, "bseq") orelse return error.InvalidBatch;
    if (bseq == 0) return error.InvalidBatch;
    return .{ .replica = replica, .bseq = bseq };
}

/// Exactly 16 lowercase hex digits.
pub fn parseReplica(text: []const u8) ?u64 {
    if (text.len != 16) return null;
    for (text) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return null;
    return std.fmt.parseInt(u64, text, 16) catch null;
}

fn intField(object: std.json.ObjectMap, name: []const u8) ?u64 {
    return switch (object.get(name) orelse return null) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn batch(buf: []u8, replica: []const u8, bseq: u64, ops: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"replica\":\"{s}\",\"bseq\":{d},\"ops\":{s}}}", .{ replica, bseq, ops }) catch unreachable;
}

test "append assigns seqs, stores ops verbatim, and is idempotent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(testing.allocator, testing.io, tmp.dir);
    defer store.deinit();
    var buf: [256]u8 = undefined;

    const a = try store.append(batch(&buf, "00000000000000aa", 1, "[{\"x\": 1.50e3}]"));
    try testing.expectEqual(Appended{ .seq = 1, .head = 1, .duplicate = false }, a);
    const b = try store.append(batch(&buf, "00000000000000bb", 1, "[]"));
    try testing.expectEqual(@as(u64, 2), b.seq);
    const again = try store.append(batch(&buf, "00000000000000aa", 1, "[{\"x\": 1.50e3}]"));
    try testing.expectEqual(Appended{ .seq = 1, .head = 2, .duplicate = true }, again);
    try testing.expectEqualStrings(
        "{\"seq\":1,\"replica\":\"00000000000000aa\",\"bseq\":1,\"ops\":[{\"x\": 1.50e3}]}",
        store.lines.items[0],
    );
}

test "append rejects gaps, bad replicas and non-array ops" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(testing.allocator, testing.io, tmp.dir);
    defer store.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectError(error.OutOfOrder, store.append(batch(&buf, "00000000000000aa", 2, "[]")));
    try testing.expectError(error.InvalidBatch, store.append(batch(&buf, "00000000000000AA", 1, "[]")));
    try testing.expectError(error.InvalidBatch, store.append(batch(&buf, "aa", 1, "[]")));
    try testing.expectError(error.InvalidBatch, store.append(batch(&buf, "00000000000000aa", 0, "[]")));
    try testing.expectError(error.InvalidBatch, store.append(batch(&buf, "00000000000000aa", 1, "{}")));
    try testing.expectError(error.InvalidBatch, store.append("not json"));
    try testing.expectEqual(@as(u64, 0), store.head());
}

test "append rejects oversized batches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(testing.allocator, testing.io, tmp.dir);
    defer store.deinit();
    const big = try testing.allocator.alloc(u8, max_batch_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try testing.expectError(error.BatchTooLarge, store.append(big));
}

test "reopen rebuilds the index and drops a torn last line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    {
        var store = try Store.open(testing.allocator, testing.io, tmp.dir);
        defer store.deinit();
        _ = try store.append(batch(&buf, "00000000000000aa", 1, "[1]"));
        _ = try store.append(batch(&buf, "00000000000000aa", 2, "[2]"));
    }
    {
        // Simulate a crash in the middle of writing a third line.
        const file = try tmp.dir.openFile(testing.io, file_name, .{ .mode = .read_write });
        defer file.close(testing.io);
        const len = try file.length(testing.io);
        try file.writePositionalAll(testing.io, "{\"seq\":3,\"repl", len);
    }
    var store = try Store.open(testing.allocator, testing.io, tmp.dir);
    defer store.deinit();
    try testing.expectEqual(@as(u64, 2), store.head());
    try testing.expectEqual(@as(usize, 14), store.dropped_bytes);
    // Idempotency and ordering survive the restart.
    try testing.expect((try store.append(batch(&buf, "00000000000000aa", 2, "[2]"))).duplicate);
    const next = try store.append(batch(&buf, "00000000000000aa", 3, "[3]"));
    try testing.expectEqual(@as(u64, 3), next.seq);

    var again = try Store.open(testing.allocator, testing.io, tmp.dir);
    defer again.deinit();
    try testing.expectEqual(@as(u64, 3), again.head());
}

test "page honours after, limit and the byte cap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(testing.allocator, testing.io, tmp.dir);
    defer store.deinit();
    var buf: [256]u8 = undefined;
    for (1..6) |i| _ = try store.append(batch(&buf, "00000000000000aa", i, "[]"));

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(testing.allocator);
    try store.page(2, 2, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(std.mem.startsWith(u8, out.items[0], "{\"seq\":3,"));

    out.clearRetainingCapacity();
    try store.page(5, 10, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    out.clearRetainingCapacity();
    try store.page(0, 1_000_000, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 5), out.items.len);
}

test "page stops at the byte cap but always returns one batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(testing.allocator, testing.io, tmp.dir);
    defer store.deinit();
    const ops = try testing.allocator.alloc(u8, 700 * 1024);
    defer testing.allocator.free(ops);
    @memset(ops, ' ');
    ops[0] = '[';
    ops[ops.len - 1] = ']';
    const body_buf = try testing.allocator.alloc(u8, ops.len + 128);
    defer testing.allocator.free(body_buf);
    for (1..4) |i| _ = try store.append(batch(body_buf, "00000000000000aa", i, ops));

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(testing.allocator);
    try store.page(0, 100, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}
