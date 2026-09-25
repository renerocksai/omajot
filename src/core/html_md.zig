//! HTML clipboard fragments → markdown, for paste (spikes/paste/REPORT.md).
//! A tolerant tokenizer that understands the handful of tags people actually
//! paste: headings, paragraphs, emphasis, code, links, images, lists with
//! checkboxes, quotes, rules, tables. Attributes other than href, src, alt,
//! type and checked are ignored, which also discards Chromium's inline styles.
//! Pure: no I/O, caller-owned allocator.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn convert(gpa: Allocator, html: []const u8) ![]u8 {
    var c: Converter = .{ .gpa = gpa };
    defer c.deinit();
    try c.run(html);
    return c.finish();
}

const ListKind = enum { ul, ol };
const List = struct { kind: ListKind, next: u32 = 1, indent: usize };

const Converter = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    /// Line prefix: blockquote markers and list continuation indentation.
    lists: std.ArrayList(List) = .empty,
    quote_depth: usize = 0,
    at_line_start: bool = true,
    /// Pending whitespace between inline runs (collapsed to one space).
    pending_space: bool = false,
    /// Newlines owed before the next content (2 = blank line).
    pending_break: u8 = 0,
    pre_depth: usize = 0,
    skip_depth: usize = 0,
    skip_tag: []const u8 = "",
    hrefs: std.ArrayList(?[]u8) = .empty,
    link_starts: std.ArrayList(usize) = .empty,
    table: ?Table = null,

    const Table = struct {
        rows: std.ArrayList(std.ArrayList([]u8)) = .empty,
        cell_start: ?usize = null,
    };

    fn deinit(self: *Converter) void {
        self.out.deinit(self.gpa);
        self.lists.deinit(self.gpa);
        for (self.hrefs.items) |h| if (h) |x| self.gpa.free(x);
        self.hrefs.deinit(self.gpa);
        self.link_starts.deinit(self.gpa);
        if (self.table) |*t| self.freeTable(t);
    }

    fn freeTable(self: *Converter, t: *Table) void {
        for (t.rows.items) |*row| {
            for (row.items) |cell| self.gpa.free(cell);
            row.deinit(self.gpa);
        }
        t.rows.deinit(self.gpa);
    }

    fn finish(self: *Converter) ![]u8 {
        // Trim trailing whitespace; a single final newline is not needed for an insert.
        while (self.out.items.len > 0 and std.ascii.isWhitespace(self.out.items[self.out.items.len - 1]))
            self.out.items.len -= 1;
        // Trim leading blank lines.
        var start: usize = 0;
        while (start < self.out.items.len and self.out.items[start] == '\n') start += 1;
        const result = try self.gpa.dupe(u8, self.out.items[start..]);
        return result;
    }

    // ---------------------------------------------------------------- output

    fn blockBreak(self: *Converter, lines: u8) void {
        self.pending_space = false;
        if (self.out.items.len == 0) return;
        // Inside a list, paragraphs are separated by single newlines.
        const wanted: u8 = if (self.lists.items.len > 0) 1 else lines;
        self.pending_break = @max(self.pending_break, wanted);
    }

    fn flushBreak(self: *Converter) !void {
        if (self.pending_break == 0) return;
        const lines = self.pending_break;
        self.pending_break = 0;
        for (0..lines) |i| {
            if (i > 0) try self.writePrefix(false);
            try self.out.append(self.gpa, '\n');
        }
        self.at_line_start = true;
        self.pending_space = false;
    }

    fn writePrefix(self: *Converter, with_indent: bool) !void {
        for (0..self.quote_depth) |_| try self.out.appendSlice(self.gpa, "> ");
        if (with_indent and self.lists.items.len > 0) {
            const indent = self.lists.items[self.lists.items.len - 1].indent;
            try self.out.appendNTimes(self.gpa, ' ', indent);
        }
    }

    fn startLine(self: *Converter) !void {
        if (!self.at_line_start) return;
        try self.writePrefix(true);
        self.at_line_start = false;
    }

    fn raw(self: *Converter, bytes: []const u8) !void {
        try self.flushBreak();
        try self.startLine();
        if (self.pending_space) {
            const last = if (self.out.items.len > 0) self.out.items[self.out.items.len - 1] else '\n';
            if (last != ' ' and last != '\n') try self.out.append(self.gpa, ' ');
            self.pending_space = false;
        }
        try self.out.appendSlice(self.gpa, bytes);
    }

    fn text(self: *Converter, decoded: []const u8) !void {
        if (self.pre_depth > 0) {
            try self.flushBreak();
            for (decoded) |ch| {
                if (ch == '\n') {
                    try self.out.append(self.gpa, '\n');
                    self.at_line_start = true;
                } else {
                    try self.startLine();
                    try self.out.append(self.gpa, ch);
                }
            }
            return;
        }
        var i: usize = 0;
        while (i < decoded.len) {
            if (isSpace(decoded[i])) {
                if (!self.at_line_start or self.pending_break > 0) self.pending_space = true;
                i += 1;
                continue;
            }
            var j = i;
            while (j < decoded.len and !isSpace(decoded[j])) j += 1;
            var word: std.ArrayList(u8) = .empty;
            defer word.deinit(self.gpa);
            for (decoded[i..j]) |ch| {
                if (std.mem.findScalar(u8, "\\*_`[]", ch) != null) try word.append(self.gpa, '\\');
                try word.append(self.gpa, ch);
            }
            try self.raw(word.items);
            i = j;
        }
    }

    fn hardBreak(self: *Converter) !void {
        if (self.pre_depth > 0) return self.text("\n");
        try self.flushBreak();
        try self.out.append(self.gpa, '\n');
        self.at_line_start = true;
        self.pending_space = false;
    }

    // ---------------------------------------------------------------- tags

    fn open(self: *Converter, name: []const u8, attrs: []const u8, self_closing: bool) !void {
        if (self.skip_depth > 0) {
            if (eql(name, self.skip_tag) and !self_closing) self.skip_depth += 1;
            return;
        }
        if (eql(name, "script") or eql(name, "style") or eql(name, "head") or eql(name, "title") or eql(name, "template")) {
            if (!self_closing) {
                self.skip_depth = 1;
                self.skip_tag = skipName(name);
            }
            return;
        }
        if (headingLevel(name)) |level| {
            self.blockBreak(2);
            var hashes: [7]u8 = undefined;
            @memset(hashes[0..level], '#');
            hashes[level] = ' ';
            try self.raw(hashes[0 .. level + 1]);
            return;
        }
        if (eql(name, "p") or eql(name, "div") or eql(name, "section") or eql(name, "article") or
            eql(name, "header") or eql(name, "footer") or eql(name, "figure") or eql(name, "dl") or eql(name, "dt") or eql(name, "dd"))
            return self.blockBreak(if (eql(name, "div")) 1 else 2);
        if (eql(name, "br")) return self.hardBreak();
        if (eql(name, "hr")) {
            self.blockBreak(2);
            try self.raw("---");
            return self.blockBreak(2);
        }
        if (eql(name, "b") or eql(name, "strong")) return self.raw("**");
        if (eql(name, "i") or eql(name, "em")) return self.raw("*");
        if (eql(name, "s") or eql(name, "del") or eql(name, "strike")) return self.raw("~~");
        if (eql(name, "code") and self.pre_depth == 0) return self.raw("`");
        if (eql(name, "pre")) {
            self.blockBreak(2);
            try self.raw("```");
            self.pre_depth += 1;
            try self.hardBreak();
            return;
        }
        if (eql(name, "blockquote")) {
            self.blockBreak(2);
            try self.flushBreak();
            self.quote_depth += 1;
            return;
        }
        if (eql(name, "ul") or eql(name, "ol")) {
            const parent_indent = if (self.lists.items.len > 0) self.lists.items[self.lists.items.len - 1].indent else 0;
            // Nested lists start on their own line inside the parent item.
            if (self.lists.items.len > 0) self.blockBreak(1) else self.blockBreak(2);
            try self.lists.append(self.gpa, .{ .kind = if (eql(name, "ul")) .ul else .ol, .indent = parent_indent });
            return;
        }
        if (eql(name, "li")) {
            self.blockBreak(1);
            try self.flushBreak();
            if (self.out.items.len > 0 and !self.at_line_start) try self.hardBreak();
            const list = if (self.lists.items.len > 0) &self.lists.items[self.lists.items.len - 1] else null;
            var marker_buf: [16]u8 = undefined;
            const marker = if (list) |l| switch (l.kind) {
                .ul => "- ",
                .ol => blk: {
                    const m = std.fmt.bufPrint(&marker_buf, "{d}. ", .{l.next}) catch "1. ";
                    l.next += 1;
                    break :blk m;
                },
            } else "- ";
            // The marker sits at the parent's indentation; content continues after it.
            const base = if (list) |l| l.indent else 0;
            if (self.at_line_start) {
                try self.writePrefix(false);
                try self.out.appendNTimes(self.gpa, ' ', base);
                self.at_line_start = false;
            }
            try self.out.appendSlice(self.gpa, marker);
            if (list) |l| l.indent = base;
            // Continuation lines (nested lists, <br>) indent under the text.
            if (list) |l| l.indent = base + marker.len;
            self.pending_space = false;
            return;
        }
        if (eql(name, "input")) {
            if (attr(attrs, "type")) |t| if (std.ascii.eqlIgnoreCase(t, "checkbox")) {
                return self.raw(if (hasAttr(attrs, "checked")) "[x] " else "[ ] ");
            };
            return;
        }
        if (eql(name, "img")) {
            const src = attr(attrs, "src") orelse return;
            const alt = attr(attrs, "alt") orelse "";
            const decoded_alt = try decodeEntities(self.gpa, alt);
            defer self.gpa.free(decoded_alt);
            const md = try std.fmt.allocPrint(self.gpa, "![{s}]({s})", .{ decoded_alt, src });
            defer self.gpa.free(md);
            return self.raw(md);
        }
        if (eql(name, "a")) {
            const href = if (attr(attrs, "href")) |h| try decodeEntities(self.gpa, h) else null;
            try self.hrefs.append(self.gpa, href);
            if (href != null) {
                try self.raw("[");
                try self.link_starts.append(self.gpa, self.out.items.len);
            }
            return;
        }
        if (eql(name, "table")) {
            self.blockBreak(2);
            if (self.table == null) self.table = .{};
            return;
        }
        if (eql(name, "tr")) {
            if (self.table) |*t| try t.rows.append(self.gpa, .empty);
            return;
        }
        if (eql(name, "td") or eql(name, "th")) {
            if (self.table) |*t| {
                if (t.rows.items.len == 0) try t.rows.append(self.gpa, .empty);
                try self.flushBreak();
                t.cell_start = self.out.items.len;
                self.at_line_start = false;
                self.pending_space = false;
            }
            return;
        }
    }

    fn close(self: *Converter, name: []const u8) !void {
        if (self.skip_depth > 0) {
            if (eql(name, self.skip_tag)) self.skip_depth -= 1;
            return;
        }
        if (headingLevel(name) != null) return self.blockBreak(2);
        if (eql(name, "p") or eql(name, "section") or eql(name, "article") or eql(name, "header") or
            eql(name, "footer") or eql(name, "figure") or eql(name, "dl") or eql(name, "dt") or eql(name, "dd"))
            return self.blockBreak(2);
        if (eql(name, "div")) return self.blockBreak(1);
        if (eql(name, "b") or eql(name, "strong")) return self.closeInline("**");
        if (eql(name, "i") or eql(name, "em")) return self.closeInline("*");
        if (eql(name, "s") or eql(name, "del") or eql(name, "strike")) return self.closeInline("~~");
        if (eql(name, "code") and self.pre_depth == 0) return self.closeInline("`");
        if (eql(name, "pre")) {
            if (self.pre_depth == 0) return;
            self.pre_depth -= 1;
            if (!self.at_line_start) try self.hardBreak();
            try self.raw("```");
            return self.blockBreak(2);
        }
        if (eql(name, "blockquote")) {
            if (self.quote_depth > 0) self.quote_depth -= 1;
            return self.blockBreak(2);
        }
        if (eql(name, "ul") or eql(name, "ol")) {
            if (self.lists.items.len > 0) _ = self.lists.pop();
            return self.blockBreak(if (self.lists.items.len > 0) 1 else 2);
        }
        if (eql(name, "li")) {
            if (self.lists.items.len > 0) {
                const l = &self.lists.items[self.lists.items.len - 1];
                l.indent = if (self.lists.items.len > 1) self.lists.items[self.lists.items.len - 2].indent else 0;
            }
            return self.blockBreak(1);
        }
        if (eql(name, "a")) {
            const href = self.hrefs.pop() orelse return;
            const h = href orelse return;
            defer self.gpa.free(h);
            const start = self.link_starts.pop() orelse return;
            if (self.out.items.len == start) {
                // Empty link text: drop the "[" and show nothing.
                self.out.items.len = start - 1;
                return;
            }
            self.pending_space = false;
            const tail = try std.fmt.allocPrint(self.gpa, "]({s})", .{h});
            defer self.gpa.free(tail);
            try self.out.appendSlice(self.gpa, tail);
            return;
        }
        if (eql(name, "td") or eql(name, "th")) {
            if (self.table) |*t| if (t.cell_start) |start| {
                const cell_raw = std.mem.trim(u8, self.out.items[start..], " \n");
                var cell: std.ArrayList(u8) = .empty;
                for (cell_raw) |ch| switch (ch) {
                    '\n' => try cell.appendSlice(self.gpa, "<br>"),
                    '|' => try cell.appendSlice(self.gpa, "\\|"),
                    else => try cell.append(self.gpa, ch),
                };
                self.out.items.len = start;
                const row = &t.rows.items[t.rows.items.len - 1];
                try row.append(self.gpa, try cell.toOwnedSlice(self.gpa));
                t.cell_start = null;
            };
            return;
        }
        if (eql(name, "table")) {
            var t = self.table orelse return;
            self.table = null;
            defer self.freeTable(&t);
            try self.emitTable(&t);
            return self.blockBreak(2);
        }
    }

    fn closeInline(self: *Converter, marker: []const u8) !void {
        // Keep "**bold** text", not "**bold **text".
        const had_space = self.pending_space;
        self.pending_space = false;
        try self.out.appendSlice(self.gpa, marker);
        self.pending_space = had_space;
    }

    fn emitTable(self: *Converter, t: *Table) !void {
        var columns: usize = 0;
        for (t.rows.items) |row| columns = @max(columns, row.items.len);
        if (columns == 0) return;
        self.at_line_start = true;
        var first = true;
        for (t.rows.items) |row| {
            if (row.items.len == 0) continue;
            try self.flushBreak();
            try self.startLine();
            try self.out.append(self.gpa, '|');
            for (0..columns) |ci| {
                try self.out.append(self.gpa, ' ');
                if (ci < row.items.len) try self.out.appendSlice(self.gpa, row.items[ci]);
                try self.out.appendSlice(self.gpa, " |");
            }
            try self.hardBreak();
            if (first) {
                first = false;
                try self.startLine();
                try self.out.append(self.gpa, '|');
                for (0..columns) |_| try self.out.appendSlice(self.gpa, " --- |");
                try self.hardBreak();
            }
        }
    }

    // ---------------------------------------------------------------- tokenizer

    fn run(self: *Converter, html: []const u8) !void {
        var i: usize = 0;
        while (i < html.len) {
            if (html[i] == '<') {
                if (std.mem.startsWith(u8, html[i..], "<!--")) {
                    const end = std.mem.findPos(u8, html, i + 4, "-->") orelse html.len;
                    i = @min(end + 3, html.len);
                    continue;
                }
                if (std.mem.startsWith(u8, html[i..], "<!") or std.mem.startsWith(u8, html[i..], "<?")) {
                    i = (std.mem.findScalarPos(u8, html, i, '>') orelse html.len - 1) + 1;
                    continue;
                }
                if (parseTag(html, i)) |tag| {
                    var lower_buf: [16]u8 = undefined;
                    const name = std.ascii.lowerString(&lower_buf, tag.name[0..@min(tag.name.len, lower_buf.len)]);
                    if (tag.closing) try self.close(name) else try self.open(name, tag.attrs, tag.self_closing);
                    // pre/code content is raw until its closing tag, except tags we still honour.
                    i = tag.end;
                    continue;
                }
            }
            const next = std.mem.findScalarPos(u8, html, i + 1, '<') orelse html.len;
            if (self.skip_depth == 0) {
                const decoded = try decodeEntities(self.gpa, html[i..next]);
                defer self.gpa.free(decoded);
                if (self.table) |t| if (t.cell_start == null) {
                    // Whitespace between table tags is not content.
                    i = next;
                    continue;
                };
                try self.text(decoded);
            }
            i = next;
        }
    }
};

