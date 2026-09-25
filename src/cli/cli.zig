//! The omajot commands (`omajot ls`, `cat`, `write`, `edit`, …): read and
//! change notes from a terminal or a script. Every command talks to the
//! daemon of the data directory over its socket (client.zig) and starts a
//! background daemon when none runs. docs/PROTOCOL.md §5 and SKILL.md
//! describe the commands, their JSON output and exit codes.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const core = @import("core");
const address = core.address;
const paths = @import("../daemon/paths.zig");
const attachments = @import("../daemon/attachments.zig");
const client = @import("client.zig");
const editor = @import("editor.zig");
const timefmt = @import("timefmt.zig");
const help = @import("help.zig");

pub const exit = struct {
    pub const ok: u8 = 0;
    pub const not_found: u8 = 1;
    pub const ambiguous: u8 = 2;
    pub const conflict: u8 = 3;
    pub const usage: u8 = 64;
    pub const unavailable: u8 = 69;
    pub const software: u8 = 70;
};

/// Largest note text a command sends (the daemon reads 16 MiB lines).
const max_text_bytes: usize = 15 << 20;

pub fn isVerb(name: []const u8) bool {
    for (help.verbs) |v| if (std.mem.eql(u8, v.name, name)) return true;
    return false;
}

// ---------------------------------------------------------------- arguments

const Args = struct {
    pos: std.ArrayList([]const u8) = .empty,
    flags: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    fn has(a: *const Args, name: []const u8) bool {
        return a.flags.contains(name);
    }
    fn get(a: *const Args, name: []const u8) ?[]const u8 {
        return a.flags.get(name);
    }
};

const global_values = [_][]const u8{ "--data", "--socket", "--hub" };
const global_bools = [_][]const u8{ "--no-hub", "--no-start", "--json", "--help" };

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn parseArgs(arena: Allocator, verb: help.Verb, argv: []const []const u8, err_msg: *[]const u8) !Args {
    var a: Args = .{};
    var i: usize = 0;
    var only_pos = false;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        // Options: "--name", "-h" and the verb's short forms. Anything else,
        // "-" and "- milk" included, is an argument.
        const is_short = std.mem.eql(u8, arg, "-h") or for (verb.short) |s| {
            if (std.mem.eql(u8, arg, s[0])) break true;
        } else false;
        if (only_pos or !(std.mem.startsWith(u8, arg, "--") or is_short)) {
            try a.pos.append(arena, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            only_pos = true;
            continue;
        }
        var name = arg;
        var value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) if (std.mem.findScalar(u8, arg, '=')) |eq| {
            name = arg[0..eq];
            value = arg[eq + 1 ..];
        };
        // Short forms.
        for (verb.short) |s| if (std.mem.eql(u8, name, s[0])) {
            name = s[1];
        };
        if (std.mem.eql(u8, name, "-h")) name = "--help";
        if (contains(&global_bools, name) or contains(verb.bools, name)) {
            if (value != null) {
                err_msg.* = try std.fmt.allocPrint(arena, "{s} takes no value", .{name});
                return error.Usage;
            }
            try a.flags.put(arena, name, "");
        } else if (contains(&global_values, name) or contains(verb.values, name)) {
            const v = value orelse blk: {
                i += 1;
                if (i >= argv.len) {
                    err_msg.* = try std.fmt.allocPrint(arena, "{s} needs a value", .{name});
                    return error.Usage;
                }
                break :blk argv[i];
            };
            try a.flags.put(arena, name, v);
        } else {
            err_msg.* = try std.fmt.allocPrint(arena, "unknown option {s}", .{arg});
            return error.Usage;
        }
    }
    return a;
}

// ---------------------------------------------------------------- context

const NoteSum = struct {
    id: []const u8,
    title: []const u8,
    snippet: []const u8 = "",
    folder: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    pinned: bool = false,
    trashed: bool = false,
    created: i64 = 0,
    updated: i64 = 0,
};

const Listing = struct {
    notes: []NoteSum,
    folders: []address.FolderRef,
    ix: address.Index,
};

