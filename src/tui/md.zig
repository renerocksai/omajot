//! Markdown → libvaxis cells for the preview pane of `omajot tui`. Line-based like the web
//! app's renderer: headings, paragraphs (a newline is a line break), inline
//! bold/italic/code/strike/links/#tags, lists and task boxes, quotes, fenced
//! code, tables, rules and images (Kitty graphics, else a placeholder line).
//!
//! Two passes: measure (commit = false, in a tall window) for the content
//! height, then draw with the window shifted up by the scroll offset; rows
//! above and below the pane are clipped by libvaxis.
const std = @import("std");
const vaxis = @import("vaxis");
const Theme = @import("theme.zig").Theme;

const Style = vaxis.Style;
const Segment = vaxis.Segment;
const Window = vaxis.Window;

pub const glyph = struct {
    pub const task_open = "\u{f096}";
    pub const task_done = "\u{f14a}";
    pub const image = "\u{f03e}";
};

/// Pictures for `![alt](attachments/…)` lines, transmitted once per path.
pub const Images = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, path: []const u8) Picture,

    pub const Picture = union(enum) {
        image: vaxis.Image,
        /// The terminal has no Kitty graphics.
        no_graphics,
        /// Not on this computer (yet), or not a picture omajot can read.
        missing,
    };
};

const Ctx = struct {
    win: Window,
    arena: std.mem.Allocator,
    theme: Theme,
    commit: bool,
    row: u16 = 0,
    images: ?Images,
    scroll: u16,

    fn st(self: *Ctx, s: Style) Style {
        _ = self;
        return s;
    }

    /// Print segments at `indent`, word-wrapped; advances the row.
    fn line(self: *Ctx, segs: []const Segment, indent: u16) void {
        const child = self.win.child(.{ .x_off = indent, .y_off = self.row });
        const res = child.print(segs, .{ .wrap = .word, .commit = self.commit });
        self.row += res.row + 1;
    }

    fn fillRow(self: *Ctx, bg: [3]u8) void {
        if (!self.commit) return;
        var col: u16 = 0;
        while (col < self.win.width) : (col += 1)
            self.win.writeCell(col, self.row, .{ .style = .{ .bg = self.theme.c(bg) } });
    }
};

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// Inline markup of one line → styled segments (slices into `text`).
pub fn inlineSegments(arena: std.mem.Allocator, text: []const u8, base: Style, theme: Theme) ![]Segment {
    var out: std.ArrayList(Segment) = .empty;
    var bold = false;
    var italic = false;
    var strike = false;
    var start: usize = 0;
    var i: usize = 0;
    const cur = struct {
        fn style(b: Style, bo: bool, it: bool, sk: bool) Style {
            var s = b;
            s.bold = s.bold or bo;
            s.italic = s.italic or it;
            s.strikethrough = s.strikethrough or sk;
            return s;
        }
    };
    while (i < text.len) {
        const rest = text[i..];
        const flush = struct {
            fn f(list: *std.ArrayList(Segment), a: std.mem.Allocator, t: []const u8, s: Style) !void {
                if (t.len > 0) try list.append(a, .{ .text = t, .style = s });
            }
        }.f;
        if (std.mem.startsWith(u8, rest, "**") or std.mem.startsWith(u8, rest, "__")) {
            try flush(&out, arena, text[start..i], cur.style(base, bold, italic, strike));
            bold = !bold;
            i += 2;
            start = i;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "~~")) {
            try flush(&out, arena, text[start..i], cur.style(base, bold, italic, strike));
            strike = !strike;
            i += 2;
            start = i;
            continue;
        }
        if (rest[0] == '*' or (rest[0] == '_' and (i == 0 or !isWordByte(text[i - 1])) != italic)) {
            try flush(&out, arena, text[start..i], cur.style(base, bold, italic, strike));
            italic = !italic;
            i += 1;
            start = i;
            continue;
        }
        if (rest[0] == '`') {
            if (std.mem.findScalarPos(u8, text, i + 1, '`')) |end| {
                try flush(&out, arena, text[start..i], cur.style(base, bold, italic, strike));
                var s = base;
                s.fg = theme.c(theme.accent);
                s.bg = theme.c(theme.bg_code);
                try out.append(arena, .{ .text = text[i + 1 .. end], .style = s });
                i = end + 1;
                start = i;
                continue;
            }
        }
        if (rest[0] == '[') link: {
            const close = std.mem.findScalarPos(u8, text, i, ']') orelse break :link;
            if (close + 1 >= text.len or text[close + 1] != '(') break :link;
            const paren = std.mem.findScalarPos(u8, text, close + 2, ')') orelse break :link;
            try flush(&out, arena, text[start..i], cur.style(base, bold, italic, strike));
            var s = cur.style(base, bold, italic, strike);
            s.fg = theme.c(theme.accent);
            s.ul_style = .single;
            try out.append(arena, .{ .text = text[i + 1 .. close], .style = s, .link = .{ .uri = text[close + 2 .. paren] } });
            i = paren + 1;
            start = i;
            continue;
        }
        if (rest[0] == '#' and (i == 0 or text[i - 1] == ' ') and rest.len > 1 and isWordByte(rest[1])) {
            var j = i + 1;
            while (j < text.len and (isWordByte(text[j]) or text[j] == '-' or text[j] == '_' or text[j] == '/')) j += 1;
            try flush(&out, arena, text[start..i], cur.style(base, bold, italic, strike));
            var s = base;
            s.fg = theme.c(theme.accent);
            s.bg = theme.c(theme.bg_code);
            try out.append(arena, .{ .text = text[i..j], .style = s });
            i = j;
            start = i;
            continue;
        }
        i += 1;
    }
    if (start < text.len) try out.append(arena, .{ .text = text[start..], .style = cur.style(base, bold, italic, strike) });
    return out.items;
}