const Tag = struct { name: []const u8, attrs: []const u8, closing: bool, self_closing: bool, end: usize };

fn parseTag(html: []const u8, start: usize) ?Tag {
    var i = start + 1;
    var closing = false;
    if (i < html.len and html[i] == '/') {
        closing = true;
        i += 1;
    }
    const name_start = i;
    while (i < html.len and (std.ascii.isAlphanumeric(html[i]) or html[i] == '-' or html[i] == ':')) i += 1;
    if (i == name_start) return null;
    const name = html[name_start..i];
    // Find the closing '>' while respecting quoted attribute values.
    var quote: u8 = 0;
    const attrs_start = i;
    while (i < html.len) : (i += 1) {
        const ch = html[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '>') break;
    }
    if (i >= html.len) return null;
    const attrs = html[attrs_start..i];
    const self_closing = attrs.len > 0 and attrs[attrs.len - 1] == '/';
    return .{ .name = name, .attrs = attrs, .closing = closing, .self_closing = self_closing, .end = i + 1 };
}

/// Value of attribute `name` (raw, entities not decoded), or null.
fn attr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and (std.ascii.isWhitespace(attrs[i]) or attrs[i] == '/')) i += 1;
        const key_start = i;
        while (i < attrs.len and !std.ascii.isWhitespace(attrs[i]) and attrs[i] != '=' and attrs[i] != '/' and attrs[i] != '>') i += 1;
        const key = attrs[key_start..i];
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        var value: []const u8 = "";
        if (i < attrs.len and attrs[i] == '=') {
            i += 1;
            while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
            if (i < attrs.len and (attrs[i] == '"' or attrs[i] == '\'')) {
                const q = attrs[i];
                const v_start = i + 1;
                const v_end = std.mem.findScalarPos(u8, attrs, v_start, q) orelse attrs.len;
                value = attrs[v_start..v_end];
                i = @min(v_end + 1, attrs.len);
            } else {
                const v_start = i;
                while (i < attrs.len and !std.ascii.isWhitespace(attrs[i])) i += 1;
                value = attrs[v_start..i];
            }
        }
        if (key.len > 0 and std.ascii.eqlIgnoreCase(key, name)) return value;
        if (key.len == 0) i += 1;
    }
    return null;
}