const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    verb: help.Verb,
    args: Args,
    out: *Io.Writer,
    json: bool,
    code: u8 = exit.ok,
    opts: client.Options,
    where: ?paths.Resolved = null,
    conn: ?*client.Client = null,
    zone: timefmt.Zone = .{},
    cached: ?Listing = null,

    // ------------------------------------------------------------ output

    fn emitJson(ctx: *Ctx, value: anytype) !void {
        try json.Stringify.value(value, .{}, ctx.out);
        try ctx.out.writeByte('\n');
    }

    /// Report a failure (stderr, or a JSON object on stdout) and stop with `code`.
    fn fail(ctx: *Ctx, code: u8, comptime fmt: []const u8, args: anytype) error{Exit} {
        const msg = std.fmt.allocPrint(ctx.arena, fmt, args) catch "out of memory";
        ctx.code = code;
        if (ctx.json) {
            ctx.emitJson(.{ .ok = false, .exit = code, .@"error" = msg }) catch {};
        } else {
            std.debug.print("omajot {s}: {s}\n", .{ ctx.verb.name, msg });
        }
        return error.Exit;
    }

    fn pos(ctx: *Ctx, i: usize, what: []const u8) ![]const u8 {
        if (i < ctx.args.pos.items.len) return ctx.args.pos.items[i];
        return ctx.fail(exit.usage, "missing {s} (see omajot {s} --help)", .{ what, ctx.verb.name });
    }

    fn maxPos(ctx: *Ctx, n: usize) !void {
        if (ctx.args.pos.items.len > n) return ctx.fail(exit.usage, "too many arguments (see omajot {s} --help)", .{ctx.verb.name});
    }

    // ------------------------------------------------------------ daemon

    fn resolved(ctx: *Ctx) !paths.Resolved {
        if (ctx.where) |w| return w;
        ctx.where = paths.resolve(ctx.arena, ctx.io, ctx.env, .{ .data = ctx.opts.data, .socket = ctx.opts.socket }) catch |err|
            return ctx.fail(exit.software, "cannot read the config or make the data directory: {s}", .{@errorName(err)});
        return ctx.where.?;
    }

    fn daemon(ctx: *Ctx) !*client.Client {
        if (ctx.conn) |c| return c;
        const where = try ctx.resolved();
        var why: std.ArrayList(u8) = .empty;
        ctx.conn = client.open(ctx.gpa, ctx.io, where, ctx.opts, &why) catch |err| switch (err) {
            error.DaemonUnavailable => {
                if (why.items.len > 0) std.debug.print("omajot {s}: {s}", .{ ctx.verb.name, why.items });
                if (ctx.opts.no_start) return ctx.fail(exit.unavailable, "no daemon on {s} (--no-start)", .{where.socket});
                return ctx.fail(exit.unavailable, "cannot reach or start the daemon on {s}", .{where.socket});
            },
            else => return ctx.fail(exit.unavailable, "cannot talk to the daemon on {s}: {s}", .{ where.socket, @errorName(err) }),
        };
        return ctx.conn.?;
    }

    /// One request; a refusal ends the command with a matching exit code.
    fn call(ctx: *Ctx, cmd: []const u8, fields: anytype) !json.ObjectMap {
        const c = try ctx.daemon();
        return c.call(ctx.arena, cmd, fields) catch |err| switch (err) {
            error.Refused => {
                const msg = c.last_error;
                const code: u8 = if (std.mem.eql(u8, msg, "unknown note") or std.mem.eql(u8, msg, "unknown folder") or
                    std.mem.startsWith(u8, msg, "the note did not exist")) exit.not_found else if (std.mem.startsWith(u8, msg, "note is open")) exit.conflict else exit.software;
                return ctx.fail(code, "{s}", .{msg});
            },
            error.ConnectionLost => return ctx.fail(exit.unavailable, "lost the connection to the daemon", .{}),
        };
    }

    fn listing(ctx: *Ctx) !*Listing {
        if (ctx.cached == null) {
            const reply = try ctx.call("list", .{});
            const parsed = json.parseFromValueLeaky(struct { notes: []NoteSum, folders: []address.FolderRef }, ctx.arena, .{ .object = reply }, .{ .ignore_unknown_fields = true }) catch
                return ctx.fail(exit.software, "the daemon sent a list this version cannot read", .{});
            const refs = try ctx.arena.alloc(address.NoteRef, parsed.notes.len);
            for (parsed.notes, refs) |n, *r| r.* = .{ .id = n.id, .title = n.title, .folder = n.folder, .trashed = n.trashed };
            ctx.cached = .{ .notes = parsed.notes, .folders = parsed.folders, .ix = .{ .notes = refs, .folders = parsed.folders } };
        }
        return &ctx.cached.?;
    }

    fn invalidate(ctx: *Ctx) void {
        ctx.cached = null;
    }

    fn path(ctx: *Ctx, i: usize) ![]const u8 {
        const l = try ctx.listing();
        return l.ix.notePath(ctx.arena, i);
    }

    /// The note `query` names; not found → exit 1, ambiguous → exit 2 with the candidates.
    fn note(ctx: *Ctx, query: []const u8) !usize {
        const l = try ctx.listing();
        switch (try l.ix.resolveNote(ctx.arena, query)) {
            .found => |i| return i,
            .not_found => return ctx.fail(exit.not_found, "no note \"{s}\" (try: omajot ls -r, or omajot search)", .{query}),
            .ambiguous => |set| return ctx.ambiguous(query, set, false),
        }
    }

    fn ambiguous(ctx: *Ctx, query: []const u8, set: []const usize, folders: bool) error{ Exit, OutOfMemory } {
        const l = ctx.cached.?;
        ctx.code = exit.ambiguous;
        const Cand = struct { id: []const u8, path: []const u8, trashed: bool = false };
        const cands = try ctx.arena.alloc(Cand, set.len);
        for (set, cands) |i, *c| {
            if (folders) {
                c.* = .{ .id = l.folders[i].id, .path = try l.ix.folderPath(ctx.arena, l.folders[i].id) };
            } else {
                c.* = .{ .id = l.notes[i].id, .path = try l.ix.notePath(ctx.arena, i), .trashed = l.notes[i].trashed };
            }
        }
        if (ctx.json) {
            ctx.emitJson(.{ .ok = false, .exit = exit.ambiguous, .@"error" = "ambiguous", .candidates = cands }) catch {};
        } else {
            std.debug.print("omajot {s}: \"{s}\" matches {d} {s}. Use a longer path or an id:\n", .{ ctx.verb.name, query, set.len, if (folders) "folders" else "notes" });
            for (cands) |c| std.debug.print("  {s}  {s}{s}\n", .{ c.id, c.path, if (c.trashed) "  (in the Trash)" else "" });
        }
        return error.Exit;
    }

    /// A folder path or id → folder id; "" or "/" → null (top level).
    fn folder(ctx: *Ctx, query: []const u8) !?[]const u8 {
        const l = try ctx.listing();
        switch (try l.ix.resolveFolder(ctx.arena, query)) {
            .found => |i| return l.folders[i].id,
            .top => return null,
            .not_found => return ctx.fail(exit.not_found, "no folder \"{s}\" (make it with: omajot mkdir \"{s}\")", .{ query, query }),
            .ambiguous => |set| return ctx.ambiguous(query, set, true),
        }
    }

    /// A folder path → folder id, making missing folders. "" → null.
    fn ensureFolder(ctx: *Ctx, folder_path: []const u8) !?[]const u8 {
        const l = try ctx.listing();
        switch (try l.ix.resolveFolder(ctx.arena, folder_path)) {
            .found => |i| return l.folders[i].id,
            .top => return null,
            .ambiguous => |set| return ctx.ambiguous(folder_path, set, true),
            .not_found => {},
        }
        var parent: ?[]const u8 = null;
        var it = std.mem.tokenizeScalar(u8, folder_path, '/');
        while (it.next()) |part| {
            const lst = try ctx.listing();
            var found: ?[]const u8 = null;
            var count: usize = 0;
            for (lst.folders) |f| {
                const same_parent = if (parent) |p| (f.parent != null and std.mem.eql(u8, f.parent.?, p)) else f.parent == null;
                if (same_parent and std.mem.eql(u8, f.name, part)) {
                    found = f.id;
                    count += 1;
                }
            }
            if (count > 1) return ctx.fail(exit.ambiguous, "two folders are named \"{s}\" there; use a folder id", .{part});
            if (found) |id| {
                parent = id;
                continue;
            }
            const reply = try ctx.call("folder.create", .{ .name = part, .parent = parent });
            parent = try ctx.arena.dupe(u8, reply.get("folder").?.string);
            ctx.invalidate();
        }
        return parent;
    }

    fn readText(ctx: *Ctx, id: []const u8) ![]const u8 {
        const reply = try ctx.call("read", .{ .note = id });
        return reply.get("text").?.string;
    }

    fn stdinAll(ctx: *Ctx) ![]const u8 {
        var buf: [64 * 1024]u8 = undefined;
        var r = Io.File.stdin().reader(ctx.io, &buf);
        return r.interface.allocRemaining(ctx.arena, .limited(max_text_bytes)) catch |err| switch (err) {
            error.StreamTooLong => ctx.fail(exit.usage, "the text is longer than 15 MiB", .{}),
            else => ctx.fail(exit.software, "cannot read stdin: {s}", .{@errorName(err)}),
        };
    }

    fn now(ctx: *Ctx) i64 {
        return Io.Clock.real.now(ctx.io).toMilliseconds();
    }

    fn parseWhen(ctx: *Ctx, s: []const u8) !i64 {
        return timefmt.parse(s, ctx.now(), &ctx.zone) catch
            ctx.fail(exit.usage, "cannot read the time \"{s}\" (use 2026-09-26 14:03, 2026-09-26T12:03Z, 15m, 2h, 3d)", .{s});
    }

    fn noteOut(ctx: *Ctx, i: usize) !NoteOut {
        const l = try ctx.listing();
        const n = l.notes[i];
        return .{
            .id = n.id,
            .title = n.title,
            .path = try l.ix.notePath(ctx.arena, i),
            .folder = n.folder,
            .tags = n.tags,
            .pinned = n.pinned,
            .trashed = n.trashed,
            .created = n.created,
            .updated = n.updated,
            .snippet = n.snippet,
        };
    }
};

