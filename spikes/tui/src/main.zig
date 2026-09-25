//! omajot TUI spike on libvaxis: sources │ notes │ preview, on mock data
//! (examples/sample-notes). Not the real TUI: no daemon, no sync. See REPORT.md.
//!
//!   zig build run -- [notes-dir]      (default: ../../examples/sample-notes)
//!
//! Keys: j/k or ↓/↑ move · h/l or ←/→ change column · / search · e or Enter
//! edit in $VISUAL/$EDITOR/vi · d/u scroll the preview · g/G first/last · q quit
const std = @import("std");
const vaxis = @import("vaxis");
const notes = @import("notes.zig");
const md = @import("md.zig");
const themes = @import("theme.zig");
const Theme = themes.Theme;

/// Restores the terminal (alt screen, raw mode, kitty keyboard) on a panic.
/// Not `vaxis.Panic`: at 173a890 it still has the pre-0.15 three-argument
/// `call` and fails to compile on Zig 0.16.
pub const panic = std.debug.FullPanic(struct {
    fn call(msg: []const u8, ret_addr: ?usize) noreturn {
        vaxis.recover();
        std.debug.defaultPanic(msg, ret_addr);
    }
}.call);

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const glyph = struct {
    const all = "\u{f01c}";
    const pin = "\u{f08d}";
    const unfiled = "\u{f15c}";
    const folder = "\u{f07b}";
    const folder_open = "\u{f07c}";
    const tag = "\u{f02b}";
    const trash = "\u{f1f8}";
    const search = "\u{f002}";
    const note = "\u{f249}";
};

const Focus = enum(u2) { sources = 0, notes = 1, preview = 2 };

