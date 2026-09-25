//! Toy "pure core": no std.Io, no global state, caller-passed allocator,
//! bytes in and bytes out. Text is stored as UTF-8; the public edit API
//! takes positions in UTF-16 code units, the unit both QML (QString) and
//! JavaScript (String, CodeMirror) use, so neither client converts.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EditError = error{
    /// Position or deletion end is past the end of the text.
    OutOfRange,
    /// Position or deletion end falls between the two halves of a surrogate pair.
    SplitsSurrogatePair,
    InvalidUtf8,
} || Allocator.Error;

pub const Buffer = struct {
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Buffer, gpa: Allocator) void {
        self.bytes.deinit(gpa);
        self.* = undefined;
    }

    pub fn text(self: *const Buffer) []const u8 {
        return self.bytes.items;
    }

    /// Replace `del` UTF-16 code units at UTF-16 offset `pos` with UTF-8 `ins`.
    pub fn applyEdit(self: *Buffer, gpa: Allocator, pos: usize, del: usize, ins: []const u8) EditError!void {
        if (!std.unicode.utf8ValidateSlice(ins)) return error.InvalidUtf8;
        const start = try utf16ToByteOffset(self.bytes.items, pos);
        const end = start + try utf16ToByteOffset(self.bytes.items[start..], del);
        try self.bytes.replaceRange(gpa, start, end - start, ins);
    }
};

/// Map a UTF-16 code-unit offset to a byte offset in valid UTF-8 `s`.
pub fn utf16ToByteOffset(s: []const u8, units: usize) EditError!usize {
    var byte: usize = 0;
    var seen: usize = 0;
    while (seen < units) {
        if (byte >= s.len) return error.OutOfRange;
        const n = std.unicode.utf8ByteSequenceLength(s[byte]) catch return error.InvalidUtf8;
        // 4-byte sequences are outside the BMP: two UTF-16 units.
        const w: usize = if (n == 4) 2 else 1;
        if (seen + w > units) return error.SplitsSurrogatePair;
        seen += w;
        byte += n;
    }
    return byte;
}

/// Length of valid UTF-8 `s` in UTF-16 code units.
pub fn utf16Len(s: []const u8) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        units += if (n == 4) 2 else 1;
        i += n;
    }
    return units;
}

/// Inline `#hashtags` (Apple Notes style). A tag starts with `#` at line start
/// or after whitespace and runs until whitespace or ASCII punctuation other than
/// `-`, `_` and `/`. `# Heading` (hash + space) and `##` are not tags. Fenced code
/// blocks and inline code are skipped. Returned slices borrow from `s`; the
/// caller frees only the list.
pub fn hashtags(gpa: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        var in_code = false;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (c == '`') {
                in_code = !in_code;
                continue;
            }
            if (in_code or c != '#') continue;
            if (i > 0 and !std.ascii.isWhitespace(line[i - 1])) continue;
            var j = i + 1;
            while (j < line.len and isTagByte(line[j])) : (j += 1) {}
            if (j > i + 1) {
                const tag = line[i + 1 .. j];
                if (!contains(out.items, tag)) try out.append(gpa, tag);
            }
            i = j -| 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn isTagByte(c: u8) bool {
    if (c >= 0x80) return true; // any non-ASCII: umlauts, emoji, CJK
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '/';
}

fn contains(list: []const []const u8, tag: []const u8) bool {
    for (list) |t| if (std.mem.eql(u8, t, tag)) return true;
    return false;
}

const testing = std.testing;

test "edits in UTF-16 units over ASCII, umlauts and emoji" {
    const gpa = testing.allocator;
    var b: Buffer = .{};
    defer b.deinit(gpa);
    try b.applyEdit(gpa, 0, 0, "Grüße");
    try b.applyEdit(gpa, 5, 0, " 🎉!");
    try testing.expectEqualStrings("Grüße 🎉!", b.text());
    // "🎉" is at units 6..8; delete it.
    try b.applyEdit(gpa, 6, 2, "✓");
    try testing.expectEqualStrings("Grüße ✓!", b.text());
    try b.applyEdit(gpa, 2, 1, "ue");
    try testing.expectEqualStrings("Grueße ✓!", b.text());
    try testing.expectEqual(@as(usize, 9), utf16Len(b.text()));
}

test "rejects offsets that split a surrogate pair or run past the end" {
    const gpa = testing.allocator;
    var b: Buffer = .{};
    defer b.deinit(gpa);
    try b.applyEdit(gpa, 0, 0, "a🎉b");
    try testing.expectError(error.SplitsSurrogatePair, b.applyEdit(gpa, 2, 0, "x"));
    try testing.expectError(error.SplitsSurrogatePair, b.applyEdit(gpa, 1, 1, ""));
    try testing.expectError(error.OutOfRange, b.applyEdit(gpa, 5, 0, "x"));
    try testing.expectError(error.InvalidUtf8, b.applyEdit(gpa, 0, 0, "\xff"));
    try testing.expectEqualStrings("a🎉b", b.text());
}

test "hashtags" {
    const gpa = testing.allocator;
    const src =
        \\# Heading is not a tag
        \\Shopping #einkauf and #Grüße, also #🎉party
        \\no#tag here, `#inline` code, #work/omajot
        \\```
        \\#fenced
        \\```
        \\#einkauf again ## nope
    ;
    const tags = try hashtags(gpa, src);
    defer gpa.free(tags);
    const want = [_][]const u8{ "einkauf", "Grüße", "🎉party", "work/omajot" };
    try testing.expectEqual(want.len, tags.len);
    for (want, tags) |w, t| try testing.expectEqualStrings(w, t);
}