const NoteOut = struct {
    id: []const u8,
    title: []const u8,
    path: []const u8,
    folder: ?[]const u8,
    tags: []const []const u8,
    pinned: bool,
    trashed: bool,
    created: i64,
    updated: i64,
    snippet: []const u8,
};

fn displayTitle(t: []const u8) []const u8 {
    return if (t.len == 0) "(untitled)" else t;
}

// ---------------------------------------------------------------- entry

pub fn main(init: std.process.Init, verb_name: []const u8, argv: []const []const u8) !void {
    const gpa = init.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const verb = help.find(verb_name) orelse {
        std.debug.print("{s}", .{help.overview});
        std.process.exit(exit.usage);
    };

    var err_msg: []const u8 = "";
    const args = parseArgs(arena, verb, argv, &err_msg) catch |err| switch (err) {
        error.Usage => {
            std.debug.print("omajot {s}: {s}\n\n{s}", .{ verb.name, err_msg, verb.help });
            std.process.exit(exit.usage);
        },
        else => return err,
    };
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &out_buf);
    if (args.has("--help")) {
        try stdout.interface.writeAll(verb.help);
        try stdout.interface.flush();
        return;
    }

    var ctx: Ctx = .{
        .gpa = gpa,
        .arena = arena,
        .io = init.io,
        .env = init.environ_map,
        .verb = verb,
        .args = args,
        .out = &stdout.interface,
        .json = args.has("--json"),
        .opts = .{
            .data = args.get("--data"),
            .socket = args.get("--socket"),
            .hub = args.get("--hub"),
            .no_hub = args.has("--no-hub"),
            .no_start = args.has("--no-start"),
        },
        .zone = timefmt.Zone.load(gpa, init.io, init.environ_map),
    };
    defer ctx.zone.deinit();
    defer if (ctx.conn) |c| c.deinit();

    const result = run(&ctx);
    stdout.interface.flush() catch {};
    result catch |err| switch (err) {
        error.Exit => {},
        error.WriteFailed => ctx.code = exit.software,
        else => {
            _ = ctx.fail(exit.software, "{s}", .{@errorName(err)}) catch {};
            stdout.interface.flush() catch {};
        },
    };
    if (ctx.code != 0) {
        if (ctx.conn) |c| c.deinit();
        ctx.conn = null;
        std.process.exit(ctx.code);
    }
}

fn run(ctx: *Ctx) !void {
    const eql = std.mem.eql;
    const v = ctx.verb.name;
    if (eql(u8, v, "ls")) return cmdLs(ctx);
    if (eql(u8, v, "cat")) return cmdCat(ctx);
    if (eql(u8, v, "search")) return cmdSearch(ctx);
    if (eql(u8, v, "write")) return cmdWrite(ctx);
    if (eql(u8, v, "edit")) return cmdEdit(ctx);
    if (eql(u8, v, "append")) return cmdAppend(ctx);
    if (eql(u8, v, "replace")) return cmdReplace(ctx);
    if (eql(u8, v, "new")) return cmdNew(ctx);
    if (eql(u8, v, "mv")) return cmdMv(ctx);
    if (eql(u8, v, "rm")) return cmdRm(ctx);
    if (eql(u8, v, "mkdir")) return cmdMkdir(ctx);
    if (eql(u8, v, "rmdir")) return cmdRmdir(ctx);
    if (eql(u8, v, "tags")) return cmdTags(ctx);
    if (eql(u8, v, "history")) return cmdHistory(ctx);
    if (eql(u8, v, "restore")) return cmdRestore(ctx);
    if (eql(u8, v, "export")) return cmdExport(ctx);
    if (eql(u8, v, "status")) return cmdStatus(ctx);
    unreachable;
}

// ---------------------------------------------------------------- reading

fn isUnder(l: *const Listing, folder_id: ?[]const u8, root: ?[]const u8) bool {
    const r = root orelse return true;
    var cur = folder_id;
    var guard: usize = 0;
    while (cur) |id| : (guard += 1) {
        if (guard > l.folders.len) return false;
        if (std.mem.eql(u8, id, r)) return true;
        const i = l.ix.folderIndex(id) orelse return false;
        cur = l.folders[i].parent;
    }
    return false;
}