fn cells(line: []const u8) []const u8 {
    var t = std.mem.trim(u8, line, " \t\r");
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') t = t[0 .. t.len - 1];
    return t;
}

fn isTableRule(line: []const u8) bool {
    const t = cells(line);
    if (t.len == 0) return false;
    for (t) |b| if (b != '-' and b != ':' and b != '|' and b != ' ') return false;
    return true;
}

fn table(ctx: *Ctx, rows: []const []const u8) !void {
    const t = ctx.theme;
    var widths: [16]u16 = @splat(0);
    var ncols: usize = 0;
    // Cells carry inline markup: width = the rendered segments, not the source.
    const Cell = struct { segs: []Segment, width: u16 };
    var parsed: std.ArrayList([]const Cell) = .empty;
    for (rows) |r| {
        if (isTableRule(r)) continue;
        const header = parsed.items.len == 0;
        var cs: std.ArrayList(Cell) = .empty;
        var it = std.mem.splitScalar(u8, cells(r), '|');
        while (it.next()) |c| {
            if (cs.items.len == widths.len) break;
            const segs = try inlineSegments(ctx.arena, std.mem.trim(u8, c, " "), .{ .fg = t.c(t.fg), .bold = header }, t);
            var w: u16 = 0;
            for (segs) |sg| w += ctx.win.gwidth(sg.text);
            widths[cs.items.len] = @max(widths[cs.items.len], w);
            try cs.append(ctx.arena, .{ .segs = segs, .width = w });
        }
        ncols = @max(ncols, cs.items.len);
        try parsed.append(ctx.arena, cs.items);
    }
    const border: Style = .{ .fg = t.c(t.border) };
    for (parsed.items, 0..) |cs, ri| {
        var segs: std.ArrayList(Segment) = .empty;
        try segs.append(ctx.arena, .{ .text = "│ ", .style = border });
        for (0..ncols) |ci| {
            const cell: Cell = if (ci < cs.len) cs[ci] else .{ .segs = &.{}, .width = 0 };
            try segs.appendSlice(ctx.arena, cell.segs);
            try segs.append(ctx.arena, .{ .text = try spaces(ctx.arena, widths[ci] - cell.width) });
            try segs.append(ctx.arena, .{ .text = " │ ", .style = border });
        }
        const child = ctx.win.child(.{ .y_off = ctx.row });
        _ = child.print(segs.items, .{ .wrap = .none, .commit = ctx.commit });
        ctx.row += 1;
        if (ri == 0) {
            var rule: std.ArrayList(u8) = .empty;
            try rule.appendSlice(ctx.arena, "├");
            for (0..ncols) |ci| {
                for (0..widths[ci] + 2) |_| try rule.appendSlice(ctx.arena, "─");
                try rule.appendSlice(ctx.arena, if (ci + 1 == ncols) "┤" else "┼");
            }
            const rc = ctx.win.child(.{ .y_off = ctx.row });
            _ = rc.print(&.{.{ .text = rule.items, .style = border }}, .{ .wrap = .none, .commit = ctx.commit });
            ctx.row += 1;
        }
    }
}

