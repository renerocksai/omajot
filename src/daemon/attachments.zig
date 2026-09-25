//! Local attachments: `<data>/attachments/<sha256hex>.<ext>`, referenced from
//! markdown as `attachments/<sha256hex>.<ext>` (docs/PROTOCOL.md §2).
const std = @import("std");
const Io = std.Io;
const blobs = @import("../hub/blobs.zig");

pub const dir_name = "attachments";
pub const max_bytes = blobs.max_blob_bytes;
/// A blob name held by value: `<64 hex>.<ext>`.
pub const Name = struct {
    buf: [64 + 1 + blobs.max_ext_len]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Store `bytes` under its content hash (idempotent) and return the name.
pub fn store(io: Io, dir: Io.Dir, bytes: []const u8, ext: []const u8) !Name {
    if (bytes.len > max_bytes) return error.AttachmentTooLarge;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var name: Name = .{};
    const text = std.fmt.bufPrint(&name.buf, "{s}.{s}", .{ &blobs.hexDigest(digest), normalizeExt(ext) }) catch unreachable;
    name.len = text.len;
    if (!blobs.exists(io, dir, name.slice())) try writeNew(io, dir, name.slice(), bytes);
    return name;
}

/// Write a downloaded blob after checking it against its name.
pub fn storeVerified(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    if (!blobs.validName(name)) return error.InvalidName;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &blobs.hexDigest(digest), name[0..64])) return error.HashMismatch;
    if (!blobs.exists(io, dir, name)) try writeNew(io, dir, name, bytes);
}

fn writeNew(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var tmp_buf: [96]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".tmp-{s}", .{name});
    {
        const file = try dir.createFile(io, tmp, .{});
        defer file.close(io);
        try file.writePositionalAll(io, bytes, 0);
        try file.sync(io);
    }
    try dir.rename(tmp, dir, name, io);
}

/// A safe extension: lowercase alphanumerics, ≤ 10 chars, "bin" otherwise.
pub fn normalizeExt(ext: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "png", "png" }, .{ "jpg", "jpg" },   .{ "jpeg", "jpg" }, .{ "gif", "gif" },   .{ "webp", "webp" },
        .{ "svg", "svg" }, .{ "bmp", "bmp" },   .{ "avif", "avif" }, .{ "heic", "heic" }, .{ "pdf", "pdf" },
        .{ "tif", "tiff" }, .{ "tiff", "tiff" }, .{ "txt", "txt" }, .{ "md", "md" },     .{ "zip", "zip" },
        .{ "mp4", "mp4" }, .{ "mov", "mov" },   .{ "mp3", "mp3" },  .{ "m4a", "m4a" },   .{ "ico", "ico" },
    };
    for (table) |entry| if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
    return "bin";
}

pub fn extForMime(mime: []const u8) []const u8 {
    const base = std.mem.trim(u8, mime[0 .. std.mem.findScalar(u8, mime, ';') orelse mime.len], " ");
    const table = [_]struct { []const u8, []const u8 }{
        .{ "image/png", "png" },  .{ "image/jpeg", "jpg" },     .{ "image/jpg", "jpg" }, .{ "image/gif", "gif" },
        .{ "image/webp", "webp" }, .{ "image/svg+xml", "svg" }, .{ "image/bmp", "bmp" }, .{ "image/avif", "avif" },
        .{ "image/heic", "heic" }, .{ "image/tiff", "tiff" },   .{ "application/pdf", "pdf" }, .{ "image/x-icon", "ico" },
    };
    for (table) |entry| if (std.ascii.eqlIgnoreCase(base, entry[0])) return entry[1];
    return "bin";
}

/// Recognize common image formats by their magic bytes.
pub fn sniffExt(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "jpg";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "webp";
    if (std.mem.startsWith(u8, bytes, "%PDF")) return "pdf";
    if (std.mem.startsWith(u8, bytes, "BM")) return "bmp";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..12], "ftypavif")) return "avif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp") and std.mem.eql(u8, bytes[8..12], "heic")) return "heic";
    const head = std.mem.trimStart(u8, bytes[0..@min(bytes.len, 256)], " \t\r\n\xef\xbb\xbf");
    if (std.mem.startsWith(u8, head, "<svg") or (std.mem.startsWith(u8, head, "<?xml") and std.mem.find(u8, bytes[0..@min(bytes.len, 1024)], "<svg") != null)) return "svg";
    return null;
}

/// Call `found(name)` for every `attachments/<sha>.<ext>` reference in `text`
/// (any text: markdown, or JSON carrying markdown).
pub fn scan(text: []const u8, context: anytype, comptime found: fn (@TypeOf(context), []const u8) void) void {
    const marker = "attachments/";
    var from: usize = 0;
    while (std.mem.findPos(u8, text, from, marker)) |at| {
        const start = at + marker.len;
        from = start;
        var end = start;
        while (end < text.len and end - start < 64 + 1 + blobs.max_ext_len and
            (std.ascii.isAlphanumeric(text[end]) or text[end] == '.')) end += 1;
        var candidate = text[start..end];
        // Longest valid name: trim trailing dots/chars until valid.
        while (candidate.len >= 66 and !blobs.validName(candidate)) candidate = candidate[0 .. candidate.len - 1];
        if (blobs.validName(candidate)) found(context, candidate);
    }
}

const testing = std.testing;

test "store is content addressed and idempotent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try store(testing.io, tmp.dir, "abc", "PNG");
    const b = try store(testing.io, tmp.dir, "abc", "png");
    try testing.expectEqualStrings(a.slice(), b.slice());
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.png", a.slice());
    try testing.expectError(error.HashMismatch, storeVerified(testing.io, tmp.dir, a.slice(), "xyz"));
}

test "sniff and mime" {
    try testing.expectEqualStrings("png", sniffExt("\x89PNG\r\n\x1a\nrest").?);
    try testing.expectEqualStrings("jpg", extForMime("image/jpeg"));
    try testing.expectEqualStrings("svg", extForMime("image/svg+xml; charset=utf-8"));
    try testing.expectEqualStrings("bin", normalizeExt("../x"));
    try testing.expect(sniffExt("hello") == null);
}

test "scan finds references in markdown and JSON" {
    const Collector = struct {
        var names: [4][]const u8 = undefined;
        var n: usize = 0;
        fn found(_: void, name: []const u8) void {
            names[n] = name;
            n += 1;
        }
    };
    const sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const text = "![x](attachments/" ++ sha ++ ".png) and {\"text\":\"[f](attachments/" ++ sha ++ ".pdf)\"} attachments/short.png";
    scan(text, {}, Collector.found);
    try testing.expectEqual(@as(usize, 2), Collector.n);
    try testing.expectEqualStrings(sha ++ ".png", Collector.names[0]);
    try testing.expectEqualStrings(sha ++ ".pdf", Collector.names[1]);
}
