//! Content-addressed attachments (docs/PROTOCOL.md §2): `<sha256hex>.<ext>`,
//! immutable, verified against the body's hash before they become visible.
const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const dir_name = "blobs";
pub const max_blob_bytes: usize = 16 << 20;
pub const max_ext_len = 10;

/// `<64 lowercase hex>.<1-10 lowercase alnum>`. Also rules out path traversal.
pub fn validName(name: []const u8) bool {
    if (name.len < 66 or name.len > 65 + max_ext_len or name[64] != '.') return false;
    for (name[0..64]) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    for (name[65..]) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'z'))) return false;
    return true;
}

pub fn contentType(name: []const u8) []const u8 {
    const ext = name[(std.mem.findScalarLast(u8, name, '.') orelse return "application/octet-stream") + 1 ..];
    const table = [_]struct { []const u8, []const u8 }{
        .{ "png", "image/png" },       .{ "jpg", "image/jpeg" },       .{ "jpeg", "image/jpeg" },
        .{ "gif", "image/gif" },       .{ "webp", "image/webp" },      .{ "avif", "image/avif" },
        .{ "svg", "image/svg+xml" },   .{ "bmp", "image/bmp" },        .{ "ico", "image/x-icon" },
        .{ "heic", "image/heic" },     .{ "pdf", "application/pdf" },  .{ "txt", "text/plain; charset=utf-8" },
        .{ "md", "text/markdown; charset=utf-8" }, .{ "mp4", "video/mp4" }, .{ "mov", "video/quicktime" },
        .{ "mp3", "audio/mpeg" },      .{ "m4a", "audio/mp4" },        .{ "zip", "application/zip" },
    };
    for (table) |entry| if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
    return "application/octet-stream";
}

pub fn hexDigest(digest: [Sha256.digest_length]u8) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

pub const Saved = enum { created, existed };

/// Write `chunks` (the body, possibly split) to `dir/<name>` if its sha256
/// matches the name. The file appears atomically (temp file + rename).
pub fn save(io: Io, dir: Io.Dir, name: []const u8, chunks: []const []const u8, tmp_suffix: u64) !Saved {
    if (!validName(name)) return error.InvalidName;
    var total: usize = 0;
    var hasher = Sha256.init(.{});
    for (chunks) |chunk| {
        total += chunk.len;
        hasher.update(chunk);
    }
    if (total > max_blob_bytes) return error.BlobTooLarge;
    const hex = hexDigest(hasher.finalResult());
    if (!std.mem.eql(u8, &hex, name[0..64])) return error.HashMismatch;
    if (exists(io, dir, name)) return .existed;

    var tmp_buf: [96]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_buf, ".tmp-{s}-{x}", .{ name[0..16], tmp_suffix });
    {
        const file = try dir.createFile(io, tmp_name, .{});
        defer file.close(io);
        var offset: u64 = 0;
        for (chunks) |chunk| {
            try file.writePositionalAll(io, chunk, offset);
            offset += chunk.len;
        }
        try file.sync(io);
    }
    errdefer dir.deleteFile(io, tmp_name) catch {};
    try dir.rename(tmp_name, dir, name, io);
    return .created;
}

pub fn exists(io: Io, dir: Io.Dir, name: []const u8) bool {
    dir.access(io, name, .{}) catch return false;
    return true;
}

/// Largest single request body for a blob chunk (and bounded/http's max_body):
/// the engine reserves 2 × max_body per connection up front, so blobs above
/// this are uploaded in resumable chunks.
pub const max_chunk_bytes: usize = 1 << 20;

pub const Chunked = union(enum) {
    /// Bytes stored so far; more chunks are expected.
    partial: u64,
    created,
    existed,
};