const App = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator, // lives as long as the app (store, edited bodies)
    io: std.Io,
    env: *std.process.Environ.Map,
    store: notes.Store,
    sources: []notes.Source,
    theme: Theme,
    focus: Focus = .notes,
    src: usize = 0,
    note: usize = 0, // index into `visible`
    visible: []usize = &.{},
    list_top: usize = 0,
    scroll: u16 = 0,
    preview_height: u16 = 0,
    preview_rows: u16 = 0,
    searching: bool = false,
    query: std.ArrayList(u8) = .empty,
    message: []const u8 = "",
    message_buf: [160]u8 = undefined,
    images: std.StringHashMapUnmanaged(vaxis.Image) = .empty,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    quit: bool = false,

    fn refilter(self: *App, keep_note: ?usize) !void {
        const prev = if (keep_note) |k| k else if (self.note < self.visible.len) self.visible[self.note] else null;
        self.visible = try notes.filter(self.arena, &self.store, self.sources[self.src], self.query.items);
        self.note = 0;
        if (prev) |p| for (self.visible, 0..) |v, i| {
            if (v == p) self.note = i;
        };
        self.scroll = 0;
    }

    fn selectedNote(self: *App) ?*notes.Note {
        if (self.note >= self.visible.len) return null;
        return &self.store.notes[self.visible[self.note]];
    }

    fn moveSource(self: *App, delta: i32) !void {
        var i: i32 = @intCast(self.src);
        while (true) {
            i += delta;
            if (i < 0 or i >= self.sources.len) return;
            if (self.sources[@intCast(i)].kind != .header) break;
        }
        self.src = @intCast(i);
        try self.refilter(null);
    }

    fn moveNote(self: *App, delta: i32) void {
        if (self.visible.len == 0) return;
        const n: i32 = @intCast(self.visible.len);
        const next = std.math.clamp(@as(i32, @intCast(self.note)) + delta, 0, n - 1);
        if (next != self.note) self.scroll = 0;
        self.note = @intCast(next);
    }

    fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.message = std.fmt.bufPrint(&self.message_buf, fmt, args) catch "";
    }

    /// Images for md.render: transmitted once per path, only with Kitty graphics.
    fn getImage(ctx: *anyopaque, path: []const u8) ?vaxis.Image {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (!self.vx.caps.kitty_graphics) return null;
        if (self.images.get(path)) |img| return img;
        const abs = std.fs.path.join(self.arena, &.{ self.store.dir, path }) catch return null;
        const img = self.vx.loadImage(self.gpa, self.tty.writer(), .{ .path = abs }) catch return null;
        self.images.put(self.arena, path, img) catch {};
        return img;
    }

    // ------------------------------------------------------------------ keys

    fn key(self: *App, k: vaxis.Key) !void {
        self.message = "";
        if (self.searching) {
            if (k.matches(vaxis.Key.escape, .{})) {
                self.searching = false;
                self.query.clearRetainingCapacity();
                try self.refilter(null);
            } else if (k.matches(vaxis.Key.enter, .{})) {
                self.searching = false;
                self.focus = .notes;
            } else if (k.matches(vaxis.Key.backspace, .{})) {
                if (self.query.items.len > 0) {
                    // drop one UTF-8 code point
                    var i = self.query.items.len - 1;
                    while (i > 0 and self.query.items[i] & 0xC0 == 0x80) i -= 1;
                    self.query.shrinkRetainingCapacity(i);
                    try self.refilter(null);
                }
            } else if (k.text) |t| {
                try self.query.appendSlice(self.arena, t);
                try self.refilter(null);
            }
            return;
        }
        if (k.matches('q', .{}) or k.matches('c', .{ .ctrl = true })) {
            self.quit = true;
        } else if (k.matches('j', .{}) or k.matches(vaxis.Key.down, .{})) {
            switch (self.focus) {
                .sources => try self.moveSource(1),
                .notes => self.moveNote(1),
                .preview => self.scrollBy(1),
            }
        } else if (k.matches('k', .{}) or k.matches(vaxis.Key.up, .{})) {
            switch (self.focus) {
                .sources => try self.moveSource(-1),
                .notes => self.moveNote(-1),
                .preview => self.scrollBy(-1),
            }
        } else if (k.matches('h', .{}) or k.matches(vaxis.Key.left, .{})) {
            self.focus = @enumFromInt(@intFromEnum(self.focus) -| 1);
        } else if (k.matches('l', .{}) or k.matches(vaxis.Key.right, .{})) {
            self.focus = @enumFromInt(@min(@intFromEnum(self.focus) + 1, 2));
        } else if (k.matches('g', .{})) {
            self.note = 0;
            self.scroll = 0;
        } else if (k.matches('G', .{}) or k.matches('g', .{ .shift = true })) {
            if (self.visible.len > 0) self.note = self.visible.len - 1;
            self.scroll = 0;
        } else if (k.matches('d', .{})) {
            self.scrollBy(@intCast(@max(self.preview_rows / 2, 1)));
        } else if (k.matches('u', .{})) {
            self.scrollBy(-@as(i32, @intCast(@max(self.preview_rows / 2, 1))));
        } else if (k.matches('/', .{})) {
            self.searching = true;
            self.focus = .notes;
        } else if (k.matches('e', .{}) or k.matches(vaxis.Key.enter, .{})) {
            try self.edit();
        } else if (k.matches('l', .{ .ctrl = true })) {
            self.vx.queueRefresh();
        } else if (k.matches('!', .{}) and self.env.get("OMAJOT_TUI_PANIC_KEY") != null) {
            @panic("test panic (OMAJOT_TUI_PANIC_KEY)"); // checks the terminal restore
        }
    }

    fn scrollBy(self: *App, delta: i32) void {
        const max: i32 = @max(@as(i32, self.preview_height) - @as(i32, self.preview_rows), 0);
        self.scroll = @intCast(std.math.clamp(@as(i32, self.scroll) + delta, 0, max));
    }

    // ---------------------------------------------------------------- editor

    /// $VISUAL, then $EDITOR, then vi; the value may carry arguments.
    fn editorCommand(self: *App) []const u8 {
        for ([_][]const u8{ "VISUAL", "EDITOR" }) |name| {
            if (self.env.get(name)) |v| if (std.mem.trim(u8, v, " ").len > 0) return v;
        }
        return "vi";
    }

    fn tempPath(self: *App, title: []const u8) ![]const u8 {
        const base = self.env.get("XDG_RUNTIME_DIR") orelse "/tmp";
        var slug: std.ArrayList(u8) = .empty;
        for (title) |b| {
            if (slug.items.len >= 40) break;
            if (std.ascii.isAlphanumeric(b)) {
                try slug.append(self.arena, std.ascii.toLower(b));
            } else if (slug.items.len > 0 and slug.items[slug.items.len - 1] != '-') {
                try slug.append(self.arena, '-');
            }
        }
        const name = std.mem.trimEnd(u8, slug.items, "-");
        return std.fmt.allocPrint(self.arena, "{s}/omajot-{s}.md", .{ base, if (name.len > 0) name else "note" });
    }

    /// Suspend the TUI, run the editor on a temporary copy, resume. The real
    /// TUI sends the changes to the daemon as a diff against this version.
    fn edit(self: *App) !void {
        const n = self.selectedNote() orelse return;
        const path = try self.tempPath(n.title);
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = path, .data = n.body });
        defer cwd.deleteFile(self.io, path) catch {};

        const editor = self.editorCommand();
        const script = try std.fmt.allocPrint(self.arena, "{s} \"$1\"", .{editor});
        const w = self.tty.writer();

        // Leave: stop reading keys, reset modes (alt screen, kitty keyboard,
        // mouse, paste), back to cooked mode so the editor owns the terminal.
        try self.vx.resetState(w);
        try w.flush();
        std.posix.tcsetattr(self.tty.fd.handle, .FLUSH, self.tty.termios) catch {};

        const ran: ?u8 = run: {
            var child = std.process.spawn(self.io, .{
                .argv = &.{ "sh", "-c", script, "omajot", path },
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
            }) catch break :run null;
            const term = child.wait(self.io) catch break :run null;
            break :run switch (term) {
                .exited => |code| code,
                else => 255,
            };
        };

        // Back: raw mode, alt screen, the detected features, a full redraw.
        _ = try vaxis.Tty.makeRaw(self.tty.fd.handle);
        try self.vx.enterAltScreen(w);
        try self.vx.enableDetectedFeatures(w);
        if (self.tty.getWinsize()) |ws| try self.vx.resize(self.gpa, w, ws) else |_| {}
        self.vx.queueRefresh();

        const code = ran orelse {
            self.say("Could not start the editor: {s}. Set $VISUAL or $EDITOR.", .{editor});
            return;
        };
        if (code == 126 or code == 127) { // sh: not executable / not found
            self.say("Cannot run the editor \"{s}\". Set $VISUAL or $EDITOR.", .{editor});
            return;
        }
        if (code != 0) {
            self.say("The editor ({s}) exited with status {d}; the note is unchanged.", .{ editor, code });
            return;
        }
        const after = try cwd.readFileAlloc(self.io, path, self.arena, .limited(16 << 20));
        if (std.mem.eql(u8, after, n.body)) {
            self.say("No changes.", .{});
            return;
        }
        const added = countLines(after) -| countLines(n.body);
        n.body = after;
        n.title = notes.titleOf(after);
        n.tags = try notes.tagsOf(self.arena, after);
        n.age_minutes = 0;
        self.say("Saved: {d} bytes, {d} new lines. The real TUI sends this as a diff.", .{ after.len, added });
    }

    // ------------------------------------------------------------------ draw

    fn panel(self: *App, parent: vaxis.Window, x: u16, width: u16, height: u16, title: []const u8, focused: bool, bg: [3]u8) vaxis.Window {
        const t = self.theme;
        const outer = parent.child(.{ .x_off = x, .width = width, .height = height });
        outer.fill(.{ .style = .{ .bg = Theme.c(bg) } });
        const inner = outer.child(.{ .border = .{ .where = .all, .style = .{ .fg = Theme.c(if (focused) t.accent else t.border), .bg = Theme.c(bg) } } });
        const label = outer.child(.{ .x_off = 2, .height = 1 });
        _ = label.print(&.{.{ .text = title, .style = .{ .fg = Theme.c(if (focused) t.accent else t.muted), .bg = Theme.c(bg), .bold = true } }}, .{ .wrap = .none });
        return inner.child(.{ .x_off = 1, .width = inner.width -| 2 });
    }

    fn drawSources(self: *App, win: vaxis.Window, fa: std.mem.Allocator) !void {
        const t = self.theme;
        for (self.sources, 0..) |s, i| {
            if (i >= win.height) break;
            const row: u16 = @intCast(i);
            const line = win.child(.{ .y_off = row, .height = 1 });
            if (s.kind == .header) {
                _ = line.print(&.{.{ .text = s.label, .style = .{ .fg = Theme.c(t.muted), .bold = true, .bg = Theme.c(t.bg_side) } }}, .{ .wrap = .none });
                continue;
            }
            const selected = i == self.src;
            const bg = if (selected) t.selection else t.bg_side;
            if (selected) line.fill(.{ .style = .{ .bg = Theme.c(bg) } });
            const icon = switch (s.kind) {
                .all => glyph.all,
                .pinned => glyph.pin,
                .unfiled => glyph.unfiled,
                .folder => if (selected) glyph.folder_open else glyph.folder,
                .tag => glyph.tag,
                .trash => glyph.trash,
                .header => "",
            };
            // Cells borrow their text until render(): never print from the stack.
            const count = if (s.count > 0) try std.fmt.allocPrint(fa, "{d}", .{s.count}) else "";
            const indent = s.depth * 2;
            const name = line.child(.{ .x_off = indent + 1, .width = line.width -| (indent + 1) -| 4 });
            _ = name.print(&.{
                .{ .text = icon, .style = .{ .fg = Theme.c(if (selected) t.accent else t.muted), .bg = Theme.c(bg) } },
                .{ .text = "  ", .style = .{ .bg = Theme.c(bg) } },
                .{ .text = if (s.kind == .tag) "#" else "", .style = .{ .fg = Theme.c(t.fg), .bg = Theme.c(bg) } },
                .{ .text = s.label, .style = .{ .fg = Theme.c(t.fg), .bg = Theme.c(bg), .bold = selected } },
            }, .{ .wrap = .none });
            const cw: u16 = @intCast(count.len);
            const cnt = line.child(.{ .x_off = line.width -| cw -| 1, .width = cw });
            _ = cnt.print(&.{.{ .text = count, .style = .{ .fg = Theme.c(t.muted), .bg = Theme.c(bg) } }}, .{ .wrap = .none });
        }
    }

    /// First text line after the title, without markdown marks.
    fn snippet(fa: std.mem.Allocator, body: []const u8) ![]const u8 {
        var it = std.mem.splitScalar(u8, body, '\n');
        _ = it.next(); // the title
        while (it.next()) |raw| {
            var l = std.mem.trim(u8, raw, " \t\r");
            if (l.len == 0 or l[0] == '#' or l[0] == '|' or std.mem.startsWith(u8, l, "![") or std.mem.startsWith(u8, l, "```") or std.mem.startsWith(u8, l, "---")) continue;
            for ([_][]const u8{ "- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "> " }) |p| {
                if (std.mem.startsWith(u8, l, p)) {
                    l = l[p.len..];
                    break;
                }
            }
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < l.len) : (i += 1) {
                switch (l[i]) {
                    '*', '`', '[' => {},
                    ']' => if (i + 1 < l.len and l[i + 1] == '(') {
                        i = std.mem.findScalarPos(u8, l, i, ')') orelse l.len;
                    },
                    else => try out.append(fa, l[i]),
                }
            }
            return out.items;
        }
        return "";
    }

    fn drawNotes(self: *App, win: vaxis.Window, fa: std.mem.Allocator) !void {
        const t = self.theme;
        var top: u16 = 0;
        if (self.searching or self.query.items.len > 0) {
            const box = win.child(.{ .height = 1 });
            box.fill(.{ .style = .{ .bg = Theme.c(t.bg_code) } });
            _ = box.print(&.{
                .{ .text = " " ++ glyph.search ++ "  ", .style = .{ .fg = Theme.c(t.accent), .bg = Theme.c(t.bg_code) } },
                .{ .text = self.query.items, .style = .{ .fg = Theme.c(t.fg), .bg = Theme.c(t.bg_code) } },
                .{ .text = if (self.searching) "▏" else "", .style = .{ .fg = Theme.c(t.accent), .bg = Theme.c(t.bg_code) } },
            }, .{ .wrap = .none });
            top = 2;
        }
        const per: u16 = 3; // title, meta, gap
        const fit: usize = @max((win.height -| top) / per, 1);
        if (self.note < self.list_top) self.list_top = self.note;
        if (self.note >= self.list_top + fit) self.list_top = self.note + 1 - fit;
        if (self.visible.len == 0) {
            const e = win.child(.{ .y_off = top + 1, .x_off = 1 });
            _ = e.print(&.{.{ .text = if (self.query.items.len > 0) "No match" else "No notes here", .style = .{ .fg = Theme.c(t.muted), .italic = true } }}, .{});
            return;
        }
        var i = self.list_top;
        while (i < self.visible.len and i < self.list_top + fit) : (i += 1) {
            const n = self.store.notes[self.visible[i]];
            const row: u16 = top + @as(u16, @intCast((i - self.list_top) * per));
            const selected = i == self.note;
            const bg = if (selected) t.selection else t.bg;
            const card = win.child(.{ .y_off = row, .height = 2 });
            if (selected) card.fill(.{ .style = .{ .bg = Theme.c(bg) } });
            const inner = card.child(.{ .x_off = 1, .width = card.width -| 2 });
            const ago_buf = try fa.alloc(u8, 16);
            _ = inner.print(&.{
                .{ .text = if (n.pinned) glyph.pin ++ " " else "", .style = .{ .fg = Theme.c(t.accent), .bg = Theme.c(bg) } },
                .{ .text = n.title, .style = .{ .fg = Theme.c(t.fg), .bg = Theme.c(bg), .bold = true } },
            }, .{ .wrap = .none });
            const meta = inner.child(.{ .y_off = 1, .height = 1 });
            _ = meta.print(&.{
                .{ .text = notes.ago(ago_buf, n.age_minutes), .style = .{ .fg = Theme.c(t.accent), .bg = Theme.c(bg) } },
                .{ .text = "  ", .style = .{ .bg = Theme.c(bg) } },
                .{ .text = try snippet(fa, n.body), .style = .{ .fg = Theme.c(t.muted), .bg = Theme.c(bg) } },
            }, .{ .wrap = .none });
        }
    }

    fn drawPreview(self: *App, win: vaxis.Window, fa: std.mem.Allocator) !void {
        const t = self.theme;
        const n = self.selectedNote() orelse {
            const e = win.child(.{ .y_off = 1 });
            _ = e.print(&.{.{ .text = "Select a note", .style = .{ .fg = Theme.c(t.muted), .italic = true } }}, .{});
            return;
        };
        const ago_buf = try fa.alloc(u8, 16);
        var meta: std.ArrayList(vaxis.Segment) = .empty;
        try meta.append(fa, .{ .text = notes.folderName(&self.store, n.folder), .style = .{ .fg = Theme.c(t.muted) } });
        try meta.append(fa, .{ .text = "  ·  ", .style = .{ .fg = Theme.c(t.border) } });
        try meta.append(fa, .{ .text = notes.ago(ago_buf, n.age_minutes), .style = .{ .fg = Theme.c(t.muted) } });
        for (n.tags) |tag| {
            try meta.append(fa, .{ .text = "  ", .style = .{} });
            try meta.append(fa, .{ .text = try std.fmt.allocPrint(fa, "#{s}", .{tag}), .style = .{ .fg = Theme.c(t.accent), .bg = Theme.c(t.bg_code) } });
        }
        _ = win.child(.{ .height = 1 }).print(meta.items, .{ .wrap = .none });
        const body = win.child(.{ .y_off = 2 });
        self.preview_rows = body.height;
        const images: md.Images = .{ .ctx = self, .get = getImage };
        self.preview_height = try md.render(body, fa, n.body, t, 0, false, images);
        self.scroll = @min(self.scroll, self.preview_height -| self.preview_rows);
        _ = try md.render(body, fa, n.body, t, self.scroll, true, images);
    }

    fn draw(self: *App, fa: std.mem.Allocator) !void {
        const t = self.theme;
        const win = self.vx.window();
        win.clear();
        win.fill(.{ .style = .{ .bg = Theme.c(t.bg) } });
        if (win.height < 3 or win.width < 20) return;
        const body_h = win.height - 1;
        const body = win.child(.{ .height = body_h });

        // Wide: three columns. Medium: notes + preview (the sources column
        // replaces the notes while it has focus). Narrow: one column.
        const w = win.width;
        const wide = w >= 110;
        const medium = !wide and w >= 70;
        var x: u16 = 0;
        if (wide or (!medium and self.focus == .sources) or (medium and self.focus == .sources)) {
            const sw: u16 = if (wide) 30 else if (medium) 34 else w;
            const inner = self.panel(body, x, sw, body_h, " omajot ", self.focus == .sources, t.bg_side);
            try self.drawSources(inner, fa);
            x += sw;
        }
        if (wide or (medium and self.focus != .sources) or (!wide and !medium and self.focus == .notes)) {
            const lw: u16 = if (wide) 44 else if (medium) 40 else w;
            const title = try std.fmt.allocPrint(fa, " {s} · {d} ", .{ self.sources[self.src].label, self.visible.len });
            const inner = self.panel(body, x, lw, body_h, title, self.focus == .notes, t.bg);
            try self.drawNotes(inner, fa);
            x += lw;
        }
        if (x < w and (wide or medium or self.focus == .preview)) {
            const inner = self.panel(body, x, w - x, body_h, " preview ", self.focus == .preview, t.bg);
            try self.drawPreview(inner, fa);
        }

        // status bar
        const bar = win.child(.{ .y_off = body_h, .height = 1 });
        bar.fill(.{ .style = .{ .bg = Theme.c(t.bg_side) } });
        const hints = if (self.searching) "type to search · Enter keep · Esc clear" else "j/k move · h/l column · / search · e edit · d/u scroll · q quit";
        const left = bar.print(&.{
            .{ .text = " ● ", .style = .{ .fg = Theme.c(t.ok), .bg = Theme.c(t.bg_side) } },
            .{ .text = "Synced (mock)", .style = .{ .fg = Theme.c(t.muted), .bg = Theme.c(t.bg_side) } },
            .{ .text = "  ", .style = .{ .bg = Theme.c(t.bg_side) } },
            .{ .text = self.message, .style = .{ .fg = Theme.c(t.accent), .bg = Theme.c(t.bg_side) } },
        }, .{ .wrap = .none });
        // Hints only where they fit: the sync state and messages win.
        const hw: u16 = @intCast(bar.gwidth(hints) + 1);
        if (left.row == 0 and !left.overflow and left.col + 2 + hw <= bar.width) _ = bar.child(.{ .x_off = bar.width - hw, .width = hw }).print(&.{.{ .text = hints, .style = .{ .fg = Theme.c(t.border), .bg = Theme.c(t.bg_side) } }}, .{ .wrap = .none });
    }
};