fn hasAttr(attrs: []const u8, name: []const u8) bool {
    return attr(attrs, name) != null;
}

fn headingLevel(name: []const u8) ?u8 {
    if (name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6') return name[1] - '0';
    return null;
}

fn skipName(name: []const u8) []const u8 {
    const names = [_][]const u8{ "script", "style", "head", "title", "template" };
    for (names) |n| if (eql(name, n)) return n;
    return "";
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t' or ch == '\x0c';
}

/// Decode character references. Unknown named entities are kept verbatim.
pub fn decodeEntities(gpa: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '&') {
            try out.append(gpa, s[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.findScalarPos(u8, s, i + 1, ';');
        if (semi == null or semi.? - i > 12) {
            try out.append(gpa, '&');
            i += 1;
            continue;
        }
        const body = s[i + 1 .. semi.?];
        var codepoint: ?u21 = null;
        if (body.len > 1 and body[0] == '#') {
            const parsed = if (body[1] == 'x' or body[1] == 'X')
                std.fmt.parseInt(u21, body[2..], 16)
            else
                std.fmt.parseInt(u21, body[1..], 10);
            codepoint = parsed catch null;
        } else {
            const named = [_]struct { []const u8, u21 }{
                .{ "amp", '&' },      .{ "lt", '<' },         .{ "gt", '>' },        .{ "quot", '"' },
                .{ "apos", '\'' },    .{ "nbsp", ' ' },       .{ "hellip", 0x2026 }, .{ "mdash", 0x2014 },
                .{ "ndash", 0x2013 }, .{ "lsquo", 0x2018 },   .{ "rsquo", 0x2019 },  .{ "ldquo", 0x201C },
                .{ "rdquo", 0x201D }, .{ "copy", 0xA9 },      .{ "reg", 0xAE },      .{ "trade", 0x2122 },
                .{ "euro", 0x20AC },  .{ "bull", 0x2022 },    .{ "middot", 0xB7 },   .{ "times", 0xD7 },
                .{ "auml", 0xE4 },    .{ "ouml", 0xF6 },      .{ "uuml", 0xFC },     .{ "Auml", 0xC4 },
                .{ "Ouml", 0xD6 },    .{ "Uuml", 0xDC },      .{ "szlig", 0xDF },    .{ "shy", 0xAD },
            };
            for (named) |n| if (eql(body, n[0])) {
                codepoint = n[1];
                break;
            };
        }
        if (codepoint) |cp| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch {
                try out.appendSlice(gpa, s[i .. semi.? + 1]);
                i = semi.? + 1;
                continue;
            };
            try out.appendSlice(gpa, buf[0..len]);
        } else {
            try out.appendSlice(gpa, s[i .. semi.? + 1]);
        }
        i = semi.? + 1;
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------- tests

fn expectConvert(html: []const u8, expected: []const u8) !void {
    const got = try convert(std.testing.allocator, html);
    defer std.testing.allocator.free(got);
    std.testing.expectEqualStrings(expected, got) catch |err| {
        std.debug.print("\n--- html:\n{s}\n", .{html});
        return err;
    };
}

test "inline formatting, links, entities" {
    try expectConvert(
        "<p>Some <b>bold</b>, <i>italic</i>, <code>code</code> and a <a href=\"https://example.com/x\">link</a>. Umlaut: Gr&uuml;&szlig;e &amp; 🎉</p>",
        "Some **bold**, *italic*, `code` and a [link](https://example.com/x). Umlaut: Grüße & 🎉",
    );
}

test "headings, paragraphs, quote, rule, pre" {
    try expectConvert(
        "<h1>Title</h1><p>one</p><p>two</p><blockquote>A quote</blockquote><hr><pre><code>fn main() void {}\nx &lt; y</code></pre>",
        "# Title\n\none\n\ntwo\n\n> A quote\n\n---\n\n```\nfn main() void {}\nx < y\n```",
    );
}

test "nested lists with checkboxes and ordered lists" {
    try expectConvert(
        "<ul><li>one<ul><li>nested</li></ul></li><li><input type=\"checkbox\" checked=\"\"><span> </span>done task</li><li><input type=\"checkbox\"> open task</li></ul><ol><li>first</li><li>second</li></ol>",
        "- one\n  - nested\n- [x] done task\n- [ ] open task\n\n1. first\n2. second",
    );
}

test "table becomes GFM with a header row" {
    try expectConvert(
        "<table><tr><th>A</th><th>B</th></tr>\n<tr><td>1</td><td>2|3</td></tr></table>",
        "| A | B |\n| --- | --- |\n| 1 | 2\\|3 |",
    );
}

test "images, styles and scripts are handled; markdown chars are escaped" {
    try expectConvert(
        "<style>p{color:red}</style><p style=\"color: rgb(0, 0, 0); font-family: &quot;Times New Roman&quot;;\">a*b_c <img src=\"data:image/png;base64,AAA\" alt=\"pic\"></p><script>alert(1)</script>",
        "a\\*b\\_c ![pic](data:image/png;base64,AAA)",
    );
}

test "chromium fragment from the paste spike" {
    // Trimmed from spikes/paste: inline styles everywhere, spans for spaces.
    try expectConvert(
        "<h1 style=\"color: rgb(0, 0, 0);\">Paste test</h1><p style=\"x\">Some<span> </span><b>bold</b>,<span> </span><i>italic</i></p><ul style=\"y\"><li>one</li></ul>",
        "# Paste test\n\nSome **bold**, *italic*\n\n- one",
    );
}

test "br and empty links" {
    try expectConvert("<p>a<br>b<a href=\"x\"></a></p>", "a\nb");
}