/// Append one chunk of a resumable upload to `.part-<name>`. `offset` must
/// equal the bytes already received (else error.OffsetMismatch; `received`
/// tells the client where to resume). When `offset + chunk.len == total`, the
/// part is hashed; on a match it becomes `<name>`, otherwise it is deleted.
/// Callers serialize calls for the same name.
pub fn appendChunk(io: Io, dir: Io.Dir, name: []const u8, offset: u64, total: u64, chunk: []const u8, received: *u64) !Chunked {
    if (!validName(name)) return error.InvalidName;
    if (total > max_blob_bytes) return error.BlobTooLarge;
    if (chunk.len > max_chunk_bytes or offset + chunk.len > total) return error.BadChunk;
    if (exists(io, dir, name)) return .existed;

    var part_buf: [96]u8 = undefined;
    const part_name = try std.fmt.bufPrint(&part_buf, ".part-{s}", .{name});
    const file = try dir.createFile(io, part_name, .{ .read = true, .truncate = false });
    var closed = false;
    defer if (!closed) file.close(io);
    const have = try file.length(io);
    received.* = have;
    if (offset != have) return error.OffsetMismatch;
    try file.writePositionalAll(io, chunk, offset);
    const now = offset + chunk.len;
    received.* = now;
    if (now < total) return .{ .partial = now };

    try file.sync(io);
    var hasher = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var position: u64 = 0;
    while (position < now) {
        const n = try file.readPositional(io, &.{&buffer}, position);
        if (n == 0) break;
        hasher.update(buffer[0..n]);
        position += n;
    }
    file.close(io);
    closed = true;
    const hex = hexDigest(hasher.finalResult());
    if (!std.mem.eql(u8, &hex, name[0..64])) {
        dir.deleteFile(io, part_name) catch {};
        received.* = 0;
        return error.HashMismatch;
    }
    try dir.rename(part_name, dir, name, io);
    return .created;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn nameFor(bytes: []const u8, ext: []const u8, buf: []u8) []const u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ hexDigest(digest), ext }) catch unreachable;
}

test "validName" {
    var buf: [96]u8 = undefined;
    try testing.expect(validName(nameFor("x", "png", &buf)));
    try testing.expect(!validName("../etc/passwd"));
    try testing.expect(!validName(nameFor("x", "PNG", &buf)));
    try testing.expect(!validName(nameFor("x", "toolongextension", &buf)));
    const n = nameFor("x", "png", &buf);
    var upper: [80]u8 = undefined;
    @memcpy(upper[0..n.len], n);
    upper[0] = 'A';
    try testing.expect(!validName(upper[0..n.len]));
}

test "save checks the hash, is idempotent, and joins chunks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [80]u8 = undefined;
    const name = nameFor("hello world", "txt", &buf);
    try testing.expectEqual(Saved.created, try save(testing.io, tmp.dir, name, &.{ "hello ", "world" }, 1));
    try testing.expectEqual(Saved.existed, try save(testing.io, tmp.dir, name, &.{"hello world"}, 2));
    try testing.expectError(error.HashMismatch, save(testing.io, tmp.dir, name, &.{"tampered"}, 3));
    var read_buf: [32]u8 = undefined;
    const contents = try tmp.dir.readFile(testing.io, name, &read_buf);
    try testing.expectEqualStrings("hello world", contents);
    try testing.expectError(error.InvalidName, save(testing.io, tmp.dir, "x.png", &.{"x"}, 4));
}

test "appendChunk resumes, rejects bad offsets, and verifies the hash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [96]u8 = undefined;
    const name = nameFor("abcdefgh", "bin", &buf);
    var got: u64 = 0;
    try testing.expectEqual(Chunked{ .partial = 3 }, try appendChunk(testing.io, tmp.dir, name, 0, 8, "abc", &got));
    try testing.expectError(error.OffsetMismatch, appendChunk(testing.io, tmp.dir, name, 0, 8, "abc", &got));
    try testing.expectEqual(@as(u64, 3), got);
    try testing.expectEqual(Chunked.created, try appendChunk(testing.io, tmp.dir, name, 3, 8, "defgh", &got));
    try testing.expectEqual(Chunked.existed, try appendChunk(testing.io, tmp.dir, name, 0, 8, "abc", &got));
    var read_buf: [16]u8 = undefined;
    try testing.expectEqualStrings("abcdefgh", try tmp.dir.readFile(testing.io, name, &read_buf));

    const other = nameFor("12345678", "bin", &buf);
    _ = try appendChunk(testing.io, tmp.dir, other, 0, 8, "1234", &got);
    try testing.expectError(error.HashMismatch, appendChunk(testing.io, tmp.dir, other, 4, 8, "XXXX", &got));
    try testing.expect(!exists(testing.io, tmp.dir, other));
    // After a mismatch the upload restarts from zero.
    try testing.expectEqual(Chunked{ .partial = 4 }, try appendChunk(testing.io, tmp.dir, other, 0, 8, "1234", &got));
    try testing.expectError(error.BadChunk, appendChunk(testing.io, tmp.dir, other, 4, 8, "567890", &got));
}

test "contentType" {
    try testing.expectEqualStrings("image/png", contentType("abc.png"));
    try testing.expectEqualStrings("application/octet-stream", contentType("abc.xyz"));
}