fn spaces(arena: std.mem.Allocator, n: u16) ![]const u8 {
    const buf = try arena.alloc(u8, n);
    @memset(buf, ' ');
    return buf;
}

pub const rows_for_image: u16 = 12;

fn image(ctx: *Ctx, alt: []const u8, path: []const u8) !void {
    const picture: Images.Picture = if (ctx.images) |imgs| imgs.get(imgs.ctx, path) else .no_graphics;
    switch (picture) {
        .image => |img| {
            // Only draw a picture that fits the pane completely: a Kitty image
            // cut at an edge needs pixel clipping.
            if (ctx.commit and ctx.row >= ctx.scroll and ctx.row + rows_for_image <= ctx.win.height) {
                const area = ctx.win.child(.{ .y_off = ctx.row, .width = @min(ctx.win.width, 64), .height = rows_for_image });
                img.draw(area, .{ .scale = .contain }) catch {};
            }
            ctx.row += rows_for_image + 1;
        },
        .no_graphics, .missing => {
            const s: Style = .{ .fg = ctx.theme.c(ctx.theme.muted), .italic = true };
            ctx.line(&.{
                .{ .text = glyph.image ++ "  ", .style = s },
                .{ .text = if (alt.len > 0) alt else "picture", .style = s },
                .{ .text = if (picture == .missing) "  (not on this computer yet)" else "  (this terminal shows no pictures)", .style = .{ .fg = ctx.theme.c(ctx.theme.border), .italic = true } },
            }, 0);
        },
    }
}