fn sameFolder(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn hasTag(n: NoteSum, tag: []const u8) bool {
    for (n.tags) |t| if (std.mem.eql(u8, t, tag)) return true;
    return false;
}

fn cmdLs(ctx: *Ctx) !void {
    try ctx.maxPos(1);
    const query = if (ctx.args.pos.items.len > 0) ctx.args.pos.items[0] else "";
    const root = try ctx.folder(query);
    const l = try ctx.listing();
    const trash = ctx.args.has("--trash");
    const tag_raw = ctx.args.get("--tag");
    const tag: ?[]u8 = if (tag_raw) |t| blk: {
        const c = try ctx.arena.dupe(u8, std.mem.trimStart(u8, t, "#"));
        core.text.foldCase(c);
        break :blk c;
    } else null;
    const recursive = ctx.args.has("--recursive") or tag != null or trash;
    const root_path = try l.ix.folderPath(ctx.arena, root);

    // Subfolders (plain listing only).
    const FolderOut = struct { id: []const u8, name: []const u8, path: []const u8 };
    var subs: std.ArrayList(FolderOut) = .empty;
    if (!recursive) for (l.folders) |f| if (sameFolder(f.parent, root)) {
        try subs.append(ctx.arena, .{ .id = f.id, .name = f.name, .path = try l.ix.folderPath(ctx.arena, f.id) });
    };

    var notes: std.ArrayList(usize) = .empty;
    for (l.notes, 0..) |n, i| {
        if (n.trashed != trash) continue;
        if (recursive) {
            if (!isUnder(l, n.folder, root)) continue;
        } else if (!sameFolder(n.folder, root)) continue;
        if (tag) |t| if (!hasTag(n, t)) continue;
        try notes.append(ctx.arena, i);
    }
    // Pinned first, then the list order (last changed first).
    std.mem.sort(usize, notes.items, l, struct {
        fn less(lst: *Listing, a: usize, b: usize) bool {
            if (lst.notes[a].pinned != lst.notes[b].pinned) return lst.notes[a].pinned;
            return a < b;
        }
    }.less);

    if (ctx.json) {
        const outs = try ctx.arena.alloc(NoteOut, notes.items.len);
        for (notes.items, outs) |i, *o| o.* = try ctx.noteOut(i);
        const F = struct { id: []const u8, path: []const u8 };
        return ctx.emitJson(.{
            .ok = true,
            .folder = if (root) |r| F{ .id = r, .path = root_path } else null,
            .folders = subs.items,
            .notes = outs,
        });
    }
    const long = ctx.args.has("--long");
    for (subs.items) |f| try ctx.out.print("{s}/\n", .{f.name});
    for (notes.items) |i| {
        const n = l.notes[i];
        const shown = if (recursive) blk: {
            const full = try l.ix.notePath(ctx.arena, i);
            break :blk if (root_path.len > 0 and std.mem.startsWith(u8, full, root_path) and full.len > root_path.len) full[root_path.len + 1 ..] else full;
        } else displayTitle(n.title);
        if (long) {
            var tb: [32]u8 = undefined;
            try ctx.out.print("{s}  {s}  {s}{s}\n", .{ timefmt.local(&tb, &ctx.zone, n.updated), n.id, if (n.pinned) "* " else "", shown });
        } else {
            try ctx.out.print("{s}\n", .{shown});
        }
    }
}

fn cmdCat(ctx: *Ctx) !void {
    try ctx.maxPos(1);
    const i = try ctx.note(try ctx.pos(0, "note"));
    const l = try ctx.listing();
    const id = l.notes[i].id;
    var at: ?i64 = null;
    const t = if (ctx.args.get("--at")) |when| blk: {
        at = try ctx.parseWhen(when);
        const reply = try ctx.call("read", .{ .note = id, .at = at.? });
        break :blk reply.get("text").?.string;
    } else try ctx.readText(id);
    if (ctx.json) return ctx.emitJson(.{ .ok = true, .id = id, .path = try ctx.path(i), .text = t, .at = at });
    try ctx.out.writeAll(t);
}

fn cmdSearch(ctx: *Ctx) !void {
    try ctx.maxPos(1);
    const q = try ctx.pos(0, "text to find");
    if (q.len == 0) return ctx.fail(exit.usage, "the text to find is empty", .{});
    const reply = try ctx.call("search", .{ .q = q });
    const l = try ctx.listing();
    const trash = ctx.args.has("--trash");
    var hits: std.ArrayList(usize) = .empty;
    for (reply.get("ids").?.array.items) |v| {
        for (l.notes, 0..) |n, i| if (std.mem.eql(u8, n.id, v.string)) {
            if (n.trashed == trash) try hits.append(ctx.arena, i);
            break;
        };
    }
    if (ctx.json) {
        const outs = try ctx.arena.alloc(NoteOut, hits.items.len);
        for (hits.items, outs) |i, *o| o.* = try ctx.noteOut(i);
        return ctx.emitJson(.{ .ok = true, .notes = outs });
    }
    for (hits.items) |i| try ctx.out.print("{s}\n", .{try ctx.path(i)});
    if (hits.items.len == 0) ctx.code = exit.not_found;
}

// ---------------------------------------------------------------- writing

const Action = enum {
    created,
    updated,
    appended,
    moved,
    trashed,
    untrashed,

    fn text(a: Action) []const u8 {
        return switch (a) {
            .created => "created",
            .updated => "updated",
            .appended => "appended to",
            .moved => "moved",
            .trashed => "moved to the Trash:",
            .untrashed => "restored from the Trash:",
        };
    }
};

/// Report a change: "<action> <path>" or JSON.
fn done(ctx: *Ctx, action: Action, id: []const u8, path: []const u8, changed: bool) !void {
    if (ctx.json) return ctx.emitJson(.{ .ok = true, .id = id, .path = path, .changed = changed, .action = @tagName(action) });
    try ctx.out.print("{s} {s}\n", .{ if (changed) action.text() else "unchanged", path });
}

fn cmdWrite(ctx: *Ctx) !void {
    try ctx.maxPos(1);
    const query = try ctx.pos(0, "note");
    const body = try ctx.stdinAll();
    const l = try ctx.listing();
    switch (try l.ix.resolveNote(ctx.arena, query)) {
        .found => |i| {
            const id = l.notes[i].id;
            const reply = try ctx.call("put", .{ .note = id, .text = body });
            ctx.invalidate();
            return done(ctx, .updated, id, try pathOfId(ctx, id), reply.get("changed").?.bool);
        },
        .ambiguous => |set| return ctx.ambiguous(query, set, false),
        .not_found => {},
    }
    if (std.mem.startsWith(u8, query, "n-")) return ctx.fail(exit.not_found, "no note with the id {s}", .{query});
    // Make it: the folder from --folder or from the path; the title from the path.
    const split = address.splitLast(query);
    const folder_path = ctx.args.get("--folder") orelse split.parent;
    const folder_id = try ctx.ensureFolder(folder_path);
    const text = if (std.mem.eql(u8, core.text.title(body), split.name))
        body
    else
        try std.fmt.allocPrint(ctx.arena, "# {s}\n\n{s}", .{ split.name, body });
    const reply = try ctx.call("create", .{ .folder = folder_id, .text = text });
    const id = reply.get("note").?.string;
    ctx.invalidate();
    return done(ctx, .created, id, try pathOfId(ctx, id), true);
}

fn pathOfId(ctx: *Ctx, id: []const u8) ![]const u8 {
    const l = try ctx.listing();
    for (l.notes, 0..) |n, i| if (std.mem.eql(u8, n.id, id)) return l.ix.notePath(ctx.arena, i);
    return id;
}

/// Read the note, change its text with `f`, and put it back with the text
/// read as base, so edits made elsewhere in the meantime stay.
fn change(ctx: *Ctx, i: usize, new: []const u8, base: []const u8) !bool {
    const l = try ctx.listing();
    const reply = try ctx.call("put", .{ .note = l.notes[i].id, .base = base, .text = new });
    return reply.get("changed").?.bool;
}

fn textArg(ctx: *Ctx, i: usize, what: []const u8) ![]const u8 {
    const t = try ctx.pos(i, what);
    if (std.mem.eql(u8, t, "-")) return ctx.stdinAll();
    return t;
}

fn cmdAppend(ctx: *Ctx) !void {
    try ctx.maxPos(2);
    const i = try ctx.note(try ctx.pos(0, "note"));
    const add = try textArg(ctx, 1, "text (or - for stdin)");
    const l = try ctx.listing();
    const id = l.notes[i].id;
    const path = try ctx.path(i);
    const cur = try ctx.readText(id);
    const sep: []const u8 = if (cur.len > 0 and cur[cur.len - 1] != '\n') "\n" else "";
    const end: []const u8 = if (add.len > 0 and add[add.len - 1] != '\n') "\n" else "";
    const new = try std.mem.concat(ctx.arena, u8, &.{ cur, sep, add, end });
    return done(ctx, .appended, id, path, try change(ctx, i, new, cur));
}

fn cmdReplace(ctx: *Ctx) !void {
    try ctx.maxPos(3);
    const i = try ctx.note(try ctx.pos(0, "note"));
    const old = try ctx.pos(1, "old text");
    const new_part = try ctx.pos(2, "new text");
    if (old.len == 0) return ctx.fail(exit.usage, "the old text is empty", .{});
    const l = try ctx.listing();
    const id = l.notes[i].id;
    const path = try ctx.path(i);
    const cur = try ctx.readText(id);
    const count = std.mem.count(u8, cur, old);
    if (count == 0) return ctx.fail(exit.not_found, "the old text is not in {s}", .{path});
    if (count > 1 and !ctx.args.has("--all"))
        return ctx.fail(exit.ambiguous, "the old text is in {s} {d} times; add more context to it, or use --all", .{ path, count });
    const new = if (count == 1) blk: {
        const at = std.mem.find(u8, cur, old).?;
        break :blk try std.mem.concat(ctx.arena, u8, &.{ cur[0..at], new_part, cur[at + old.len ..] });
    } else try std.mem.replaceOwned(u8, ctx.arena, cur, old, new_part);
    const changed = try change(ctx, i, new, cur);
    if (ctx.json) return ctx.emitJson(.{ .ok = true, .id = id, .path = path, .changed = changed, .action = "replaced", .count = count });
    try ctx.out.print("replaced {d} in {s}\n", .{ count, path });
}

fn cmdNew(ctx: *Ctx) !void {
    try ctx.maxPos(2);
    const title = try ctx.pos(0, "title");
    if (std.mem.trim(u8, title, " \t").len == 0 or std.mem.findScalar(u8, title, '\n') != null)
        return ctx.fail(exit.usage, "the title must be one non-empty line", .{});
    const body = if (ctx.args.pos.items.len > 1) try textArg(ctx, 1, "text") else "";
    const folder_id = try ctx.ensureFolder(ctx.args.get("--folder") orelse "");
    const text = if (body.len == 0)
        try std.fmt.allocPrint(ctx.arena, "# {s}\n", .{title})
    else
        try std.fmt.allocPrint(ctx.arena, "# {s}\n\n{s}{s}", .{ title, body, if (body[body.len - 1] == '\n') "" else "\n" });
    const reply = try ctx.call("create", .{ .folder = folder_id, .text = text });
    const id = reply.get("note").?.string;
    ctx.invalidate();
    return done(ctx, .created, id, try pathOfId(ctx, id), true);
}

fn cmdMv(ctx: *Ctx) !void {
    try ctx.maxPos(2);
    const i = try ctx.note(try ctx.pos(0, "note"));
    const target = try ctx.folder(try ctx.pos(1, "folder (\"/\" for the top level)"));
    const l = try ctx.listing();
    const id = l.notes[i].id;
    const changed = !sameFolder(l.notes[i].folder, target);
    if (changed) _ = try ctx.call("set", .{ .note = id, .folder = target });
    ctx.invalidate();
    return done(ctx, .moved, id, try pathOfId(ctx, id), changed);
}

fn cmdRm(ctx: *Ctx) !void {
    try ctx.maxPos(1);
    const i = try ctx.note(try ctx.pos(0, "note"));
    const l = try ctx.listing();
    const id = l.notes[i].id;
    const path = try ctx.path(i);
    const restore = ctx.args.has("--restore");
    const changed = l.notes[i].trashed != !restore;
    if (changed) _ = try ctx.call("set", .{ .note = id, .trashed = !restore });
    return done(ctx, if (restore) .untrashed else .trashed, id, path, changed);
}

fn cmdMkdir(ctx: *Ctx) !void {
    try ctx.maxPos(1);
    const p = std.mem.trim(u8, try ctx.pos(0, "folder path"), "/");
    if (p.len == 0) return ctx.fail(exit.usage, "the folder path is empty", .{});
    const l = try ctx.listing();
    const existed = switch (try l.ix.resolveFolder(ctx.arena, p)) {
        .found => true,
        else => false,
    };
    const id = (try ctx.ensureFolder(p)).?;
    const l2 = try ctx.listing();
    const path = try l2.ix.folderPath(ctx.arena, id);
    if (ctx.json) return ctx.emitJson(.{ .ok = true, .id = id, .path = path, .changed = !existed });
    try ctx.out.print("{s} {s}/\n", .{ if (existed) "exists:" else "made", path });
}

fn cmdRmdir(ctx: *Ctx) !void {
    try ctx.maxPos(1);
    const q = try ctx.pos(0, "folder");
    const id = (try ctx.folder(q)) orelse return ctx.fail(exit.usage, "the top level is not a folder", .{});
    const l = try ctx.listing();
    const path = try l.ix.folderPath(ctx.arena, id);
    var notes: usize = 0;
    var subs: usize = 0;
    for (l.notes) |n| if (!n.trashed and isUnder(l, n.folder, id)) {
        notes += 1;
    };
    for (l.folders) |f| if (!std.mem.eql(u8, f.id, id) and isUnder(l, f.id, id)) {
        subs += 1;
    };
    if ((notes > 0 or subs > 0) and !ctx.args.has("--force"))
        return ctx.fail(exit.conflict, "{s} has {d} note(s) and {d} folder(s). Use --force to delete it: its notes then move to the top level, its folders to the parent folder", .{ path, notes, subs });
    _ = try ctx.call("folder.delete", .{ .folder = id });
    if (ctx.json) return ctx.emitJson(.{ .ok = true, .id = id, .path = path, .changed = true });
    try ctx.out.print("deleted {s}/\n", .{path});
}

fn cmdTags(ctx: *Ctx) !void {
    try ctx.maxPos(0);
    const l = try ctx.listing();
    var counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (l.notes) |n| if (!n.trashed) for (n.tags) |t| {
        const e = try counts.getOrPut(ctx.arena, t);
        e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
    };
    const Tag = struct { tag: []const u8, count: usize };
    const list = try ctx.arena.alloc(Tag, counts.count());
    for (counts.keys(), counts.values(), list) |k, v, *t| t.* = .{ .tag = k, .count = v };
    std.mem.sort(Tag, list, {}, struct {
        fn less(_: void, a: Tag, b: Tag) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.order(u8, a.tag, b.tag) == .lt;
        }
    }.less);
    if (ctx.json) return ctx.emitJson(.{ .ok = true, .tags = list });
    for (list) |t| try ctx.out.print("{d:>5}  #{s}\n", .{ t.count, t.tag });
}

