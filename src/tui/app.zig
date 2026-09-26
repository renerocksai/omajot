//! `omajot tui`: sources │ notes │ preview in the terminal (libvaxis), on the
//! daemon's socket (docs/PROTOCOL.md §1).
//!
//! Two connections: requests go on one, and a thread reads the broadcast
//! events (`notes`, `folders`, `sync`, `attachment`) from the other, notes
//! what changed in `Shared` and wakes the UI with a `.daemon` event; the UI
//! then lists again. Notes are changed with `read` + `put` (never `open`), so
//! the Omarchy plugin and the PWA can have the same note open.
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const client = @import("../cli/client.zig");
const editor = @import("../cli/editor.zig");
const editsession = @import("../cli/editsession.zig");
const paths = @import("../daemon/paths.zig");
const daemon = @import("../daemon/daemon.zig");
const model = @import("model.zig");
const md = @import("md.zig");
const keys = @import("keys.zig");
const Theme = @import("theme.zig").Theme;

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    /// The event thread has news; see `Shared`.
    daemon,
};

const Loop = vaxis.Loop(Event);

const glyph = struct {
    const all = "\u{f01c}";
    const pin = "\u{f08d}";
    const unfiled = "\u{f15c}";
    const folder = "\u{f07b}";
    const folder_open = "\u{f07c}";
    const tag = "\u{f02b}";
    const trash = "\u{f1f8}";
    const search = "\u{f002}";
    const check = "\u{f00c}";
};

pub const SyncState = enum(u8) { unknown, online, connecting, offline, conflict, lost };

/// Written by the event thread, read by the UI.
const Shared = struct {
    notes_dirty: std.atomic.Value(bool) = .init(false),
    attachment: std.atomic.Value(bool) = .init(false),
    sync: std.atomic.Value(u8) = .init(@intFromEnum(SyncState.unknown)),
    pending: std.atomic.Value(u32) = .init(0),
    /// 0: not known yet, 1: a hub, 2: no hub (local only).
    hub: std.atomic.Value(u8) = .init(0),
};

const Focus = enum(u2) { sources = 0, notes = 1, preview = 2 };
const Mode = enum { browse, search, prompt, picker, help };
const Prompt = enum { new_note, new_folder, rename_folder };
const Tone = enum { info, ok, warn };

