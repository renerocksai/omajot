//! Pure text helpers: UTF-8 ⇄ UTF-16 at the protocol edge, and the note
//! summary derivations from docs/PROTOCOL.md §1 (title, snippet, #hashtags,
//! search folding).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn isHigh(u: u16) bool {
    return u >= 0xD800 and u <= 0xDBFF;
}

pub fn isLow(u: u16) bool {
    return u >= 0xDC00 and u <= 0xDFFF;
}

pub fn toUtf16(gpa: Allocator, utf8: []const u8) error{ InvalidUtf8, OutOfMemory }![]u16 {
    return std.unicode.utf8ToUtf16LeAlloc(gpa, utf8);
}

pub fn toUtf8(gpa: Allocator, units: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(gpa, units);
}

/// Length in UTF-16 code units of valid UTF-8.
pub fn utf16Len(utf8: []const u8) error{InvalidUtf8}!usize {
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(utf8) catch return error.InvalidUtf8;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| n += if (cp >= 0x10000) 2 else 1;
    return n;
}

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == '\n';
}

/// First line, with a leading markdown heading marker (`#`…`######` + space) removed.
pub fn title(utf8: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, utf8, '\n') orelse utf8.len;
    var line = std.mem.trim(u8, utf8[0..end], " \t\r");
    var hashes: usize = 0;
    while (hashes < line.len and line[hashes] == '#') hashes += 1;
    if (hashes >= 1 and hashes <= 6 and (hashes == line.len or line[hashes] == ' ' or line[hashes] == '\t')) {
        line = std.mem.trim(u8, line[hashes..], " \t");
    }
    return line;
}

pub const snippet_max_codepoints = 120;

/// Text after the first line, whitespace runs collapsed, at most 120 codepoints.
pub fn snippet(gpa: Allocator, utf8: []const u8) ![]u8 {
    const nl = std.mem.findScalar(u8, utf8, '\n') orelse return gpa.dupe(u8, "");
    const rest = utf8[nl + 1 ..];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var codepoints: usize = 0;
    var pending_space = false;
    var i: usize = 0;
    while (i < rest.len and codepoints < snippet_max_codepoints) {
        const b = rest[i];
        if (isSpace(b)) {
            pending_space = out.items.len > 0;
            i += 1;
            continue;
        }
        if (pending_space) {
            try out.append(gpa, ' ');
            codepoints += 1;
            pending_space = false;
            if (codepoints >= snippet_max_codepoints) break;
        }
        const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        const take = @min(len, rest.len - i);
        try out.appendSlice(gpa, rest[i .. i + take]);
        codepoints += 1;
        i += take;
    }
    return out.toOwnedSlice(gpa);
}

fn isTagByte(b: u8) bool {
    return b >= 0x80 or std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b == '/';
}

/// Lowercase ASCII and Latin-1 capitals (À–Þ except ×) in place. Enough for
/// German umlauts; other scripts are kept as typed.
pub fn foldCase(s: []u8) void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const b = s[i];
        if (b >= 'A' and b <= 'Z') {
            s[i] = b + 32;
        } else if (b == 0xC3 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9E and s[i + 1] != 0x97) {
            s[i + 1] += 0x20;
            i += 1;
        }
    }
}