/// Draws (commit) or measures `text`; returns the content height in rows.
pub fn render(win: Window, arena: std.mem.Allocator, text: []const u8, theme: Theme, scroll: u16, commit: bool, images: ?Images) !u16 {
    var content = win;
    if (commit) {
        content.y_off = win.y_off - @as(i17, scroll);
        content.parent_y_off = @min(win.parent_y_off - @as(i17, scroll), 0);
        content.height = win.height + scroll;
    } else content.height = 60000;
    var ctx: Ctx = .{ .win = content, .arena = arena, .theme = theme, .commit = commit, .images = images, .scroll = scroll };
    const t = theme;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(arena, std.mem.trimEnd(u8, l, "\r"));

    var i: usize = 0;
    var blank = false;
    while (i < lines.items.len) : (i += 1) {
        const raw = lines.items[i];
        const l = std.mem.trimStart(u8, raw, " ");
        const indent: u16 = @intCast(@min((raw.len - l.len) / 2 * 2, 12));
        if (l.len == 0) {
            if (!blank and ctx.row > 0) ctx.row += 1;
            blank = true;
            continue;
        }
        blank = false;

        if (std.mem.startsWith(u8, l, "```")) { // fenced code
            const lang = std.mem.trim(u8, l[3..], " ");
            if (lang.len > 0) {
                ctx.fillRow(t.bg_code);
                const c = ctx.win.child(.{ .x_off = 2, .y_off = ctx.row });
                _ = c.print(&.{.{ .text = lang, .style = .{ .fg = t.c(t.muted), .bg = t.c(t.bg_code), .italic = true } }}, .{ .wrap = .none, .commit = ctx.commit });
                ctx.row += 1;
            }
            i += 1;
            while (i < lines.items.len and !std.mem.startsWith(u8, std.mem.trimStart(u8, lines.items[i], " "), "```")) : (i += 1) {
                ctx.fillRow(t.bg_code);
                const c = ctx.win.child(.{ .x_off = 2, .y_off = ctx.row });
                _ = c.print(&.{.{ .text = lines.items[i], .style = .{ .fg = t.c(t.fg), .bg = t.c(t.bg_code) } }}, .{ .wrap = .none, .commit = ctx.commit });
                ctx.row += 1;
            }
            continue;
        }
        if (l[0] == '#') { // heading
            var level: usize = 0;
            while (level < l.len and l[level] == '#') level += 1;
            if (level <= 6 and level < l.len and l[level] == ' ') {
                var s: Style = .{ .bold = true, .fg = t.c(t.fg) };
                if (level == 1) s.fg = t.c(t.accent);
                if (level >= 3) s.fg = t.c(t.muted);
                const segs = try inlineSegments(arena, l[level + 1 ..], s, t);
                ctx.line(segs, 0);
                if (level == 1) { // an underline under the note title
                    const width = @min(ctx.win.gwidth(l[level + 1 ..]), ctx.win.width);
                    if (ctx.commit) for (0..width) |col| ctx.win.writeCell(@intCast(col), ctx.row, .{ .char = .{ .grapheme = "━", .width = 1 }, .style = .{ .fg = t.c(t.border) } });
                    ctx.row += 1;
                }
                continue;
            }
        }
        if (l.len >= 3 and (std.mem.eql(u8, l, "---") or std.mem.eql(u8, l, "***"))) {
            if (ctx.commit) for (0..ctx.win.width) |col| ctx.win.writeCell(@intCast(col), ctx.row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = .{ .fg = t.c(t.border) } });
            ctx.row += 1;
            continue;
        }
        if (l[0] == '|') { // table
            var end = i;
            while (end < lines.items.len and std.mem.startsWith(u8, std.mem.trimStart(u8, lines.items[end], " "), "|")) end += 1;
            try table(&ctx, lines.items[i..end]);
            i = end - 1;
            continue;
        }
        if (std.mem.startsWith(u8, l, "![")) img: {
            const close = std.mem.findScalar(u8, l, ']') orelse break :img;
            if (close + 1 >= l.len or l[close + 1] != '(') break :img;
            const paren = std.mem.findScalarPos(u8, l, close + 2, ')') orelse break :img;
            try image(&ctx, l[2..close], l[close + 2 .. paren]);
            continue;
        }
        if (l[0] == '>') { // quote
            const body = std.mem.trimStart(u8, l[1..], " ");
            if (ctx.commit) ctx.win.writeCell(indent, ctx.row, .{ .char = .{ .grapheme = "▌", .width = 1 }, .style = .{ .fg = t.c(t.accent) } });
            const segs = try inlineSegments(arena, body, .{ .fg = t.c(t.muted), .italic = true }, t);
            ctx.line(segs, indent + 2);
            continue;
        }
        const bullet = (l.len > 2 and (l[0] == '-' or l[0] == '*' or l[0] == '+') and l[1] == ' ');
        var num_end: usize = 0;
        while (num_end < l.len and std.ascii.isDigit(l[num_end])) num_end += 1;
        const numbered = num_end > 0 and num_end + 1 < l.len and l[num_end] == '.' and l[num_end + 1] == ' ';
        if (bullet or numbered) {
            var body = if (bullet) l[2..] else l[num_end + 2 ..];
            var mark: Segment = .{ .text = "•", .style = .{ .fg = t.c(t.muted) } };
            if (numbered) mark = .{ .text = l[0 .. num_end + 1], .style = .{ .fg = t.c(t.muted) } };
            var base: Style = .{ .fg = t.c(t.fg) };
            if (bullet and body.len >= 3 and body[0] == '[' and body[2] == ']') {
                const done = body[1] == 'x' or body[1] == 'X';
                mark = .{ .text = if (done) glyph.task_done else glyph.task_open, .style = .{ .fg = t.c(if (done) t.accent else t.muted) } };
                body = std.mem.trimStart(u8, body[3..], " ");
                if (done) base = .{ .fg = t.c(t.muted), .strikethrough = true };
            }
            const mc = ctx.win.child(.{ .x_off = indent, .y_off = ctx.row });
            _ = mc.print(&.{mark}, .{ .wrap = .none, .commit = ctx.commit });
            const segs = try inlineSegments(arena, body, base, t);
            ctx.line(segs, indent + @as(u16, @intCast(ctx.win.gwidth(mark.text))) + 1);
            continue;
        }
        const segs = try inlineSegments(arena, l, .{ .fg = t.c(t.fg) }, t);
        ctx.line(segs, indent);
    }
    return ctx.row;
}