pub const App = struct {
    gpa: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    where: paths.Resolved,
    opts: client.Options,
    theme: Theme,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    loop: *Loop,
    shared: Shared = .{},

    conn: ?*client.Client = null,
    data_dir: []const u8 = "",
    scratch: std.heap.ArenaAllocator,

    list_arena: std.heap.ArenaAllocator,
    store: model.Store = .{},
    sources: []model.Source = &.{},
    view_arena: std.heap.ArenaAllocator,
    visible: []usize = &.{},
    search_arena: std.heap.ArenaAllocator,
    hits: ?std.StringHashMapUnmanaged(void) = null,
    query: std.ArrayList(u8) = .empty,

    mode: Mode = .browse,
    prompt: Prompt = .new_note,
    prompt_label: []const u8 = "",
    input: std.ArrayList(u8) = .empty,
    picker_arena: std.heap.ArenaAllocator,
    picker: []model.Target = &.{},
    picker_sel: usize = 0,

    focus: Focus = .notes,
    src: usize = 0,
    src_top: usize = 0,
    note: usize = 0,
    list_top: usize = 0,
    scroll: u16 = 0,
    preview_height: u16 = 0,
    preview_rows: u16 = 0,
    preview_id: std.ArrayList(u8) = .empty,
    preview_updated: i64 = -1,
    preview_text: std.ArrayList(u8) = .empty,

    message: []const u8 = "",
    message_buf: [320]u8 = undefined,
    tone: Tone = .info,

    images: std.StringHashMapUnmanaged(md.Images.Picture) = .empty,
    quit: bool = false,

    pub fn deinit(app: *App) void {
        var it = app.images.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == .image) app.vx.freeImage(app.tty.writer(), e.value_ptr.image.id);
            app.gpa.free(e.key_ptr.*);
        }
        app.images.deinit(app.gpa);
        app.query.deinit(app.gpa);
        app.input.deinit(app.gpa);
        app.preview_id.deinit(app.gpa);
        app.preview_text.deinit(app.gpa);
        app.list_arena.deinit();
        app.view_arena.deinit();
        app.search_arena.deinit();
        app.picker_arena.deinit();
        app.scratch.deinit();
        if (app.conn) |c| c.deinit();
    }

    fn say(app: *App, tone: Tone, comptime fmt: []const u8, args: anytype) void {
        app.tone = tone;
        app.message = std.fmt.bufPrint(&app.message_buf, fmt, args) catch blk: {
            // Too long: cut at a UTF-8 boundary and mark the cut.
            var cut: usize = app.message_buf.len - 3;
            while (cut > 0 and app.message_buf[cut] & 0xC0 == 0x80) cut -= 1;
            @memcpy(app.message_buf[cut .. cut + 3], "…");
            break :blk app.message_buf[0 .. cut + 3];
        };
    }

    // ------------------------------------------------------------ daemon

    /// Connect (or reconnect) the request connection.
    pub fn connect(app: *App, allow_start: bool) !*client.Client {
        if (app.conn) |c| return c;
        var why: std.ArrayList(u8) = .empty;
        defer why.deinit(app.gpa);
        var opts = app.opts;
        if (!allow_start) opts.no_start = true;
        const c = try client.open(app.gpa, app.io, app.where, opts, &why);
        errdefer c.deinit();
        var a: std.heap.ArenaAllocator = .init(app.gpa);
        defer a.deinit();
        _ = try c.call(a.allocator(), "hello", .{ .client = "tui" });
        app.conn = c;
        return c;
    }

    /// One request. A refusal or a lost daemon becomes a message and error.Failed.
    fn call(app: *App, arena: Allocator, cmd: []const u8, fields: anytype) !json.ObjectMap {
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const c = app.connect(false) catch {
                app.say(.warn, "The omajot daemon is not running. omajot tries again in the background.", .{});
                return error.Failed;
            };
            return c.call(arena, cmd, fields) catch |err| switch (err) {
                error.Refused => {
                    app.say(.warn, "{s}", .{c.last_error});
                    return error.Failed;
                },
                error.ConnectionLost => {
                    c.deinit();
                    app.conn = null;
                    if (attempt == 0) continue;
                    app.say(.warn, "Lost the connection to the omajot daemon.", .{});
                    return error.Failed;
                },
            };
        }
    }

    /// `list` again; keeps the selected source and note where they still exist.
    pub fn refresh(app: *App) !void {
        var fresh: std.heap.ArenaAllocator = .init(app.gpa);
        var owned = true; // until it replaces list_arena
        defer if (owned) fresh.deinit();
        const a = fresh.allocator();
        const reply = app.call(a, "list", .{}) catch return;
        const parsed = json.parseFromValueLeaky(struct { notes: []model.Note, folders: []model.Folder }, a, .{ .object = reply }, .{ .ignore_unknown_fields = true }) catch {
            app.say(.warn, "The daemon sent a list this version of omajot cannot read.", .{});
            return;
        };
        const store: model.Store = .{ .notes = parsed.notes, .folders = parsed.folders };
        const sources = try model.sources(a, store);

        // The old selection, before its arena goes away.
        const old_src: ?model.Source = if (app.src < app.sources.len) app.sources[app.src] else null;
        var keep_id: []const u8 = "";
        if (app.selected()) |n| keep_id = try a.dupe(u8, n.id);
        var src: usize = 0;
        if (old_src) |o| {
            src = for (sources, 0..) |s, i| {
                if (s.same(o)) break i;
            } else @min(app.src, sources.len - 1);
            if (sources[src].kind == .header) src = 0;
        }
        app.list_arena.deinit();
        app.list_arena = fresh;
        owned = false;
        app.store = store;
        app.sources = sources;
        app.src = src;
        if (app.query.items.len > 0) try app.runSearch();
        try app.refilter(keep_id);
    }

    /// The visible notes for the source and the search; keeps `keep_id` selected.
    fn refilter(app: *App, keep_id: []const u8) !void {
        _ = app.view_arena.reset(.retain_capacity);
        const hits: ?*const std.StringHashMapUnmanaged(void) = if (app.hits) |*h| h else null;
        const src = if (app.src < app.sources.len) app.sources[app.src] else model.Source{ .kind = .all, .label = "" };
        app.visible = try model.filter(app.view_arena.allocator(), app.store, src, hits);
        const before = app.note;
        app.note = @min(app.note, app.visible.len -| 1);
        if (keep_id.len > 0) for (app.visible, 0..) |v, i| {
            if (std.mem.eql(u8, app.store.notes[v].id, keep_id)) app.note = i;
        };
        if (app.note != before) app.scroll = 0;
    }

    fn selected(app: *App) ?model.Note {
        if (app.note >= app.visible.len) return null;
        return app.store.notes[app.visible[app.note]];
    }

    fn selectedId(app: *App) []const u8 {
        return if (app.selected()) |n| n.id else "";
    }

    fn currentSource(app: *App) model.Source {
        return if (app.src < app.sources.len) app.sources[app.src] else .{ .kind = .all, .label = "All notes" };
    }

    /// Select a note by id, switching to All notes (and dropping the search)
    /// when the current view does not show it.
    fn selectNote(app: *App, id: []const u8) !void {
        for (app.visible, 0..) |v, i| if (std.mem.eql(u8, app.store.notes[v].id, id)) {
            app.note = i;
            app.scroll = 0;
            return;
        };
        app.clearSearchState();
        app.src = 0;
        app.note = 0;
        try app.refilter(id);
    }

    /// Server-side search for `query`: the hits filter the list.
    fn runSearch(app: *App) !void {
        _ = app.search_arena.reset(.retain_capacity);
        app.hits = null;
        if (app.query.items.len == 0) return;
        const a = app.search_arena.allocator();
        const reply = app.call(a, "search", .{ .q = app.query.items }) catch return;
        var hits: std.StringHashMapUnmanaged(void) = .empty;
        if (reply.get("ids")) |ids| if (ids == .array) for (ids.array.items) |v| {
            if (v == .string) try hits.put(a, v.string, {});
        };
        app.hits = hits;
    }

    fn clearSearchState(app: *App) void {
        app.query.clearRetainingCapacity();
        app.hits = null;
        _ = app.search_arena.reset(.retain_capacity);
    }

    /// What the event thread noticed since the last look.
    pub fn onDaemon(app: *App) !void {
        if (app.shared.attachment.swap(false, .acq_rel)) app.forgetPictures(true);
        if (app.shared.notes_dirty.swap(false, .acq_rel)) try app.refresh();
    }

    // ------------------------------------------------------------ preview

    /// The text of the selected note, read again when it changed.
    fn previewText(app: *App) []const u8 {
        const n = app.selected() orelse return "";
        if (std.mem.eql(u8, app.preview_id.items, n.id) and app.preview_updated == n.updated) return app.preview_text.items;
        const reply = app.call(app.scratch.allocator(), "read", .{ .note = n.id }) catch return "";
        const text = if (reply.get("text")) |t| (if (t == .string) t.string else "") else "";
        if (!std.mem.eql(u8, app.preview_id.items, n.id)) app.scroll = 0;
        app.preview_id.clearRetainingCapacity();
        app.preview_text.clearRetainingCapacity();
        app.preview_id.appendSlice(app.gpa, n.id) catch return "";
        app.preview_text.appendSlice(app.gpa, text) catch return "";
        app.preview_updated = n.updated;
        return app.preview_text.items;
    }

    fn forgetPreview(app: *App) void {
        app.preview_updated = -1;
    }

    /// md.Images: pictures from the attachments directory, sent to the
    /// terminal once (Kitty graphics protocol).
    fn getPicture(ctx: *anyopaque, path: []const u8) md.Images.Picture {
        const app: *App = @ptrCast(@alignCast(ctx));
        if (!app.vx.caps.kitty_graphics) return .no_graphics;
        if (app.images.get(path)) |p| return p;
        const picture: md.Images.Picture = load: {
            if (!std.mem.startsWith(u8, path, "attachments/") or std.mem.indexOf(u8, path, "..") != null) break :load .missing;
            const abs = std.fs.path.join(app.scratch.allocator(), &.{ app.data_dir, path }) catch break :load .missing;
            _ = Io.Dir.cwd().statFile(app.io, abs, .{}) catch break :load .missing;
            const img = app.vx.loadImage(app.gpa, app.tty.writer(), .{ .path = abs }) catch break :load .missing;
            break :load .{ .image = img };
        };
        const key = app.gpa.dupe(u8, path) catch return picture;
        app.images.put(app.gpa, key, picture) catch app.gpa.free(key);
        return picture;
    }

    /// Forget pictures: the missing ones (an attachment arrived), or all
    /// (the terminal dropped them during an editor round trip).
    fn forgetPictures(app: *App, only_missing: bool) void {
        var drop: std.ArrayList([]const u8) = .empty;
        defer drop.deinit(app.gpa);
        var it = app.images.iterator();
        while (it.next()) |e| {
            if (only_missing and e.value_ptr.* != .missing) continue;
            if (e.value_ptr.* == .image) app.vx.freeImage(app.tty.writer(), e.value_ptr.image.id);
            drop.append(app.gpa, e.key_ptr.*) catch return;
        }
        for (drop.items) |key| {
            _ = app.images.remove(key);
            app.gpa.free(key);
        }
    }

    // ------------------------------------------------------------ keys

    pub fn onKey(app: *App, k: vaxis.Key) !void {
        switch (app.mode) {
            .help => {
                app.mode = .browse;
                return;
            },
            .search => return app.searchKey(k),
            .prompt => return app.promptKey(k),
            .picker => return app.pickerKey(k),
            .browse => {},
        }
        app.message = "";
        if (k.matches(vaxis.Key.escape, .{})) {
            if (app.query.items.len > 0) {
                const keep = try app.scratch.allocator().dupe(u8, app.selectedId());
                app.clearSearchState();
                try app.refilter(keep);
            }
            return;
        }
        if (k.matches('!', .{}) and app.env.get("OMAJOT_TUI_PANIC_KEY") != null) {
            @panic("test panic (OMAJOT_TUI_PANIC_KEY)"); // checks the terminal restore
        }
        switch (keys.map(k)) {
            .none => {},
            .quit => app.quit = true,
            .down => try app.move(1),
            .up => try app.move(-1),
            .left => app.focus = @enumFromInt(@intFromEnum(app.focus) -| 1),
            .right => app.focus = @enumFromInt(@min(@intFromEnum(app.focus) + 1, 2)),
            .next_column => app.focus = @enumFromInt((@as(u8, @intFromEnum(app.focus)) + 1) % 3),
            .first => switch (app.focus) {
                .sources => try app.setSource(0),
                .notes => app.setNote(0),
                .preview => app.scroll = 0,
            },
            .last => switch (app.focus) {
                .sources => try app.setSource(app.sources.len -| 1),
                .notes => app.setNote(app.visible.len -| 1),
                .preview => app.scrollBy(std.math.maxInt(i32) / 2),
            },
            .scroll_down => app.scrollBy(@max(app.preview_rows / 2, 1)),
            .scroll_up => app.scrollBy(-@as(i32, @max(app.preview_rows / 2, 1))),
            .search => {
                app.mode = .search;
                if (app.focus == .sources) app.focus = .notes;
            },
            .edit => if (app.focus == .sources) {
                app.focus = .notes;
            } else if (app.selected()) |n| {
                try app.editNote(n.id, n.title);
            },
            .new_note => app.startPrompt(.new_note, "Title of the new note", ""),
            .new_folder => {
                const s = app.currentSource();
                const label = if (s.kind == .folder)
                    try std.fmt.allocPrint(app.picker_arena.allocator(), "New folder in {s}", .{s.label})
                else
                    "New folder";
                app.startPrompt(.new_folder, label, "");
            },
            .rename_folder => {
                const s = app.currentSource();
                if (s.kind != .folder) {
                    app.say(.info, "Select a folder in the left column (h), then press r to rename it.", .{});
                    return;
                }
                app.startPrompt(.rename_folder, "Rename the folder", s.label);
            },
            .pin => if (app.selected()) |n| {
                _ = app.call(app.scratch.allocator(), "set", .{ .note = n.id, .pinned = !n.pinned }) catch return;
                app.say(.ok, "{s} \u{201c}{s}\u{201d}", .{ if (n.pinned) "Unpinned" else "Pinned", title(n.title) });
                try app.refresh();
            },
            .trash => if (app.selected()) |n| {
                _ = app.call(app.scratch.allocator(), "set", .{ .note = n.id, .trashed = !n.trashed }) catch return;
                if (n.trashed) {
                    app.say(.ok, "Restored \u{201c}{s}\u{201d}", .{title(n.title)});
                } else {
                    app.say(.ok, "Moved \u{201c}{s}\u{201d} to the Trash. In the Trash, x restores it.", .{title(n.title)});
                }
                try app.refresh();
            },
            .move => if (app.selected()) |n| {
                _ = app.picker_arena.reset(.retain_capacity);
                app.picker = try model.targets(app.picker_arena.allocator(), app.store);
                app.picker_sel = 0;
                for (app.picker, 0..) |t, i| if (sameFolder(t.id, n.folder)) {
                    app.picker_sel = i;
                };
                app.mode = .picker;
            },
            .help => app.mode = .help,
            .redraw => app.vx.queueRefresh(),
        }
    }

    fn move(app: *App, delta: i32) !void {
        switch (app.focus) {
            .sources => {
                var i: i32 = @intCast(app.src);
                while (true) {
                    i += delta;
                    if (i < 0 or i >= app.sources.len) return;
                    if (app.sources[@intCast(i)].kind != .header) break;
                }
                try app.setSource(@intCast(i));
            },
            .notes => {
                if (app.visible.len == 0) return;
                const n: i32 = @intCast(app.visible.len);
                app.setNote(@intCast(std.math.clamp(@as(i32, @intCast(app.note)) + delta, 0, n - 1)));
            },
            .preview => app.scrollBy(delta),
        }
    }

    fn setSource(app: *App, i: usize) !void {
        var j = @min(i, app.sources.len -| 1);
        while (j > 0 and app.sources[j].kind == .header) j -= 1;
        if (j == app.src) return;
        app.src = j;
        app.note = 0;
        app.list_top = 0;
        app.scroll = 0;
        try app.refilter("");
    }

    fn setNote(app: *App, i: usize) void {
        if (i != app.note) app.scroll = 0;
        app.note = i;
    }

    fn scrollBy(app: *App, delta: i32) void {
        const max: i32 = @max(@as(i32, app.preview_height) - @as(i32, app.preview_rows), 0);
        app.scroll = @intCast(std.math.clamp(@as(i32, app.scroll) +| delta, 0, max));
    }

    /// Returns true when the key changed the input text.
    fn editInput(list: *std.ArrayList(u8), gpa: Allocator, k: vaxis.Key) !bool {
        if (k.matches(vaxis.Key.backspace, .{})) {
            if (list.items.len == 0) return false;
            var i = list.items.len - 1;
            while (i > 0 and list.items[i] & 0xC0 == 0x80) i -= 1;
            list.shrinkRetainingCapacity(i);
            return true;
        }
        if (k.matches('u', .{ .ctrl = true })) {
            list.clearRetainingCapacity();
            return true;
        }
        if (k.matches('w', .{ .ctrl = true })) {
            const t = std.mem.trimEnd(u8, list.items, " ");
            const cut = if (std.mem.lastIndexOfScalar(u8, t, ' ')) |sp| sp + 1 else 0;
            list.shrinkRetainingCapacity(cut);
            return true;
        }
        if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
        const text = k.text orelse return false;
        for (text) |b| if (b < 0x20 or b == 0x7f) return false;
        try list.appendSlice(gpa, text);
        return true;
    }

    fn searchKey(app: *App, k: vaxis.Key) !void {
        const keep = try app.scratch.allocator().dupe(u8, app.selectedId());
        if (k.matches(vaxis.Key.escape, .{})) {
            app.mode = .browse;
            app.clearSearchState();
            try app.refilter(keep);
        } else if (k.matches(vaxis.Key.enter, .{}) or k.matches(vaxis.Key.down, .{})) {
            app.mode = .browse;
            app.focus = .notes;
        } else if (try editInput(&app.query, app.gpa, k)) {
            app.note = 0;
            try app.runSearch();
            try app.refilter("");
        }
    }

    fn startPrompt(app: *App, kind: Prompt, label: []const u8, initial: []const u8) void {
        app.prompt = kind;
        app.prompt_label = label;
        app.input.clearRetainingCapacity();
        app.input.appendSlice(app.gpa, initial) catch {};
        app.mode = .prompt;
    }

    fn promptKey(app: *App, k: vaxis.Key) !void {
        if (k.matches(vaxis.Key.escape, .{})) {
            app.mode = .browse;
            return;
        }
        if (!k.matches(vaxis.Key.enter, .{})) {
            _ = try editInput(&app.input, app.gpa, k);
            return;
        }
        app.mode = .browse;
        const text = std.mem.trim(u8, app.input.items, " \t");
        const a = app.scratch.allocator();
        const s = app.currentSource();
        const folder: ?[]const u8 = if (s.kind == .folder) s.id else null;
        switch (app.prompt) {
            .new_note => {
                if (text.len == 0) return app.say(.info, "No title: no note made.", .{});
                // In a tag's list, the new note carries the tag.
                const body = if (s.kind == .tag)
                    try std.fmt.allocPrint(a, "# {s}\n\n#{s}\n", .{ text, s.id })
                else
                    try std.fmt.allocPrint(a, "# {s}\n\n", .{text});
                const reply = app.call(a, "create", .{ .folder = folder, .text = body }) catch return;
                const id = try a.dupe(u8, reply.get("note").?.string);
                const name = try a.dupe(u8, text);
                if (s.kind == .trash) try app.setSource(0);
                try app.refresh();
                try app.selectNote(id);
                app.focus = .notes;
                try app.editNote(id, name);
            },
            .new_folder => {
                if (text.len == 0) return app.say(.info, "No name: no folder made.", .{});
                const reply = app.call(a, "folder.create", .{ .name = text, .parent = folder }) catch return;
                const id = try a.dupe(u8, reply.get("folder").?.string);
                try app.refresh();
                for (app.sources, 0..) |x, i| if (x.kind == .folder and std.mem.eql(u8, x.id, id)) try app.setSource(i);
                app.focus = .sources;
                app.say(.ok, "Made the folder \u{201c}{s}\u{201d}", .{text});
            },
            .rename_folder => {
                if (text.len == 0 or folder == null) return;
                _ = app.call(a, "folder.rename", .{ .folder = folder.?, .name = text }) catch return;
                app.say(.ok, "Renamed the folder to \u{201c}{s}\u{201d}", .{text});
                try app.refresh();
            },
        }
    }

    fn pickerKey(app: *App, k: vaxis.Key) !void {
        const action = keys.map(k);
        if (k.matches(vaxis.Key.escape, .{}) or action == .quit) {
            app.mode = .browse;
        } else if (action == .down) {
            app.picker_sel = @min(app.picker_sel + 1, app.picker.len -| 1);
        } else if (action == .up) {
            app.picker_sel -|= 1;
        } else if (action == .first) {
            app.picker_sel = 0;
        } else if (action == .last) {
            app.picker_sel = app.picker.len -| 1;
        } else if (k.matches(vaxis.Key.enter, .{})) {
            app.mode = .browse;
            const n = app.selected() orelse return;
            if (app.picker_sel >= app.picker.len) return;
            const t = app.picker[app.picker_sel];
            const a = app.scratch.allocator();
            const id = try a.dupe(u8, n.id);
            const name = try a.dupe(u8, title(n.title));
            const where = try app.store.folderPath(a, t.id);
            _ = app.call(a, "set", .{ .note = id, .folder = t.id }) catch return;
            app.say(.ok, "Moved \u{201c}{s}\u{201d} to {s}", .{ name, where });
            try app.refresh();
        }
    }

    // ------------------------------------------------------------ editor

    /// Leave the terminal to the editor: no input thread, the terminal's
    /// own modes and cooked mode.
    fn suspendTerminal(app: *App) void {
        app.loop.stop();
        const w = app.tty.writer();
        app.vx.resetState(w) catch {};
        w.flush() catch {};
        switch (builtin.os.tag) {
            .windows => {
                vaxis.Tty.setConsoleMode(app.tty.stdin, app.tty.initial_input_mode) catch {};
                vaxis.Tty.setConsoleMode(app.tty.stdout, app.tty.initial_output_mode) catch {};
            },
            else => std.posix.tcsetattr(app.tty.fd.handle, .FLUSH, app.tty.termios) catch {},
        }
    }

    /// Back from the editor: raw mode, alt screen, the detected features, a
    /// full redraw at the current size, input again.
    fn resumeTerminal(app: *App) !void {
        const w = app.tty.writer();
        switch (builtin.os.tag) {
            .windows => {
                vaxis.Tty.setConsoleMode(app.tty.stdin, vaxis.Tty.input_raw_mode) catch {};
                vaxis.Tty.setConsoleMode(app.tty.stdout, vaxis.Tty.output_raw_mode) catch {};
            },
            else => _ = try vaxis.Tty.makeRaw(app.tty.fd.handle),
        }
        try app.vx.enterAltScreen(w);
        try app.vx.enableDetectedFeatures(w);
        if (app.tty.getWinsize()) |ws| try app.vx.resize(app.gpa, w, ws) else |_| {}
        app.vx.queueRefresh();
        // Pictures were drawn on the screen the editor replaced.
        app.forgetPictures(false);
        try app.loop.start();
    }

    /// Edit a note in $VISUAL / $EDITOR. Every save goes to the daemon as a
    /// `put` based on the previous save, so changes made elsewhere meanwhile
    /// are merged, not overwritten.
    fn editNote(app: *App, id_in: []const u8, title_in: []const u8) !void {
        const a = app.scratch.allocator();
        const id = try a.dupe(u8, id_in);
        const name = try a.dupe(u8, title(title_in));
        const choice = editor.choose(app.io, app.env) catch {
            app.say(.warn, "{s}", .{std.mem.trimEnd(u8, editor.no_editor_message, "\n")});
            return;
        };
        const before = app.call(a, "read", .{ .note = id }) catch return;
        const text = before.get("text").?.string;
        const c = app.connect(false) catch return;
        const s = editsession.Session.begin(app.gpa, app.io, app.env, c, id, name, text) catch |err| {
            app.say(.warn, "Cannot write the note to a private file: {s}", .{@errorName(err)});
            return;
        };
        defer s.deinit();

        app.suspendTerminal();
        const code = s.run(a, choice) catch |err| {
            try app.resumeTerminal();
            app.say(.warn, "Cannot start the editor \"{s}\": {s}", .{ choice.command, @errorName(err) });
            return;
        };
        try app.resumeTerminal();

        app.forgetPreview();
        try app.refresh();
        if (s.failed) |f| {
            app.say(.warn, "Could not save your changes: {s}. Your text is in {s}", .{ f, s.file });
            return;
        }
        if (s.saves == 0) {
            if (code == 126 or code == 127) {
                app.say(.warn, "Cannot run the editor \"{s}\". Set $VISUAL or $EDITOR.", .{choice.command});
            } else if (code != 0) {
                app.say(.warn, "The editor exited with status {d}; the note is unchanged.", .{code});
            } else {
                app.say(.info, "No changes to \u{201c}{s}\u{201d}", .{name});
            }
            return;
        }
        const after = app.call(a, "read", .{ .note = id }) catch return;
        const merged = !std.mem.eql(u8, after.get("text").?.string, s.last);
        const saves: []const u8 = if (s.saves == 1) "" else try std.fmt.allocPrint(a, " ({d} saves)", .{s.saves});
        if (merged) {
            app.say(.ok, "Saved and merged \u{201c}{s}\u{201d}{s}: it also changed elsewhere; omajot kept both changes.", .{ name, saves });
        } else {
            app.say(.ok, "Saved \u{201c}{s}\u{201d}{s}", .{ name, saves });
        }
    }

    // ------------------------------------------------------------ draw

    fn st(app: *App, fg: [3]u8, bg: [3]u8) vaxis.Style {
        return .{ .fg = app.theme.c(fg), .bg = app.theme.c(bg) };
    }

    /// The selection: the theme's selection colour, reverse video in NO_COLOR.
    fn selStyle(app: *App, s: vaxis.Style) vaxis.Style {
        var out = s;
        if (app.theme.mono) out.reverse = true else out.bg = app.theme.c(app.theme.selection);
        return out;
    }

    fn panel(app: *App, parent: vaxis.Window, x: u16, width: u16, height: u16, label: []const u8, focused: bool, bg: [3]u8) vaxis.Window {
        const t = app.theme;
        const outer = parent.child(.{ .x_off = x, .width = width, .height = height });
        outer.fill(.{ .style = .{ .bg = t.c(bg) } });
        const inner = outer.child(.{ .border = .{ .where = .all, .style = .{ .fg = t.c(if (focused) t.accent else t.border), .bg = t.c(bg), .bold = focused and t.mono } } });
        const lab = outer.child(.{ .x_off = 2, .width = width -| 4, .height = 1 });
        _ = lab.print(&.{.{ .text = label, .style = .{ .fg = t.c(if (focused) t.accent else t.muted), .bg = t.c(bg), .bold = true } }}, .{ .wrap = .none });
        return inner.child(.{ .x_off = 1, .width = inner.width -| 2 });
    }

    fn drawSources(app: *App, win: vaxis.Window, fa: Allocator) !void {
        const t = app.theme;
        const h: usize = win.height;
        if (h == 0) return;
        if (app.src < app.src_top) app.src_top = app.src;
        if (app.src >= app.src_top + h) app.src_top = app.src + 1 - h;
        var i = app.src_top;
        while (i < app.sources.len and i < app.src_top + h) : (i += 1) {
            const s = app.sources[i];
            const line = win.child(.{ .y_off = @intCast(i - app.src_top), .height = 1 });
            if (s.kind == .header) {
                _ = line.print(&.{.{ .text = s.label, .style = .{ .fg = t.c(t.muted), .bg = t.c(t.bg_side), .bold = true } }}, .{ .wrap = .none });
                continue;
            }
            const is_sel = i == app.src;
            var base = app.st(t.fg, t.bg_side);
            if (is_sel) {
                base = app.selStyle(base);
                line.fill(.{ .style = base });
            }
            const icon = switch (s.kind) {
                .all => glyph.all,
                .pinned => glyph.pin,
                .unfiled => glyph.unfiled,
                .folder => if (is_sel) glyph.folder_open else glyph.folder,
                .tag => glyph.tag,
                .trash => glyph.trash,
                .header => "",
            };
            var icon_st = base;
            icon_st.fg = t.c(if (is_sel) t.accent else t.muted);
            var name_st = base;
            name_st.bold = is_sel;
            const count = if (s.count > 0) try std.fmt.allocPrint(fa, "{d}", .{s.count}) else "";
            const cw: u16 = @intCast(count.len);
            const indent: u16 = @as(u16, s.depth) * 2;
            const name = line.child(.{ .x_off = indent + 1, .width = line.width -| (indent + 1) -| (cw + 2) });
            _ = name.print(&.{
                .{ .text = icon, .style = icon_st },
                .{ .text = "  ", .style = base },
                .{ .text = if (s.kind == .tag) "#" else "", .style = name_st },
                .{ .text = s.label, .style = name_st },
            }, .{ .wrap = .none });
            var cnt_st = base;
            cnt_st.fg = t.c(t.muted);
            _ = line.child(.{ .x_off = line.width -| cw -| 1, .width = cw }).print(&.{.{ .text = count, .style = cnt_st }}, .{ .wrap = .none });
        }
    }

    fn drawNotes(app: *App, win: vaxis.Window, fa: Allocator) !void {
        const t = app.theme;
        var top: u16 = 0;
        if (app.mode == .search or app.query.items.len > 0) {
            const field = win.child(.{ .height = 1 });
            const bs = app.st(t.fg, t.bg_code);
            field.fill(.{ .style = bs });
            _ = field.print(&.{
                .{ .text = " " ++ glyph.search ++ "  ", .style = app.st(t.accent, t.bg_code) },
                .{ .text = app.query.items, .style = bs },
                .{ .text = if (app.mode == .search) "▏" else "", .style = app.st(t.accent, t.bg_code) },
            }, .{ .wrap = .none });
            top = 2;
        }
        const per: u16 = 3; // title, time + snippet, gap
        const fit: usize = @max((win.height -| top) / per, 1);
        if (app.note < app.list_top) app.list_top = app.note;
        if (app.note >= app.list_top + fit) app.list_top = app.note + 1 - fit;
        if (app.list_top > app.visible.len) app.list_top = 0;
        if (app.visible.len == 0) {
            const src = app.currentSource();
            const empty = if (app.query.items.len > 0) "No match" else if (src.kind == .trash) "The Trash is empty" else "No notes here. n makes one.";
            _ = win.child(.{ .y_off = top + 1, .x_off = 1 }).print(&.{.{ .text = empty, .style = .{ .fg = t.c(t.muted), .italic = true } }}, .{});
            return;
        }
        const now = Io.Clock.real.now(app.io).toMilliseconds();
        var i = app.list_top;
        while (i < app.visible.len and i < app.list_top + fit) : (i += 1) {
            const n = app.store.notes[app.visible[i]];
            const row: u16 = top + @as(u16, @intCast((i - app.list_top) * per));
            const is_sel = i == app.note;
            var base = app.st(t.fg, t.bg);
            const card = win.child(.{ .y_off = row, .height = 2 });
            if (is_sel) {
                base = app.selStyle(base);
                card.fill(.{ .style = base });
            }
            const inner = card.child(.{ .x_off = 1, .width = card.width -| 2 });
            var segs: std.ArrayList(vaxis.Segment) = .empty;
            var pin_st = base;
            pin_st.fg = t.c(t.accent);
            var title_st = base;
            title_st.bold = true;
            if (n.pinned) try segs.append(fa, .{ .text = glyph.pin ++ " ", .style = pin_st });
            try segs.append(fa, .{ .text = title(n.title), .style = title_st });
            var tag_st = base;
            tag_st.fg = t.c(t.accent);
            for (n.tags) |tag| {
                try segs.append(fa, .{ .text = "  ", .style = base });
                try segs.append(fa, .{ .text = try std.fmt.allocPrint(fa, "#{s}", .{tag}), .style = tag_st });
            }
            _ = inner.print(segs.items, .{ .wrap = .none });
            const ago_buf = try fa.alloc(u8, 24);
            var time_st = base;
            time_st.fg = t.c(t.accent);
            var snip_st = base;
            snip_st.fg = t.c(t.muted);
            _ = inner.child(.{ .y_off = 1, .height = 1 }).print(&.{
                .{ .text = model.ago(ago_buf, now, n.updated), .style = time_st },
                .{ .text = "  ", .style = base },
                .{ .text = try model.plainSnippet(fa, n.snippet), .style = snip_st },
            }, .{ .wrap = .none });
        }
    }

    fn drawPreview(app: *App, win: vaxis.Window, fa: Allocator) !void {
        const t = app.theme;
        const n = app.selected() orelse {
            _ = win.child(.{ .y_off = 1 }).print(&.{.{ .text = "Select a note", .style = .{ .fg = t.c(t.muted), .italic = true } }}, .{});
            return;
        };
        const text = app.previewText();
        const now = Io.Clock.real.now(app.io).toMilliseconds();
        const ago_buf = try fa.alloc(u8, 24);
        const muted: vaxis.Style = .{ .fg = t.c(t.muted) };
        var meta: std.ArrayList(vaxis.Segment) = .empty;
        if (n.trashed) try meta.append(fa, .{ .text = glyph.trash ++ " In the Trash  ·  ", .style = .{ .fg = t.c(t.warn) } });
        try meta.append(fa, .{ .text = try app.store.folderPath(fa, n.folder), .style = muted });
        try meta.append(fa, .{ .text = "  ·  ", .style = .{ .fg = t.c(t.border) } });
        try meta.append(fa, .{ .text = model.ago(ago_buf, now, n.updated), .style = muted });
        if (n.pinned) try meta.append(fa, .{ .text = "  " ++ glyph.pin, .style = .{ .fg = t.c(t.accent) } });
        _ = win.child(.{ .height = 1 }).print(meta.items, .{ .wrap = .none });
        const body = win.child(.{ .y_off = 2 });
        app.preview_rows = body.height;
        const images: md.Images = .{ .ctx = app, .get = getPicture };
        app.preview_height = try md.render(body, fa, text, t, 0, false, images);
        app.scroll = @min(app.scroll, app.preview_height -| app.preview_rows);
        _ = try md.render(body, fa, text, t, app.scroll, true, images);
    }

    /// A bordered box in the middle of `win`; returns its inside.
    fn box(app: *App, win: vaxis.Window, width: u16, height: u16, label: []const u8) vaxis.Window {
        const w = @min(width, win.width);
        const h = @min(height, win.height);
        const x = (win.width - w) / 2;
        const y = (win.height - h) / 3;
        const outer = win.child(.{ .x_off = x, .y_off = y, .width = w, .height = h });
        outer.clear();
        return app.panel(outer, 0, w, h, label, true, app.theme.bg_side);
    }

    fn drawHelp(app: *App, win: vaxis.Window) void {
        const t = app.theme;
        const inner = app.box(win, 58, keys.help.len + 4, " keys ");
        for (keys.help, 0..) |row, i| {
            const line = inner.child(.{ .y_off = @intCast(i + 1), .height = 1 });
            _ = line.print(&.{.{ .text = row[0], .style = .{ .fg = t.c(t.accent), .bg = t.c(t.bg_side), .bold = true } }}, .{ .wrap = .none });
            _ = line.child(.{ .x_off = 16 }).print(&.{.{ .text = row[1], .style = app.st(t.fg, t.bg_side) }}, .{ .wrap = .none });
        }
    }

    fn drawPrompt(app: *App, win: vaxis.Window, fa: Allocator) !void {
        const t = app.theme;
        const inner = app.box(win, 64, 5, try std.fmt.allocPrint(fa, " {s} ", .{app.prompt_label}));
        const line = inner.child(.{ .y_off = 1, .height = 1 });
        const bs = app.st(t.fg, t.bg_code);
        line.fill(.{ .style = bs });
        // Show the end of a long input.
        var text: []const u8 = app.input.items;
        while (text.len > 0 and line.gwidth(text) + 3 > line.width) {
            var cut: usize = 1;
            while (cut < text.len and text[cut] & 0xC0 == 0x80) cut += 1;
            text = text[cut..];
        }
        _ = line.print(&.{
            .{ .text = " ", .style = bs },
            .{ .text = text, .style = bs },
            .{ .text = "▏", .style = app.st(t.accent, t.bg_code) },
        }, .{ .wrap = .none });
    }

    fn drawPicker(app: *App, win: vaxis.Window, fa: Allocator) !void {
        const t = app.theme;
        const n = app.selected() orelse return;
        const rows: u16 = @intCast(@min(app.picker.len, 18));
        const inner = app.box(win, 50, rows + 2, try std.fmt.allocPrint(fa, " Move \u{201c}{s}\u{201d} to ", .{title(n.title)}));
        const top = if (app.picker_sel >= rows) app.picker_sel + 1 - rows else 0;
        var i = top;
        while (i < app.picker.len and i < top + rows) : (i += 1) {
            const target = app.picker[i];
            const line = inner.child(.{ .y_off = @intCast(i - top), .height = 1 });
            var base = app.st(t.fg, t.bg_side);
            if (i == app.picker_sel) {
                base = app.selStyle(base);
                line.fill(.{ .style = base });
            }
            var mark = base;
            mark.fg = t.c(t.accent);
            _ = line.child(.{ .x_off = 1 + @as(u16, target.depth) * 2 }).print(&.{
                .{ .text = if (target.id == null) glyph.unfiled ++ "  " else glyph.folder ++ "  ", .style = mark },
                .{ .text = target.label, .style = base },
                .{ .text = if (sameFolder(target.id, n.folder)) "  " ++ glyph.check else "", .style = mark },
            }, .{ .wrap = .none });
        }
    }

    fn syncLabel(app: *App) struct { dot: []const u8, text: []const u8, color: [3]u8 } {
        const t = app.theme;
        const state: SyncState = @enumFromInt(app.shared.sync.load(.acquire));
        const pending = app.shared.pending.load(.acquire);
        if (state == .lost) return .{ .dot = "✕", .text = "No daemon, reconnecting", .color = t.warn };
        if (app.shared.hub.load(.acquire) == 2) return .{ .dot = "○", .text = "Local only (no hub)", .color = t.muted };
        return switch (state) {
            .online => if (pending == 0)
                .{ .dot = "●", .text = "Synced", .color = t.ok }
            else
                .{ .dot = "◐", .text = "Syncing", .color = t.accent },
            .connecting => .{ .dot = "◐", .text = "Connecting", .color = t.accent },
            .offline => .{ .dot = "○", .text = if (pending > 0) "Offline, changes wait" else "Offline", .color = t.muted },
            .conflict => .{ .dot = "!", .text = "Sync conflict (your edits are kept)", .color = t.warn },
            .unknown, .lost => .{ .dot = "○", .text = "…", .color = t.muted },
        };
    }

    /// Text styled without a background would show the terminal's own
    /// background colour, which need not match the theme: give those cells
    /// the panel's colour.
    fn fillDefaultBg(app: *App, win: vaxis.Window, bg: [3]u8) void {
        if (app.theme.mono) return;
        var row: u16 = 0;
        while (row < win.height) : (row += 1) {
            var col: u16 = 0;
            while (col < win.width) : (col += 1) {
                var cell = win.readCell(col, row) orelse continue;
                if (cell.style.bg != .default) continue;
                cell.style.bg = .{ .rgb = bg };
                win.writeCell(col, row, cell);
            }
        }
    }

    pub fn draw(app: *App, fa: Allocator) !void {
        const t = app.theme;
        const win = app.vx.window();
        win.clear();
        win.fill(.{ .style = .{ .bg = t.c(t.bg) } });
        if (win.height < 3 or win.width < 20) return;
        const body_h = win.height - 1;
        const body = win.child(.{ .height = body_h });

        // Wide: three columns. Medium: notes + preview (the sources column
        // replaces the notes while it has focus). Narrow: one column.
        const w = win.width;
        const wide = w >= 110;
        const medium = !wide and w >= 70;
        var x: u16 = 0;
        if (wide or app.focus == .sources) {
            const sw: u16 = if (wide) 30 else if (medium) 34 else w;
            const inner = app.panel(body, x, sw, body_h, " omajot ", app.focus == .sources, t.bg_side);
            try app.drawSources(inner, fa);
            app.fillDefaultBg(inner, t.bg_side);
            x += sw;
        }
        if (wide or (medium and app.focus != .sources) or (!wide and !medium and app.focus == .notes)) {
            const lw: u16 = if (wide) 44 else if (medium) 40 else w;
            const src = app.currentSource();
            const label = try std.fmt.allocPrint(fa, " {s}{s} · {d} ", .{ if (src.kind == .tag) "#" else "", src.label, app.visible.len });
            const inner = app.panel(body, x, lw, body_h, label, app.focus == .notes, t.bg);
            try app.drawNotes(inner, fa);
            app.fillDefaultBg(inner, t.bg);
            x += lw;
        }
        if (x < w and (wide or medium or app.focus == .preview)) {
            const inner = app.panel(body, x, w - x, body_h, " preview ", app.focus == .preview, t.bg);
            try app.drawPreview(inner, fa);
            app.fillDefaultBg(inner, t.bg);
        }

        switch (app.mode) {
            .help => app.drawHelp(body),
            .prompt => try app.drawPrompt(body, fa),
            .picker => try app.drawPicker(body, fa),
            .browse, .search => {},
        }

        // Status bar: the sync state, a message, the key hints where they fit.
        const bar = win.child(.{ .y_off = body_h, .height = 1 });
        const bs = app.st(t.muted, t.bg_side);
        bar.fill(.{ .style = bs });
        const sync = app.syncLabel();
        const pending = app.shared.pending.load(.acquire);
        const count = if (pending > 0 and app.shared.hub.load(.acquire) != 2) try std.fmt.allocPrint(fa, " · {d} to send", .{pending}) else "";
        const tone_color = switch (app.tone) {
            .info => t.fg,
            .ok => t.ok,
            .warn => t.warn,
        };
        const left = bar.print(&.{
            .{ .text = " ", .style = bs },
            .{ .text = sync.dot, .style = app.st(sync.color, t.bg_side) },
            .{ .text = " ", .style = bs },
            .{ .text = sync.text, .style = bs },
            .{ .text = count, .style = bs },
            .{ .text = "   ", .style = bs },
            .{ .text = app.message, .style = app.st(tone_color, t.bg_side) },
        }, .{ .wrap = .none });
        const hints = switch (app.mode) {
            .browse => "? help · / search · n new · e edit · p pin · x trash · m move · q quit",
            .search => "type to search · Enter keep · Esc clear",
            .prompt => "Enter ok · Esc cancel",
            .picker => "j/k choose · Enter move · Esc cancel",
            .help => "any key closes",
        };
        const hw: u16 = bar.gwidth(hints) + 1;
        if (left.row == 0 and !left.overflow and left.col + 2 + hw <= bar.width)
            _ = bar.child(.{ .x_off = bar.width - hw, .width = hw }).print(&.{.{ .text = hints, .style = app.st(t.border, t.bg_side) }}, .{ .wrap = .none });
    }
};