// ---------------------------------------------------------------- edit

const Watch = struct {
    ctx: *Ctx,
    c: *client.Client,
    note: []const u8,
    file: []const u8,
    /// What the editor last saved (and was applied), owned by gpa.
    last: []u8,
    mtime: i96 = 0,
    size: u64 = 0,
    saves: usize = 0,
    failed: ?[]u8 = null,
    stop: std.atomic.Value(bool) = .init(false),

    fn check(w: *Watch) !void {
        const io = w.ctx.io;
        const st = Io.Dir.cwd().statFile(io, w.file, .{}) catch return; // mid-save rename
        if (st.mtime.nanoseconds == w.mtime and st.size == w.size) return;
        // Let the editor finish writing: read only a file that stays the same for 100 ms.
        io.sleep(.fromMilliseconds(100), .awake) catch {};
        const again = Io.Dir.cwd().statFile(io, w.file, .{}) catch return;
        if (again.mtime.nanoseconds != st.mtime.nanoseconds or again.size != st.size) return;
        const now_text = Io.Dir.cwd().readFileAlloc(io, w.file, w.ctx.gpa, .limited(max_text_bytes)) catch return;
        w.mtime = st.mtime.nanoseconds;
        w.size = st.size;
        if (std.mem.eql(u8, now_text, w.last)) {
            w.ctx.gpa.free(now_text);
            return;
        }
        var arena_state: std.heap.ArenaAllocator = .init(w.ctx.gpa);
        defer arena_state.deinit();
        _ = w.c.call(arena_state.allocator(), "put", .{ .note = w.note, .base = w.last, .text = now_text }) catch |err| {
            w.ctx.gpa.free(now_text);
            if (w.failed == null) w.failed = w.ctx.gpa.dupe(u8, if (err == error.Refused) w.c.last_error else @errorName(err)) catch null;
            return err;
        };
        w.ctx.gpa.free(w.last);
        w.last = now_text;
        w.saves += 1;
    }

    fn loop(w: *Watch) void {
        while (!w.stop.load(.acquire)) {
            w.ctx.io.sleep(.fromMilliseconds(250), .awake) catch {};
            w.check() catch {};
        }
    }
};