fn countLines(s: []const u8) usize {
    return std.mem.count(u8, s, "\n");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const dir = if (args.next()) |a| try arena.dupe(u8, a) else "../../examples/sample-notes";

    var store = notes.load(io, arena, dir) catch |err| {
        std.debug.print("omajot tui spike: cannot load notes from {s}: {s}\n", .{ dir, @errorName(err) });
        std.process.exit(1);
    };
    const theme = themes.load(io, arena, init.environ_map);

    var buffer: [16 * 1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, writer);

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    // Not done by start(): without it resizes arrive only from terminals with
    // in-band resize reports (mode 2048); tmux 3.x sends just SIGWINCH.
    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();

    try vx.enterAltScreen(writer);
    try writer.flush();
    try vx.queryTerminal(writer, .fromSeconds(1));

    var app: App = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .env = init.environ_map,
        .store = store,
        .sources = try notes.sources(arena, &store),
        .theme = theme,
        .vx = &vx,
        .tty = &tty,
    };
    try app.refilter(null);
    defer {
        var it = app.images.valueIterator();
        while (it.next()) |img| vx.freeImage(writer, img.id);
    }

    var frame_state: std.heap.ArenaAllocator = .init(gpa);
    defer frame_state.deinit();

    while (!app.quit) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |k| {
                if (k.matches('e', .{}) or k.matches(vaxis.Key.enter, .{})) {
                    if (!app.searching) {
                        // The editor needs the keys: stop the input thread first.
                        loop.stop();
                        try app.key(k);
                        try loop.start();
                    } else try app.key(k);
                } else try app.key(k);
            },
            .winsize => |ws| try vx.resize(gpa, writer, ws),
        }
        _ = frame_state.reset(.retain_capacity);
        try app.draw(frame_state.allocator());
        try vx.render(writer);
        try writer.flush();
    }
}

test {
    _ = notes;
    _ = md;
    _ = themes;
}