fn title(t: []const u8) []const u8 {
    return if (t.len == 0) "(untitled)" else t;
}

fn sameFolder(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// ---------------------------------------------------------------- events

/// The event connection: `hello` with events, `status` once, then every
/// broadcast event. Reconnects when the daemon goes away (a plugin daemon
/// took over, or it stopped); for the first seconds without starting a new
/// one, so a daemon that is taking over is not raced.
pub fn eventThread(app: *App) void {
    var lost_at: ?i64 = null;
    var line_arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer line_arena.deinit();
    while (true) {
        const now = Io.Clock.awake.now(app.io).toMilliseconds();
        var opts = app.opts;
        if (lost_at) |t0| if (now - t0 < 10_000) {
            opts.no_start = true;
        };
        var why: std.ArrayList(u8) = .empty;
        const c = client.open(app.gpa, app.io, app.where, opts, &why) catch {
            why.deinit(app.gpa);
            app.io.sleep(.fromMilliseconds(500), .awake) catch {};
            continue;
        };
        why.deinit(app.gpa);
        defer c.deinit();
        lost_at = null;
        _ = line_arena.reset(.retain_capacity);
        const a = line_arena.allocator();
        _ = c.call(a, "hello", .{ .client = "tui", .events = true }) catch {
            lost_at = now;
            continue;
        };
        if (c.call(a, "status", .{})) |s| {
            if (s.get("hub")) |h| app.shared.hub.store(if (h == .string and h.string.len > 0) 1 else 2, .release);
            if (s.get("sync")) |v| if (v == .string) app.shared.sync.store(@intFromEnum(parseState(v.string)), .release);
            if (s.get("pending")) |v| if (v == .integer) app.shared.pending.store(@intCast(@max(v.integer, 0)), .release);
        } else |_| {}
        app.shared.notes_dirty.store(true, .release);
        wake(app);

        while (true) {
            _ = line_arena.reset(.retain_capacity);
            const got = (daemon.readLine(&c.sr.interface, &c.line, 64 << 20) catch null) orelse break;
            if (!std.mem.startsWith(u8, got, "{\"ev\":")) continue;
            const v = json.parseFromSliceLeaky(json.Value, line_arena.allocator(), got, .{}) catch continue;
            if (v != .object) continue;
            const ev = v.object.get("ev") orelse continue;
            if (ev != .string) continue;
            const name = ev.string;
            if (std.mem.eql(u8, name, "notes") or std.mem.eql(u8, name, "folders")) {
                app.shared.notes_dirty.store(true, .release);
            } else if (std.mem.eql(u8, name, "sync")) {
                if (v.object.get("state")) |s| if (s == .string) app.shared.sync.store(@intFromEnum(parseState(s.string)), .release);
                if (v.object.get("pending")) |p| if (p == .integer) app.shared.pending.store(@intCast(@max(p.integer, 0)), .release);
            } else if (std.mem.eql(u8, name, "attachment")) {
                app.shared.attachment.store(true, .release);
            } else continue;
            wake(app);
        }
        lost_at = Io.Clock.awake.now(app.io).toMilliseconds();
        app.shared.sync.store(@intFromEnum(SyncState.lost), .release);
        wake(app);
        app.io.sleep(.fromMilliseconds(500), .awake) catch {};
    }
}

fn wake(app: *App) void {
    // A full queue already wakes the UI; a stopped loop (editor) is refreshed after.
    _ = app.loop.tryPostEvent(.daemon) catch {};
}

fn parseState(s: []const u8) SyncState {
    return std.meta.stringToEnum(SyncState, s) orelse .unknown;
}

test {
    _ = model;
    _ = md;
    _ = keys;
    _ = @import("theme.zig");
}