fn safeName(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |b| {
        const bad = b < 0x20 or b == 0x7f or std.mem.findScalar(u8, "/\\:*?\"<>|", b) != null;
        if (bad) {
            if (out.items.len == 0 or out.items[out.items.len - 1] != '-') try out.append(arena, '-');
        } else try out.append(arena, b);
    }
    var name: []const u8 = std.mem.trim(u8, out.items, " .-");
    // At most 100 bytes, cut at a UTF-8 boundary.
    if (name.len > 100) {
        var cut: usize = 100;
        while (cut > 0 and (name[cut] & 0xC0) == 0x80) cut -= 1;
        name = std.mem.trimEnd(u8, name[0..cut], " .");
    }
    if (name.len == 0) return "Untitled";
    // Names Windows reserves.
    const reserved = [_][]const u8{ "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9" };
    const stem = name[0 .. std.mem.findScalar(u8, name, '.') orelse name.len];
    for (reserved) |r| if (std.ascii.eqlIgnoreCase(stem, r)) return std.fmt.allocPrint(arena, "{s}_", .{name});
    return name;
}

/// Owner-only permissions (Windows: the default).
fn private(comptime mode: u32) Io.File.Permissions {
    if (@import("builtin").os.tag == .windows) return .default_file;
    return .fromMode(mode);
}

fn cmdEdit(ctx: *Ctx) !void {
    try ctx.maxPos(1);
    const i = try ctx.note(try ctx.pos(0, "note"));
    const l = try ctx.listing();
    const id = try ctx.gpa.dupe(u8, l.notes[i].id);
    defer ctx.gpa.free(id);
    const path = try ctx.path(i);
    const choice = editor.choose(ctx.io, ctx.env) catch return ctx.fail(exit.software, "{s}", .{editor.no_editor_message});
    const text = try ctx.readText(id);

    // A private directory for the file: $XDG_RUNTIME_DIR, else $TMPDIR, else /tmp.
    const base = ctx.env.get("XDG_RUNTIME_DIR") orelse ctx.env.get("TMPDIR") orelse "/tmp";
    var rnd: [4]u8 = undefined;
    ctx.io.random(&rnd);
    const dir = try std.fmt.allocPrint(ctx.arena, "{s}/omajot-edit-{x}", .{ std.mem.trimEnd(u8, base, "/"), std.mem.readInt(u32, &rnd, .little) });
    Io.Dir.cwd().createDir(ctx.io, dir, private(0o700)) catch |err| return ctx.fail(exit.software, "cannot make {s}: {s}", .{ dir, @errorName(err) });
    defer Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    const file = try std.fmt.allocPrint(ctx.arena, "{s}/{s}.md", .{ dir, try safeName(ctx.arena, l.notes[i].title) });
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = file, .data = text, .flags = .{ .permissions = private(0o600) } });

    const c = try ctx.daemon();
    var w: Watch = .{ .ctx = ctx, .c = c, .note = id, .file = file, .last = try ctx.gpa.dupe(u8, text) };
    defer ctx.gpa.free(w.last);
    defer if (w.failed) |f| ctx.gpa.free(f);
    if (Io.Dir.cwd().statFile(ctx.io, file, .{})) |st| {
        w.mtime = st.mtime.nanoseconds;
        w.size = st.size;
    } else |_| {}

    var child = editor.spawn(ctx.arena, ctx.io, choice, file) catch |err|
        return ctx.fail(exit.software, "cannot start the editor \"{s}\" (from ${s}): {s}", .{ choice.command, switch (choice.source) {
            .visual => "VISUAL",
            .editor => "EDITOR",
            .fallback => "EDITOR not set; vi",
        }, @errorName(err) });
    const watcher = try std.Thread.spawn(.{}, Watch.loop, .{&w});
    const term = child.wait(ctx.io) catch null;
    w.stop.store(true, .release);
    watcher.join();
    // The last save, if the watcher did not see it yet.
    w.mtime = 0;
    w.check() catch {};

    if (w.failed) |f| return ctx.fail(exit.software, "could not save your changes: {s}. Your text is in {s}", .{ f, file });
    const final = try ctx.readText(id);
    const merged = !std.mem.eql(u8, final, w.last);
    const editor_failed = if (term) |t| switch (t) {
        .exited => |code| code != 0,
        else => true,
    } else true;
    if (ctx.json) return ctx.emitJson(.{ .ok = true, .id = id, .path = path, .changed = w.saves > 0, .saves = w.saves, .merged = merged });
    if (w.saves == 0) {
        try ctx.out.print("unchanged {s}\n", .{path});
    } else {
        try ctx.out.print("saved {s} ({d} {s})\n", .{ path, w.saves, if (w.saves == 1) "save" else "saves" });
    }
    if (merged) try ctx.out.print("The note also changed elsewhere while you edited. omajot kept both changes.\n", .{});
    if (editor_failed) std.debug.print("omajot edit: the editor did not exit cleanly; omajot kept every save it saw\n", .{});
}