fn lessThanStr(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Apple-Notes-style inline tags: `#` + tag chars (letters, digits, `_`, `-`, `/`,
/// any non-ASCII), preceded by start of line or whitespace, outside inline and
/// fenced code. Headings (`# x`) are not tags; digit-only tags (`#123`) are not
/// tags; trailing `-`/`/` are dropped. Result: lowercase, unique, sorted; free
/// with `freeTags`.
pub fn hashtags(gpa: Allocator, utf8: []const u8) ![][]u8 {
    var tags: std.ArrayList([]u8) = .empty;
    errdefer freeTags(gpa, tags.items);
    defer tags.deinit(gpa);

    var in_fence = false;
    var lines = std.mem.splitScalar(u8, utf8, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        var in_code = false;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const b = line[i];
            if (b == '`') {
                in_code = !in_code;
                continue;
            }
            if (in_code or b != '#') continue;
            if (i > 0 and !isSpace(line[i - 1])) continue;
            var j = i + 1;
            while (j < line.len and isTagByte(line[j])) j += 1;
            var tag = line[i + 1 .. j];
            while (tag.len > 0 and (tag[tag.len - 1] == '-' or tag[tag.len - 1] == '/')) tag = tag[0 .. tag.len - 1];
            i = j -| 1;
            if (tag.len == 0) continue;
            var all_digits = true;
            for (tag) |c| {
                if (!std.ascii.isDigit(c)) all_digits = false;
            }
            if (all_digits) continue;
            const owned = try gpa.dupe(u8, tag);
            foldCase(owned);
            var dup = false;
            for (tags.items) |t| {
                if (std.mem.eql(u8, t, owned)) dup = true;
            }
            if (dup) {
                gpa.free(owned);
            } else {
                tags.append(gpa, owned) catch |err| {
                    gpa.free(owned);
                    return err;
                };
            }
        }
    }
    std.mem.sort([]u8, tags.items, {}, lessThanStr);
    return tags.toOwnedSlice(gpa);
}

pub fn freeTags(gpa: Allocator, tags: []const []u8) void {
    for (tags) |t| gpa.free(t);
    gpa.free(tags);
}

/// Case-insensitive substring match (same folding as tags). `needle_folded`
/// must already be folded.
pub fn containsFolded(gpa: Allocator, haystack: []const u8, needle_folded: []const u8) !bool {
    if (needle_folded.len == 0) return true;
    const h = try gpa.dupe(u8, haystack);
    defer gpa.free(h);
    foldCase(h);
    return std.mem.find(u8, h, needle_folded) != null;
}

const testing = std.testing;

test "title strips heading marks and uses the first line" {
    try testing.expectEqualStrings("Groceries", title("# Groceries\nmilk"));
    try testing.expectEqualStrings("Plain", title("  Plain  \r\nrest"));
    try testing.expectEqualStrings("#tag first", title("#tag first"));
    try testing.expectEqualStrings("", title(""));
    try testing.expectEqualStrings("", title("###"));
}

test "snippet collapses whitespace and caps codepoints" {
    const s = try snippet(testing.allocator, "Title\n\n  a\t b \n\nc  ");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a b c", s);

    const long = "t\n" ++ "ü" ** 200;
    const s2 = try snippet(testing.allocator, long);
    defer testing.allocator.free(s2);
    try testing.expectEqual(@as(usize, 120), try std.unicode.utf8CountCodepoints(s2));

    const none = try snippet(testing.allocator, "only title");
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("", none);
}

test "hashtags follow the Apple Notes rules" {
    const text =
        \\# Heading #inheading
        \\## not a tag
        \\##nottag either
        \\#Work and #work again, #Grüße, #ÄRGER, #🎉party
        \\no#tag, `#code`, #123, #a-b/c-, #x_y
        \\```
        \\#fenced
        \\```
        \\~~~
        \\#tilde
        \\~~~
        \\#after
    ;
    const tags = try hashtags(testing.allocator, text);
    defer freeTags(testing.allocator, tags);
    const want = [_][]const u8{ "a-b/c", "after", "grüße", "inheading", "work", "x_y", "ärger", "🎉party" };
    try testing.expectEqual(want.len, tags.len);
    for (want, tags) |w, t| try testing.expectEqualStrings(w, t);
}

test "utf16 length and conversion round trip" {
    try testing.expectEqual(@as(usize, 5), try utf16Len("aü🎉b"));
    const u = try toUtf16(testing.allocator, "aü🎉b");
    defer testing.allocator.free(u);
    try testing.expectEqual(@as(usize, 5), u.len);
    try testing.expect(isHigh(u[2]) and isLow(u[3]));
    const back = try toUtf8(testing.allocator, u);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("aü🎉b", back);
}

test "search folding" {
    try testing.expect(try containsFolded(testing.allocator, "Hello WÖRLD", "wörld"));
    try testing.expect(!try containsFolded(testing.allocator, "Hello", "bye"));
}