test "inline segments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const segs = try inlineSegments(arena.allocator(), "a **b** `c` [d](https://e) #tag Grüße 🎉", .{}, .{});
    var bold = false;
    var link = false;
    var tag = false;
    for (segs) |s| {
        if (s.style.bold and std.mem.eql(u8, s.text, "b")) bold = true;
        if (std.mem.eql(u8, s.link.uri, "https://e")) link = true;
        if (std.mem.eql(u8, s.text, "#tag")) tag = true;
    }
    try std.testing.expect(bold and link and tag);
}

fn testWindow(screen: *vaxis.Screen) Window {
    return .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = screen.height, .screen = screen };
}

/// Columns of the cells in `row` that hold `g`.
fn columnsOf(arena: std.mem.Allocator, screen: *vaxis.Screen, row: u16, g: []const u8) ![]u16 {
    var out: std.ArrayList(u16) = .empty;
    var col: u16 = 0;
    while (col < screen.width) : (col += 1) {
        const cell = screen.readCell(col, row) orelse continue;
        if (std.mem.eql(u8, cell.char.grapheme, g)) try out.append(arena, col);
    }
    return out.items;
}

test "render: widths, wrapping, table columns line up" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .rows = 30, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    const win = testWindow(&screen);
    const text =
        \\# Grüße aus Lisboa
        \\
        \\one two three four five six seven eight nine ten eleven twelve
        \\
        \\| Day | Plan |
        \\|-----|------|
        \\| Thu | **Alfama** |
        \\| Fri | 日本語 und Straße |
        \\
        \\- [x] done
        \\- [ ] open
    ;
    const measured = try render(win, arena, text, .{}, 0, false, null);
    const drawn = try render(win, arena, text, .{}, 0, true, null);
    try std.testing.expectEqual(measured, drawn);
    // Title, underline, blank, paragraph (2 rows at 40 columns), blank,
    // table (header, rule, 2 rows), blank, 2 tasks.
    try std.testing.expectEqual(@as(u16, 13), drawn);
    // Table: the borders of every row sit in the same columns, although
    // cells hold bold text, umlauts and wide CJK characters.
    const header = try columnsOf(arena, &screen, 6, "│");
    try std.testing.expectEqual(@as(usize, 3), header.len);
    for ([_]u16{ 8, 9 }) |row| try std.testing.expectEqualSlices(u16, header, try columnsOf(arena, &screen, row, "│"));
    // The rule's crossings match the borders too.
    try std.testing.expectEqualSlices(u16, header[1..2], try columnsOf(arena, &screen, 7, "┼"));
    // The heading underline is as wide as the heading (16 columns).
    try std.testing.expectEqual(@as(usize, 16), (try columnsOf(arena, &screen, 1, "━")).len);
}

test "render: scrolled drawing clips above the pane" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .rows = 5, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    const win = testWindow(&screen);
    const text = "a\nb\nc\nd\ne\nf\ng\nh";
    try std.testing.expectEqual(@as(u16, 8), try render(win, arena, text, .{}, 0, false, null));
    _ = try render(win, arena, text, .{}, 3, true, null);
    try std.testing.expectEqualStrings("d", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("h", screen.readCell(0, 4).?.char.grapheme);
}