// ---------------------------------------------------------------- history

const VersionJ = struct {
    t_first: i64,
    t_last: i64,
    replica: []const u8,
    self: bool = false,
    inserted: u64 = 0,
    deleted: u64 = 0,
    created: bool = false,
    other: u64 = 0,
};

fn versionsOf(ctx: *Ctx, id: []const u8) ![]VersionJ {
    const reply = try ctx.call("history", .{ .note = id });
    const parsed = json.parseFromValueLeaky(struct { versions: []VersionJ }, ctx.arena, .{ .object = reply }, .{ .ignore_unknown_fields = true }) catch
        return ctx.fail(exit.software, "the daemon sent a history this version cannot read", .{});
    return parsed.versions;
}

fn cmdHistory(ctx: *Ctx) !void {
    try ctx.maxPos(1);
    const i = try ctx.note(try ctx.pos(0, "note"));
    const l = try ctx.listing();
    const id = l.notes[i].id;
    const path = try ctx.path(i);
    const vs = try versionsOf(ctx, id);
    if (ctx.json) {
        const Out = struct { n: usize, t_first: i64, t_last: i64, time: []const u8, replica: []const u8, self: bool, inserted: u64, deleted: u64, created: bool, other: u64 };
        const outs = try ctx.arena.alloc(Out, vs.len);
        for (vs, outs, 1..) |v, *o, n| {
            var tb: [32]u8 = undefined;
            o.* = .{ .n = n, .t_first = v.t_first, .t_last = v.t_last, .time = try ctx.arena.dupe(u8, timefmt.isoUtc(&tb, v.t_last)), .replica = v.replica, .self = v.self, .inserted = v.inserted, .deleted = v.deleted, .created = v.created, .other = v.other };
        }
        return ctx.emitJson(.{ .ok = true, .id = id, .path = path, .versions = outs });
    }
    try ctx.out.print("{s}  ({s})\n", .{ path, id });
    const now_ms = ctx.now();
    for (vs, 1..) |v, n| {
        var tb: [32]u8 = undefined;
        var ab: [32]u8 = undefined;
        const who = if (v.self) "this computer" else try std.fmt.allocPrint(ctx.arena, "replica {s}", .{v.replica[0..@min(8, v.replica.len)]});
        try ctx.out.print("{d:>4}  {s}  {s:<12}  {s:<17}  +{d} -{d}{s}{s}\n", .{
            n,                                 timefmt.local(&tb, &ctx.zone, v.t_last),
            timefmt.ago(&ab, now_ms, v.t_last), who,
            v.inserted,                        v.deleted,
            if (v.created) "  created" else "", if (v.other > 0) "  moved/pinned/trashed" else "",
        });
    }
    try ctx.out.print("Show a version:    omajot cat --at <time> \"{s}\"\nRestore a version: omajot restore \"{s}\" <number>\n", .{ path, path });
}

fn cmdRestore(ctx: *Ctx) !void {
    try ctx.maxPos(2);
    const i = try ctx.note(try ctx.pos(0, "note"));
    const when = try ctx.pos(1, "version number or time");
    const l = try ctx.listing();
    const id = l.notes[i].id;
    const path = try ctx.path(i);
    const at: i64 = if (when.len <= 6 and when.len > 0 and std.mem.trim(u8, when, "0123456789").len == 0) blk: {
        const n = std.fmt.parseInt(usize, when, 10) catch 0;
        const vs = try versionsOf(ctx, id);
        if (n == 0 or n > vs.len) return ctx.fail(exit.not_found, "{s} has versions 1 to {d} (see omajot history)", .{ path, vs.len });
        break :blk vs[n - 1].t_last;
    } else try ctx.parseWhen(when);
    const reply = try ctx.call("restore", .{ .note = id, .at = at });
    const changed = reply.get("changed").?.bool;
    if (ctx.json) return ctx.emitJson(.{ .ok = true, .id = id, .path = path, .changed = changed, .at = at });
    var tb: [32]u8 = undefined;
    try ctx.out.print("{s} {s} to {s}\n", .{ if (changed) "restored" else "unchanged (same text):", path, timefmt.local(&tb, &ctx.zone, at) });
}

// ---------------------------------------------------------------- export

/// Unique names in one directory, compared without case (macOS, Windows).
const Names = struct {
    used: std.StringHashMapUnmanaged(void) = .empty,

    fn take(n: *Names, arena: Allocator, dir: []const u8, stem: []const u8, ext: []const u8) ![]const u8 {
        var k: usize = 1;
        while (true) : (k += 1) {
            const name = if (k == 1) try std.fmt.allocPrint(arena, "{s}{s}", .{ stem, ext }) else try std.fmt.allocPrint(arena, "{s} ({d}){s}", .{ stem, k, ext });
            const key = try std.ascii.allocLowerString(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }));
            const e = try n.used.getOrPut(arena, key);
            if (!e.found_existing) return name;
        }
    }
};

/// Make `attachments/<name>` links work from a file `depth` folders down.
fn relinkAttachments(arena: Allocator, text: []const u8, depth: usize) ![]const u8 {
    if (depth == 0) return text;
    var prefix: std.ArrayList(u8) = .empty;
    for (0..depth) |_| try prefix.appendSlice(arena, "../");
    var out: std.ArrayList(u8) = .empty;
    const marker = attachments.dir_name ++ "/";
    var from: usize = 0;
    while (std.mem.findPos(u8, text, from, marker)) |at| {
        const before: u8 = if (at == 0) ' ' else text[at - 1];
        try out.appendSlice(arena, text[from..at]);
        if (std.mem.findScalar(u8, "(<\"'", before) != null) try out.appendSlice(arena, prefix.items);
        try out.appendSlice(arena, marker);
        from = at + marker.len;
    }
    try out.appendSlice(arena, text[from..]);
    return out.items;
}

fn cmdExport(ctx: *Ctx) !void {
    try ctx.maxPos(1);
    const target = try ctx.pos(0, "directory");
    const io = ctx.io;
    Io.Dir.cwd().createDirPath(io, target) catch |err| return ctx.fail(exit.software, "cannot make {s}: {s}", .{ target, @errorName(err) });
    var out_dir = try Io.Dir.cwd().openDir(io, target, .{ .iterate = true });
    defer out_dir.close(io);
    {
        var it = out_dir.iterate();
        if (try it.next(io) != null and !ctx.args.has("--force"))
            return ctx.fail(exit.conflict, "{s} is not empty. Use an empty directory, or --force to write into it", .{target});
    }
    const with_trash = ctx.args.has("--trash");
    const l = try ctx.listing();
    const where = try ctx.resolved();

    // Folder id → relative directory, unique per parent.
    var names: Names = .{};
    _ = try names.take(ctx.arena, "", "README", ".md");
    _ = try names.take(ctx.arena, "", attachments.dir_name, "");
    _ = try names.take(ctx.arena, "", "Trash", "");
    var dirs: std.StringHashMapUnmanaged([]const u8) = .empty;
    const dirOf = struct {
        fn get(c: *Ctx, lst: *Listing, nm: *Names, map: *std.StringHashMapUnmanaged([]const u8), fid: ?[]const u8) ![]const u8 {
            const id = fid orelse return "";
            if (map.get(id)) |d| return d;
            const fi = lst.ix.folderIndex(id) orelse return "";
            const parent = try get(c, lst, nm, map, lst.folders[fi].parent);
            const name = try nm.take(c.arena, parent, try safeName(c.arena, lst.folders[fi].name), "");
            const d = if (parent.len == 0) name else try std.fmt.allocPrint(c.arena, "{s}/{s}", .{ parent, name });
            try map.put(c.arena, id, d);
            return d;
        }
    }.get;

    const File = struct { id: []const u8, file: []const u8 };
    var files: std.ArrayList(File) = .empty;
    var wanted: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (l.notes) |n| {
        if (n.trashed and !with_trash) continue;
        const folder_dir = try dirOf(ctx, l, &names, &dirs, n.folder);
        const dir = if (n.trashed) (if (folder_dir.len == 0) "Trash" else try std.fmt.allocPrint(ctx.arena, "Trash/{s}", .{folder_dir})) else folder_dir;
        const name = try names.take(ctx.arena, dir, try safeName(ctx.arena, n.title), ".md");
        const rel = if (dir.len == 0) name else try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ dir, name });
        const text = try ctx.readText(n.id);
        const Scan = struct {
            a: Allocator,
            set: *std.StringArrayHashMapUnmanaged(void),
            fn found(s: @This(), name_: []const u8) void {
                s.set.put(s.a, s.a.dupe(u8, name_) catch return, {}) catch {};
            }
        };
        attachments.scan(text, Scan{ .a = ctx.arena, .set = &wanted }, Scan.found);
        const depth = if (dir.len == 0) 0 else std.mem.count(u8, dir, "/") + 1;
        if (dir.len > 0) try out_dir.createDirPath(io, dir);
        try out_dir.writeFile(io, .{ .sub_path = rel, .data = try relinkAttachments(ctx.arena, text, depth) });
        try files.append(ctx.arena, .{ .id = n.id, .file = rel });
    }

    // Attachments the notes link to.
    var copied: usize = 0;
    var missing: std.ArrayList([]const u8) = .empty;
    if (wanted.count() > 0) {
        try out_dir.createDirPath(io, attachments.dir_name);
        var data_dir = try Io.Dir.cwd().openDir(io, where.data, .{});
        defer data_dir.close(io);
        var att_out = try out_dir.openDir(io, attachments.dir_name, .{});
        defer att_out.close(io);
        for (wanted.keys()) |name| {
            const src = try std.fmt.allocPrint(ctx.arena, attachments.dir_name ++ "/{s}", .{name});
            data_dir.copyFile(src, att_out, name, io, .{}) catch {
                try missing.append(ctx.arena, name);
                continue;
            };
            copied += 1;
        }
    }

    var tb: [32]u8 = undefined;
    const readme = try std.fmt.allocPrint(ctx.arena,
        \\# omajot export
        \\
        \\This folder is a copy of the notes in the omajot data directory
        \\{s}, made with `omajot export` on {s}.
        \\
        \\It is a one-way copy. Changes that you make here do not go back into omajot.
        \\
        \\- Each note is one Markdown file: `Folder/Subfolder/Title.md`. The title
        \\  is the first line of the note.
        \\- `attachments/` holds the images and files that the notes link to. The
        \\  links are relative, so they work in Markdown viewers.
        \\{s}- {d} notes, {d} attachments{s}.
        \\
    , .{
        where.data,
        timefmt.local(&tb, &ctx.zone, ctx.now()),
        if (with_trash) "- `Trash/` holds the notes that are in the Trash.\n" else "",
        files.items.len,
        copied,
        if (missing.items.len > 0) try std.fmt.allocPrint(ctx.arena, " ({d} missing on this computer)", .{missing.items.len}) else "",
    });
    try out_dir.writeFile(io, .{ .sub_path = "README.md", .data = readme });

    if (ctx.json) return ctx.emitJson(.{ .ok = true, .dir = target, .notes = files.items.len, .attachments = copied, .missing = missing.items, .files = files.items });
    try ctx.out.print("exported {d} notes and {d} attachments to {s}\n", .{ files.items.len, copied, target });
    if (missing.items.len > 0) std.debug.print("omajot export: {d} attachments are not on this computer yet (the daemon downloads them from the hub)\n", .{missing.items.len});
}

// ---------------------------------------------------------------- status

fn cmdStatus(ctx: *Ctx) !void {
    try ctx.maxPos(0);
    const s = try ctx.call("status", .{});
    const started = ctx.conn.?.started;
    if (ctx.json) {
        var o = s;
        _ = o.orderedRemove("re");
        try o.put(ctx.arena, "started", .{ .bool = started });
        try json.Stringify.value(json.Value{ .object = o }, .{}, ctx.out);
        return ctx.out.writeByte('\n');
    }
    const str = struct {
        fn get(o: json.ObjectMap, k: []const u8) []const u8 {
            const v = o.get(k) orelse return "";
            return if (v == .string) v.string else "";
        }
        fn int(o: json.ObjectMap, k: []const u8) i64 {
            const v = o.get(k) orelse return 0;
            return if (v == .integer) v.integer else 0;
        }
    };
    const hub = str.get(s, "hub");
    try ctx.out.print(
        \\daemon   {s} ({s}{s})
        \\data     {s}
        \\socket   {s}
        \\replica  {s}
        \\hub      {s}
        \\sync     {s}, {d} batches to send, hub head {d}
        \\
    , .{
        str.get(s, "daemon"),
        str.get(s, "mode"),
        if (started) ", started by this command" else "",
        str.get(s, "data"),
        str.get(s, "socket"),
        str.get(s, "replica"),
        if (hub.len > 0) hub else "none (notes stay on this computer)",
        str.get(s, "sync"),
        str.int(s, "pending"),
        str.int(s, "head"),
    });
}

test {
    _ = editor;
    _ = timefmt;
    _ = help;
}

test "safeName and relinkAttachments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a-b- c", try safeName(a, "a/b: c"));
    try std.testing.expectEqualStrings("Untitled", try safeName(a, " ..."));
    try std.testing.expectEqualStrings("CON_", try safeName(a, "CON"));
    var names: Names = .{};
    try std.testing.expectEqualStrings("Todo.md", try names.take(a, "", "Todo", ".md"));
    try std.testing.expectEqualStrings("todo (2).md", try names.take(a, "", "todo", ".md"));
    try std.testing.expectEqualStrings("![x](../../attachments/ab.png) attachments/", try relinkAttachments(a, "![x](attachments/ab.png) attachments/", 2));
}
