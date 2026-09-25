//! `omajot daemon`: the desktop replica behind the Omarchy plugin and the
//! `omajot` commands. Speaks the client protocol (docs/PROTOCOL.md §1) as
//! JSON lines on stdin/stdout (the plugin) and on a unix socket (commands,
//! other local clients), keeps the replica on disk (§4), and syncs with the
//! hub (§2). One daemon per data directory: it holds `<data>/daemon.lock`.
//!
//! Threads: main reads stdin (or, with --background, waits for the idle
//! timeout); `acceptLoop` takes socket connections, one `clientLoop` thread
//! reads each; `syncLoop` pushes the outbox, pulls pages, moves attachments;
//! `doorbellLoop` follows the hub's SSE stream and wakes the sync loop.
//! Locks, always taken in this order: `lock` (engine, replica, sync status,
//! note owners) → `clients_lock` (the client list) → a client's `wlock`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const rawjson = @import("../hub/rawjson.zig");
pub const replica = @import("replica.zig");
pub const attachments = @import("attachments.zig");
pub const hubclient = @import("hubclient.zig");
pub const paste = @import("paste.zig");
pub const paths = @import("paths.zig");

pub const version = @import("core").engine.version;
pub const max_line_bytes: usize = 16 << 20;
pub const page_limit = 200;
/// Idle pull interval even without doorbell (safety net).
pub const idle_poll_ms = 60_000;
pub const max_backoff_ms = 30_000;
/// Coalesce keystrokes into one batch.
pub const push_debounce_ms = 200;
pub const max_socket_clients = 32;
/// A background daemon stops after this long without socket clients.
pub const default_idle_exit_s = 600;

/// Exit code when another daemon holds the data directory.
pub const exit_locked = 3;

const usage =
    \\usage: omajot daemon [--hub <url>|--no-hub] [--data <dir>] [--socket <path>]
    \\                     [--background [--idle-exit <seconds>]]
    \\
    \\  Keeps the notes of one data directory and syncs them with the hub.
    \\  Speaks omajot's client protocol as JSON lines on stdin/stdout (for the
    \\  Omarchy plugin) and on a unix socket (for the omajot commands).
    \\
    \\  --hub        hub base URL (default: "hub" in the config file; without one
    \\               the daemon keeps notes locally and does not sync)
    \\  --data       data directory (default: "data" in the config file, else
    \\               $XDG_DATA_HOME/omajot or ~/.local/share/omajot)
    \\  --socket     socket path (default: "socket" in the config file, else
    \\               $XDG_RUNTIME_DIR/omajot.sock); "" turns the socket off
    \\  --background do not read stdin; stop after --idle-exit seconds without
    \\               socket clients (default 600, 0: never). The omajot commands
    \\               start the daemon like this when none runs. A plugin daemon
    \\               that starts later takes over the data directory.
    \\
    \\  Only one daemon can use a data directory (<data>/daemon.lock). A second
    \\  one stops with exit code 3.
    \\
    \\  Config file: $XDG_CONFIG_HOME/omajot/config.json or ~/.config/omajot/config.json,
    \\  e.g. {"hub": "https://host.tailnet.ts.net:8443", "data": "~/.local/share/omajot"}
    \\
;

pub const Config = paths.Config;
pub const configPath = paths.configPath;
pub const readConfig = paths.readConfig;

const SyncState = enum { connecting, online, offline };
const Reported = struct { state: SyncState, pending: usize, head: u64 };
const Mode = enum { plugin, background };

/// One connected client: the plugin on stdin/stdout, or a socket connection.
const Client = struct {
    d: *Daemon,
    kind: enum { stdio, socket },
    /// Receives broadcast events (notes, folders, sync, attachment, error).
    /// Patches go to the client that opened the note, subscribed or not.
    events: std.atomic.Value(bool),
    wlock: Io.Mutex = .init,
    writer: *Io.Writer,
    broken: bool = false,
    stream: ?Io.net.Stream = null,
    sw: Io.net.Stream.Writer = undefined,
    wbuf: [64 * 1024]u8 = undefined,

    fn send(c: *Client, bytes: []const u8) void {
        if (bytes.len == 0) return;
        c.wlock.lockUncancelable(c.d.io);
        defer c.wlock.unlock(c.d.io);
        if (c.broken) return;
        c.writer.writeAll(bytes) catch {
            c.broken = true;
            return;
        };
        c.writer.flush() catch {
            c.broken = true;
        };
    }
};

const Daemon = struct {
    gpa: Allocator,
    io: Io,
    lock: Io.Mutex = .init,
    engine: core.Engine = undefined,
    engine_ready: bool = false,
    rep: replica.Replica = undefined,
    data_path: []const u8,
    data_dir: Io.Dir,
    att_dir: Io.Dir,
    socket_path: []const u8 = "",
    mode: Mode,
    hub: ?hubclient.Hub,
    wake: Io.Event = .unset,
    running: std.atomic.Value(bool) = .init(true),
    // Sync status, guarded by `lock`.
    state: SyncState = .connecting,
    head: u64 = 0,
    events_connected: bool = false,
    reported: ?Reported = null,
    /// Note id → the client that opened it (the engine keeps one editing
    /// session per note). Guarded by `lock`; keys are owned.
    owners: std.StringHashMapUnmanaged(*Client) = .empty,
    clients_lock: Io.Mutex = .init,
    clients: std.ArrayList(*Client) = .empty,
    socket_clients: std.atomic.Value(usize) = .init(0),
    /// Last connect, disconnect or socket request (ms), for the idle exit.
    last_activity: std.atomic.Value(i64) = .init(0),
    /// Attachment names to fetch from the hub, guarded by `dl_lock` (never
    /// taken while waiting for `lock`, so it is safe under `lock`).
    dl_lock: Io.Mutex = .init,
    downloads: std.ArrayList([]u8) = .empty,

    fn nowMs(self: *Daemon) i64 {
        return Io.Clock.real.now(self.io).toMilliseconds();
    }

    // ------------------------------------------------------------ output

    /// Send to every client that subscribed to events.
    fn broadcast(self: *Daemon, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.clients_lock.lockUncancelable(self.io);
        defer self.clients_lock.unlock(self.io);
        for (self.clients.items) |c| if (c.events.load(.acquire)) c.send(bytes);
    }

    fn valueLine(self: *Daemon, value: anytype) ?[]u8 {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &aw.writer) catch {
            aw.deinit();
            return null;
        };
        aw.writer.writeByte('\n') catch {
            aw.deinit();
            return null;
        };
        return aw.toOwnedSlice() catch null;
    }

    fn broadcastValue(self: *Daemon, value: anytype) void {
        const line = self.valueLine(value) orelse return;
        defer self.gpa.free(line);
        self.broadcast(line);
    }

    fn replyValue(self: *Daemon, c: *Client, value: anytype) void {
        const line = self.valueLine(value) orelse return;
        defer self.gpa.free(line);
        c.send(line);
    }

    fn replyError(self: *Daemon, c: *Client, id: ?i64, message: []const u8) void {
        if (id) |i| {
            self.replyValue(c, .{ .re = i, .ok = false, .@"error" = message });
        } else {
            self.replyValue(c, .{ .ev = "error", .@"error" = message });
        }
    }

    /// Send engine output: the reply to `c`, patches to the client that
    /// opened the note, other events to subscribers. Caller holds `lock`, so
    /// replies and patches leave in the engine's order.
    fn deliver(self: *Daemon, c: ?*Client, out: []const u8) void {
        var rest = out;
        var events_start: ?usize = null;
        while (rest.len > 0) {
            const end = (std.mem.findScalar(u8, rest, '\n') orelse rest.len - 1) + 1;
            const line = rest[0..end];
            const offset = out.len - rest.len;
            rest = rest[end..];
            const is_reply = std.mem.startsWith(u8, line, "{\"re\":");
            const is_patch = std.mem.startsWith(u8, line, "{\"ev\":\"patch\"");
            if (!is_reply and !is_patch) {
                // Batch consecutive broadcast events.
                if (events_start == null) events_start = offset;
                continue;
            }
            if (events_start) |s| {
                self.broadcast(out[s..offset]);
                events_start = null;
            }
            if (is_reply) {
                if (c) |to| to.send(line);
            } else if (patchNote(line)) |note| {
                if (self.owners.get(note)) |owner| owner.send(line);
            }
        }
        if (events_start) |s| self.broadcast(out[s..]);
    }

    /// Emit a `sync` event if state, pending count or head changed. Caller holds `lock`.
    fn syncChangedLocked(self: *Daemon) void {
        const now: Reported = .{ .state = self.state, .pending = self.rep.pending(), .head = self.head };
        if (self.reported) |r| if (r.state == now.state and r.pending == now.pending and r.head == now.head) return;
        self.reported = now;
        self.broadcastValue(.{ .ev = "sync", .state = @tagName(now.state), .pending = now.pending, .head = now.head });
    }

    fn syncChanged(self: *Daemon) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.syncChangedLocked();
    }

    // ------------------------------------------------------------ replay

    pub fn begin(self: *Daemon, id: u64) !void {
        self.engine = try core.Engine.init(self.gpa, id);
        self.engine_ready = true;
    }

    pub fn ops(self: *Daemon, line: []const u8) !void {
        var discard: std.ArrayList(u8) = .empty;
        defer discard.deinit(self.gpa);
        self.engine.ingest(line, &discard) catch |err| {
            std.log.warn("replay: skipping ops line ({s})", .{@errorName(err)});
        };
    }

    // ------------------------------------------------------------ clients

    fn addClient(self: *Daemon, c: *Client) !void {
        self.clients_lock.lockUncancelable(self.io);
        defer self.clients_lock.unlock(self.io);
        try self.clients.append(self.gpa, c);
    }

    /// Close the notes `c` had open, then forget it.
    fn dropClient(self: *Daemon, c: *Client) void {
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            var owned: std.ArrayList([]const u8) = .empty;
            defer owned.deinit(self.gpa);
            var it = self.owners.iterator();
            while (it.next()) |e| if (e.value_ptr.* == c) owned.append(self.gpa, e.key_ptr.*) catch {};
            for (owned.items) |note| {
                const req = std.fmt.allocPrint(self.gpa, "{{\"id\":0,\"cmd\":\"close\",\"note\":\"{s}\"}}", .{note}) catch continue;
                defer self.gpa.free(req);
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(self.gpa);
                self.engine.call(req, self.nowMs(), &out) catch {};
                _ = self.owners.remove(note);
                self.gpa.free(note);
            }
        }
        self.clients_lock.lockUncancelable(self.io);
        for (self.clients.items, 0..) |x, i| if (x == c) {
            _ = self.clients.swapRemove(i);
            break;
        };
        self.clients_lock.unlock(self.io);
        if (c.stream) |s| s.close(self.io);
        if (c.kind == .socket) {
            _ = self.socket_clients.fetchSub(1, .acq_rel);
            self.last_activity.store(self.nowMs(), .release);
        }
        self.gpa.destroy(c);
    }

    fn acceptLoop(self: *Daemon, server: *Io.net.Server) void {
        while (self.running.load(.acquire)) {
            const stream = server.accept(self.io) catch |err| {
                std.log.warn("socket accept: {s}", .{@errorName(err)});
                self.io.sleep(.fromMilliseconds(100), .awake) catch {};
                continue;
            };
            if (self.socket_clients.load(.acquire) >= max_socket_clients) {
                stream.close(self.io);
                continue;
            }
            const c = self.gpa.create(Client) catch {
                stream.close(self.io);
                continue;
            };
            c.* = .{ .d = self, .kind = .socket, .events = .init(false), .writer = undefined, .stream = stream };
            c.sw = stream.writer(self.io, &c.wbuf);
            c.writer = &c.sw.interface;
            _ = self.socket_clients.fetchAdd(1, .acq_rel);
            self.last_activity.store(self.nowMs(), .release);
            self.addClient(c) catch {
                self.dropClient(c);
                continue;
            };
            const t = std.Thread.spawn(.{}, Daemon.clientLoop, .{ self, c }) catch {
                self.dropClient(c);
                continue;
            };
            t.detach();
        }
    }

    fn clientLoop(self: *Daemon, c: *Client) void {
        defer self.dropClient(c);
        var rbuf: [64 * 1024]u8 = undefined;
        var sr = c.stream.?.reader(self.io, &rbuf);
        var line: Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        while (self.running.load(.acquire)) {
            const got = readLine(&sr.interface, &line, max_line_bytes) catch |err| {
                if (err == error.StreamTooLong) self.replyError(c, null, "request line too long");
                return;
            } orelse return;
            self.last_activity.store(self.nowMs(), .release);
            const trimmed = std.mem.trim(u8, got, " \t\r");
            if (trimmed.len == 0) continue;
            self.handleLine(c, trimmed);
        }
    }

    // ------------------------------------------------------------ requests

    fn handleLine(self: *Daemon, c: *Client, line: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, line, .{}) catch {
            self.replyError(c, null, "request is not valid JSON");
            return;
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |o| o,
            else => return self.replyError(c, null, "request is not a JSON object"),
        };
        const id: ?i64 = if (object.get("id")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;
        const cmd = strField(object, "cmd") orelse "";
        const eql = std.mem.eql;

        if (eql(u8, cmd, "status")) return self.status(c, id);
        if (eql(u8, cmd, "paste")) return self.doPaste(c, id);
        if (eql(u8, cmd, "attach")) return self.doAttach(c, id, object);
        if (eql(u8, cmd, "history")) return self.doHistory(c, id, object);
        if (eql(u8, cmd, "restore")) return self.doRestore(c, id, object);
        if (eql(u8, cmd, "read") and object.get("at") != null) return self.doReadAt(c, id, object);
        if (eql(u8, cmd, "daemon.exit")) return self.doExit(c, id);
        if (eql(u8, cmd, "hello") and c.kind == .socket) {
            if (object.get("events")) |v| c.events.store(v == .bool and v.bool, .release);
        }
        self.forward(c, line, id, cmd, strField(object, "note"));
    }

    fn status(self: *Daemon, c: *Client, id: ?i64) void {
        self.lock.lockUncancelable(self.io);
        const state = self.state;
        const pending = self.rep.pending();
        const head = self.head;
        const rid = self.rep.idHex();
        self.lock.unlock(self.io);
        self.replyValue(c, .{
            .re = id orelse 0,
            .ok = true,
            .sync = @tagName(state),
            .hub = if (self.hub) |h| h.base else "",
            .pending = pending,
            .head = head,
            .replica = &rid,
            .data = self.data_path,
            .socket = self.socket_path,
            .mode = @tagName(self.mode),
            .daemon = version,
        });
    }

    fn forward(self: *Daemon, c: *Client, line: []const u8, id: ?i64, cmd: []const u8, note: ?[]const u8) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        const queued = self.callEngine(c, line, &out, cmd, note) catch |err| {
            return self.replyError(c, id, @errorName(err));
        };
        self.queueMissingAttachments(out.items);
        if (queued) self.wake.set(self.io);
    }

    /// Run one request through the engine, persist the ops it created, and
    /// deliver its output, all under `lock`, so replies and patch events leave
    /// in exactly the engine's order (patches carry `pseq`, edits `ack`).
    /// Returns whether new ops were queued for the hub.
    fn callEngine(self: *Daemon, c: *Client, line: []const u8, out: *std.ArrayList(u8), cmd: []const u8, note: ?[]const u8) !bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const eql = std.mem.eql;
        const session = eql(u8, cmd, "open") or eql(u8, cmd, "edit") or eql(u8, cmd, "close");
        if (session) if (note) |n| if (self.owners.get(n)) |owner| if (owner != c) {
            if (eql(u8, cmd, "close")) {
                // Not this client's session: nothing to close.
                try out.print(self.gpa, "{{\"re\":{d},\"ok\":true}}\n", .{requestId(line)});
            } else {
                try out.print(self.gpa, "{{\"re\":{d},\"ok\":false,\"error\":\"note is open in another omajot client\"}}\n", .{requestId(line)});
            }
            c.send(out.items);
            return false;
        };
        try self.engine.call(line, self.nowMs(), out);
        if (eql(u8, cmd, "hello")) self.augmentHello(out) catch {};
        if (session) if (note) |n| if (replyOk(out.items)) {
            if (eql(u8, cmd, "open") and !self.owners.contains(n)) {
                const key = try self.gpa.dupe(u8, n);
                self.owners.put(self.gpa, key, c) catch |err| {
                    self.gpa.free(key);
                    return err;
                };
            } else if (eql(u8, cmd, "close")) {
                if (self.owners.fetchRemove(n)) |kv| self.gpa.free(kv.key);
            }
        };
        var queued = false;
        const new_ops = try self.engine.takeNewOps(self.gpa);
        defer self.gpa.free(new_ops);
        if (!isEmptyArray(new_ops)) {
            if (self.rep.recordLocal(new_ops)) {
                queued = true;
            } else |err| {
                // Applied in memory but not durable: say so loudly.
                std.log.err("cannot persist local ops: {s}", .{@errorName(err)});
                try out.appendSlice(self.gpa, "{\"ev\":\"error\",\"error\":\"cannot save the last edit to disk\"}\n");
            }
        }
        self.deliver(c, out.items);
        if (queued) self.syncChangedLocked();
        return queued;
    }

    /// Add `data` and `attachments` (absolute, trailing slash: the QML preview's
    /// baseUrl) to the engine's hello reply.
    fn augmentHello(self: *Daemon, out: *std.ArrayList(u8)) !void {
        const end = std.mem.findScalar(u8, out.items, '\n') orelse out.items.len;
        const reply = out.items[0..end];
        if (reply.len < 2 or reply[reply.len - 1] != '}' or std.mem.find(u8, reply, "\"ok\":true") == null) return;
        const att = try std.fmt.allocPrint(self.gpa, "{s}/{s}/", .{ self.data_path, attachments.dir_name });
        defer self.gpa.free(att);
        const extra = try std.fmt.allocPrint(self.gpa, ",\"data\":{f},\"attachments\":{f},\"hub\":{f},\"daemon\":\"{s}\",\"socket\":{f},\"mode\":\"{s}\"", .{
            std.json.fmt(self.data_path, .{}),
            std.json.fmt(att, .{}),
            std.json.fmt(if (self.hub) |h| h.base else "", .{}),
            version,
            std.json.fmt(self.socket_path, .{}),
            @tagName(self.mode),
        });
        defer self.gpa.free(extra);
        try out.insertSlice(self.gpa, end - 1, extra);
    }

    /// ops.jsonl, read under `lock` so no half-written line is seen.
    fn readLog(self: *Daemon) ![]u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.data_dir.readFileAlloc(self.io, "ops.jsonl", self.gpa, .limited(replica.max_file_bytes));
    }

    /// `history {note}`: the note's versions from the op log (core/history).
    fn doHistory(self: *Daemon, c: *Client, id: ?i64, object: std.json.ObjectMap) void {
        const note_s = strField(object, "note") orelse return self.replyError(c, id, "history: note is required");
        const note = core.engine.parseNoteId(note_s) catch return self.replyError(c, id, "unknown note");
        const log = self.readLog() catch |err| return self.replyError(c, id, @errorName(err));
        defer self.gpa.free(log);
        const vs = core.history.versions(self.gpa, log, note) catch |err| return self.replyError(c, id, @errorName(err));
        defer self.gpa.free(vs);
        if (vs.len == 0) return self.replyError(c, id, "unknown note");
        const Out = struct { t_first: i64, t_last: i64, replica: []const u8, self: bool, inserted: u64, deleted: u64, created: bool, other: u64 };
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const list = arena.alloc(Out, vs.len) catch return self.replyError(c, id, "OutOfMemory");
        for (vs, list) |v, *o| o.* = .{
            .t_first = v.t_first,
            .t_last = v.t_last,
            .replica = std.fmt.allocPrint(arena, "{x:0>16}", .{v.replica}) catch "",
            .self = v.replica == self.rep.id,
            .inserted = v.inserted,
            .deleted = v.deleted,
            .created = v.created,
            .other = v.other,
        };
        self.replyValue(c, .{ .re = id orelse 0, .ok = true, .note = note_s, .versions = list });
    }

    fn textAt(self: *Daemon, object: std.json.ObjectMap) ![]u8 {
        const note_s = strField(object, "note") orelse return error.BadRequest;
        const note = core.engine.parseNoteId(note_s) catch return error.UnknownNote;
        const at = switch (object.get("at") orelse return error.BadRequest) {
            .integer => |i| i,
            else => return error.BadRequest,
        };
        const log = try self.readLog();
        defer self.gpa.free(log);
        return core.history.textAt(self.gpa, log, note, at);
    }

    /// `read {note, at}`: the note's text at a past time.
    fn doReadAt(self: *Daemon, c: *Client, id: ?i64, object: std.json.ObjectMap) void {
        const t = self.textAt(object) catch |err| return self.replyError(c, id, historyError(err));
        defer self.gpa.free(t);
        self.replyValue(c, .{ .re = id orelse 0, .ok = true, .text = t });
    }

    /// `restore {note, at}`: make the text at `at` the current text, as an
    /// ordinary edit (a `put`), so the change syncs and has its own history.
    fn doRestore(self: *Daemon, c: *Client, id: ?i64, object: std.json.ObjectMap) void {
        const t = self.textAt(object) catch |err| return self.replyError(c, id, historyError(err));
        defer self.gpa.free(t);
        const req = std.fmt.allocPrint(self.gpa, "{{\"id\":{d},\"cmd\":\"put\",\"note\":{f},\"text\":{f}}}", .{
            id orelse 0, std.json.fmt(strField(object, "note").?, .{}), std.json.fmt(t, .{}),
        }) catch return self.replyError(c, id, "OutOfMemory");
        defer self.gpa.free(req);
        self.forward(c, req, id, "put", null);
    }

    /// `daemon.exit`: a background daemon stops so a plugin daemon can take
    /// over the data directory. A plugin daemon refuses.
    fn doExit(self: *Daemon, c: *Client, id: ?i64) void {
        if (self.mode != .background) return self.replyError(c, id, "only a background daemon stops on request");
        self.replyValue(c, .{ .re = id orelse 0, .ok = true });
        self.lock.lockUncancelable(self.io);
        // Holding `lock`: no request is half-applied. Everything is on disk.
        self.shutdown();
    }

    /// Remove the socket and exit. Caller holds `lock`.
    fn shutdown(self: *Daemon) noreturn {
        self.running.store(false, .release);
        if (self.socket_path.len > 0) Io.Dir.cwd().deleteFile(self.io, self.socket_path) catch {};
        std.process.exit(0);
    }

    fn doPaste(self: *Daemon, c: *Client, id: ?i64) void {
        var fallback_client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer fallback_client.deinit();
        var p: paste.Paster = .{
            .gpa = self.gpa,
            .io = self.io,
            .att_dir = self.att_dir,
            .http = if (self.hub) |*h| &h.client else &fallback_client,
        };
        defer p.deinit();
        const md = p.paste() catch |err| return self.replyError(c, id, @errorName(err));
        defer self.gpa.free(md);
        if (p.stored.items.len > 0) {
            self.lock.lockUncancelable(self.io);
            for (p.stored.items) |name| self.rep.addUpload(name) catch {};
            self.lock.unlock(self.io);
            self.wake.set(self.io);
        }
        self.replyValue(c, .{ .re = id orelse 0, .ok = true, .ins = md });
    }

    /// `attach {path}`: copy a local file into the attachments and queue its
    /// upload; reply `{name: "attachments/<sha256>.<ext>"}` for use in markdown.
    fn doAttach(self: *Daemon, c: *Client, id: ?i64, object: std.json.ObjectMap) void {
        const path = if (object.get("path")) |v| switch (v) {
            .string => |str| str,
            else => return self.replyError(c, id, "attach: path must be a string"),
        } else return self.replyError(c, id, "attach: path is required");
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(attachments.max_bytes)) catch |err|
            return self.replyError(c, id, @errorName(err));
        defer self.gpa.free(bytes);
        const dot_ext = std.fs.path.extension(path);
        const ext = if (dot_ext.len > 1) dot_ext[1..] else attachments.sniffExt(bytes) orelse "bin";
        const name = attachments.store(self.io, self.att_dir, bytes, ext) catch |err| return self.replyError(c, id, @errorName(err));
        self.lock.lockUncancelable(self.io);
        self.rep.addUpload(name.slice()) catch {};
        self.lock.unlock(self.io);
        self.wake.set(self.io);
        var buf: [attachments.dir_name.len + 1 + name.buf.len]u8 = undefined;
        const ref = std.fmt.bufPrint(&buf, attachments.dir_name ++ "/{s}", .{name.slice()}) catch unreachable;
        self.replyValue(c, .{ .re = id orelse 0, .ok = true, .name = ref });
    }

    fn queueMissingAttachments(self: *Daemon, text: []const u8) void {
        const Ctx = struct {
            d: *Daemon,
            added: bool = false,
            fn found(ctx: *@This(), name: []const u8) void {
                if (attachmentExists(ctx.d, name)) return;
                ctx.d.dl_lock.lockUncancelable(ctx.d.io);
                defer ctx.d.dl_lock.unlock(ctx.d.io);
                for (ctx.d.downloads.items) |q| if (std.mem.eql(u8, q, name)) return;
                const copy = ctx.d.gpa.dupe(u8, name) catch return;
                ctx.d.downloads.append(ctx.d.gpa, copy) catch {
                    ctx.d.gpa.free(copy);
                    return;
                };
                ctx.added = true;
            }
        };
        if (self.hub == null) return;
        var ctx: Ctx = .{ .d = self };
        attachments.scan(text, &ctx, Ctx.found);
        if (ctx.added) self.wake.set(self.io);
    }

    // ------------------------------------------------------------ sync

    fn syncLoop(self: *Daemon) void {
        var backoff_ms: i64 = 0;
        while (self.running.load(.acquire)) {
            const wait_ms: i64 = if (backoff_ms > 0) backoff_ms else idle_poll_ms;
            self.wake.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(wait_ms), .clock = .awake } }) catch {};
            self.wake.reset();
            if (!self.running.load(.acquire)) return;
            // Let a burst of keystrokes land in one batch.
            self.io.sleep(.fromMilliseconds(push_debounce_ms), .awake) catch {};
            self.round() catch |err| {
                std.log.warn("sync: {s}", .{@errorName(err)});
                self.lock.lockUncancelable(self.io);
                self.state = .offline;
                self.syncChangedLocked();
                self.lock.unlock(self.io);
                backoff_ms = std.math.clamp(backoff_ms * 2, 1000, max_backoff_ms);
                continue;
            };
            backoff_ms = 0;
            self.lock.lockUncancelable(self.io);
            self.state = .online;
            self.syncChangedLocked();
            self.lock.unlock(self.io);
        }
    }

    fn round(self: *Daemon) !void {
        const hub = if (self.hub) |*h| h else return;
        try self.push(hub);
        try self.pull(hub);
        try self.uploads(hub);
        try self.fetchDownloads(hub);
    }

    fn push(self: *Daemon, hub: *hubclient.Hub) !void {
        while (true) {
            const body = blk: {
                self.lock.lockUncancelable(self.io);
                defer self.lock.unlock(self.io);
                const next = (try self.rep.nextBatch()) orelse return;
                break :blk try self.gpa.dupe(u8, next);
            };
            defer self.gpa.free(body);
            const response = try hub.send(.POST, "/api/batches", body, "application/json");
            defer response.deinit(self.gpa);
            switch (response.status) {
                200 => {
                    const parsed = std.json.parseFromSlice(struct { seq: u64, head: u64 }, self.gpa, response.body, .{}) catch return error.BadHubResponse;
                    defer parsed.deinit();
                    self.lock.lockUncancelable(self.io);
                    defer self.lock.unlock(self.io);
                    try self.rep.ackInflight();
                    self.head = @max(self.head, parsed.value.head);
                    self.syncChangedLocked();
                },
                409 => {
                    // The hub has a different history for our bseq sequence
                    // (e.g. its data was reset). Needs a human; keep the ops.
                    self.broadcastValue(.{ .ev = "error", .@"error" = "hub rejected our batch sequence (409); local edits are kept but not synced" });
                    return error.BatchSequenceConflict;
                },
                else => {
                    std.log.warn("hub rejected batch: {d} {s}", .{ response.status, response.body[0..@min(response.body.len, 200)] });
                    return error.HubRejectedBatch;
                },
            }
        }
    }

    fn pull(self: *Daemon, hub: *hubclient.Hub) !void {
        while (true) {
            self.lock.lockUncancelable(self.io);
            const cursor = self.rep.cursor;
            const own = self.rep.id;
            self.lock.unlock(self.io);

            var path_buf: [96]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "/api/batches?after={d}&limit={d}", .{ cursor, page_limit });
            const response = try hub.send(.GET, path, null, null);
            defer response.deinit(self.gpa);
            if (response.status != 200) return error.PullFailed;
            const head_raw = (try rawjson.field(self.gpa, response.body, "head")) orelse return error.BadHubResponse;
            const head = std.fmt.parseInt(u64, head_raw, 10) catch return error.BadHubResponse;
            const batches_raw = (try rawjson.field(self.gpa, response.body, "batches")) orelse return error.BadHubResponse;
            const batches = try rawjson.elements(self.gpa, batches_raw);
            defer self.gpa.free(batches);

            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.gpa);
            {
                self.lock.lockUncancelable(self.io);
                defer self.lock.unlock(self.io);
                if (head < cursor) {
                    // The hub knows less than we do (reset or a different hub).
                    self.broadcastValue(.{ .ev = "error", .@"error" = "hub head is behind this replica's cursor; not pulling" });
                    return error.HubBehindCursor;
                }
                self.head = head;
                for (batches) |batch| {
                    const seq_raw = (try rawjson.field(self.gpa, batch, "seq")) orelse return error.BadHubResponse;
                    const seq = std.fmt.parseInt(u64, seq_raw, 10) catch return error.BadHubResponse;
                    if (seq <= self.rep.cursor) continue;
                    const replica_raw = (try rawjson.field(self.gpa, batch, "replica")) orelse return error.BadHubResponse;
                    const from = std.fmt.parseInt(u64, std.mem.trim(u8, replica_raw, "\""), 16) catch return error.BadHubResponse;
                    const batch_ops = (try rawjson.field(self.gpa, batch, "ops")) orelse return error.BadHubResponse;
                    self.engine.ingest(batch_ops, &out) catch |err| {
                        std.log.err("ingest seq {d}: {s}", .{ seq, @errorName(err) });
                        return err;
                    };
                    if (from != own) try self.rep.recordRemote(batch_ops);
                    try self.rep.setCursor(seq);
                }
                // Under the lock: patch events keep their order relative to replies.
                self.deliver(null, out.items);
                self.syncChangedLocked();
            }
            self.queueMissingAttachments(out.items);
            self.lock.lockUncancelable(self.io);
            const done = self.rep.cursor >= head or batches.len == 0;
            self.lock.unlock(self.io);
            if (done) return;
        }
    }

    fn uploads(self: *Daemon, hub: *hubclient.Hub) !void {
        while (true) {
            const name = blk: {
                self.lock.lockUncancelable(self.io);
                defer self.lock.unlock(self.io);
                if (self.rep.uploads.items.len == 0) return;
                break :blk try self.gpa.dupe(u8, self.rep.uploads.items[0]);
            };
            defer self.gpa.free(name);
            const bytes = self.att_dir.readFileAlloc(self.io, name, self.gpa, .limited(attachments.max_bytes)) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (bytes) |b| {
                defer self.gpa.free(b);
                try hub.putBlob(name, b);
            }
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            try self.rep.removeUpload(name);
        }
    }

    fn fetchDownloads(self: *Daemon, hub: *hubclient.Hub) !void {
        while (true) {
            const name = blk: {
                self.dl_lock.lockUncancelable(self.io);
                defer self.dl_lock.unlock(self.io);
                if (self.downloads.items.len == 0) return;
                break :blk self.downloads.orderedRemove(0);
            };
            defer self.gpa.free(name);
            const bytes = (hub.getBlob(name) catch |err| {
                std.log.warn("download {s}: {s}", .{ name, @errorName(err) });
                continue;
            }) orelse continue; // not uploaded yet; the next reference retries
            defer self.gpa.free(bytes);
            attachments.storeVerified(self.io, self.att_dir, name, bytes) catch |err| {
                std.log.warn("attachment {s}: {s}", .{ name, @errorName(err) });
                continue;
            };
            // Tell the UI so an open preview can reload the image.
            self.broadcastValue(.{ .ev = "attachment", .name = name });
        }
    }

    fn doorbellLoop(self: *Daemon) void {
        const hub = if (self.hub) |*h| h else return;
        var backoff_ms: i64 = 1000;
        while (self.running.load(.acquire)) {
            self.lock.lockUncancelable(self.io);
            const cursor = self.rep.cursor;
            self.lock.unlock(self.io);
            const Handler = struct {
                fn connected(d: *Daemon) void {
                    d.lock.lockUncancelable(d.io);
                    d.events_connected = true;
                    d.lock.unlock(d.io);
                    // Catch up on anything missed while disconnected.
                    d.wake.set(d.io);
                }
                fn head(d: *Daemon, h: u64) void {
                    d.lock.lockUncancelable(d.io);
                    const behind = h != d.rep.cursor;
                    d.lock.unlock(d.io);
                    if (behind) d.wake.set(d.io);
                }
            };
            if (hub.followEvents(cursor, self, Handler.connected, Handler.head)) {
                backoff_ms = 1000; // clean end at the stream's planned lifetime
                self.io.sleep(.fromMilliseconds(100), .awake) catch {};
            } else |err| {
                // ReadFailed included: a cut stream is just a reconnect. Back off
                // only while connecting fails; a stream that was up (and then cut,
                // e.g. by the server deadline) reconnects at once.
                self.lock.lockUncancelable(self.io);
                const was_connected = self.events_connected;
                self.events_connected = false;
                self.lock.unlock(self.io);
                if (was_connected) backoff_ms = 1000;
                const delay_ms: i64 = if (was_connected) 250 else backoff_ms;
                std.log.info("events: {s}; reconnecting in {d} ms", .{ @errorName(err), delay_ms });
                self.io.sleep(.fromMilliseconds(delay_ms), .awake) catch {};
                if (!was_connected) backoff_ms = @min(backoff_ms * 2, max_backoff_ms);
            }
        }
    }
};

fn isEmptyArray(json: []const u8) bool {
    const t = std.mem.trim(u8, json, " \t\r\n");
    if (t.len < 2 or t[0] != '[') return false;
    return std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n").len == 0;
}

fn strField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The request's `id` (0 when missing), without a full parse.
fn requestId(line: []const u8) i64 {
    const parsed = std.json.parseFromSlice(struct { id: i64 = 0 }, std.heap.page_allocator, line, .{ .ignore_unknown_fields = true }) catch return 0;
    defer parsed.deinit();
    return parsed.value.id;
}

/// Whether the first line of engine output is a successful reply.
fn replyOk(out: []const u8) bool {
    const end = std.mem.findScalar(u8, out, '\n') orelse out.len;
    return std.mem.find(u8, out[0..end], "\"ok\":true") != null;
}

/// The note id of a `{"ev":"patch","note":"n-…",…}` line.
fn patchNote(line: []const u8) ?[]const u8 {
    const key = "\"note\":\"";
    const start = (std.mem.find(u8, line, key) orelse return null) + key.len;
    const end = std.mem.findScalarPos(u8, line, start, '"') orelse return null;
    return line[start..end];
}

fn historyError(err: anyerror) []const u8 {
    return switch (err) {
        error.NoteDidNotExist => "the note did not exist at that time",
        error.UnknownNote => "unknown note",
        error.BadRequest => "bad request",
        else => @errorName(err),
    };
}

/// One line from `r` without the newline, or null at the end of the stream.
pub fn readLine(r: *Io.Reader, aw: *Io.Writer.Allocating, limit: usize) !?[]const u8 {
    aw.clearRetainingCapacity();
    _ = try r.streamDelimiterLimit(&aw.writer, '\n', .limited(limit));
    if (r.peekByte()) |_| {
        r.toss(1);
    } else |err| switch (err) {
        error.EndOfStream => if (aw.written().len == 0) return null,
        error.ReadFailed => return error.ReadFailed,
    }
    return aw.written();
}

// Local check used by queueMissingAttachments.
fn attachmentExists(d: *Daemon, name: []const u8) bool {
    return @import("../hub/blobs.zig").exists(d.io, d.att_dir, name);
}

const Options = struct {
    /// Null: not given on the command line (then the config file; else no hub).
    hub: ?[]const u8 = null,
    no_hub: bool = false,
    data: ?[]const u8 = null,
    socket: ?[]const u8 = null,
    background: bool = false,
    idle_exit_s: u32 = default_idle_exit_s,
};

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        var name = arg;
        var value: ?[]const u8 = null;
        if (std.mem.findScalar(u8, arg, '=')) |eq| {
            name = arg[0..eq];
            value = arg[eq + 1 ..];
        }
        if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) return error.Help;
        if (std.mem.eql(u8, name, "--no-hub")) {
            options.no_hub = true;
            continue;
        }
        if (std.mem.eql(u8, name, "--background")) {
            options.background = true;
            continue;
        }
        const v = value orelse blk: {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            break :blk args[i];
        };
        if (std.mem.eql(u8, name, "--hub")) {
            if (v.len == 0) options.no_hub = true else options.hub = v;
        } else if (std.mem.eql(u8, name, "--data")) {
            options.data = v;
        } else if (std.mem.eql(u8, name, "--socket")) {
            options.socket = v;
        } else if (std.mem.eql(u8, name, "--idle-exit")) {
            options.idle_exit_s = std.fmt.parseInt(u32, v, 10) catch return error.BadIdleExit;
        } else return error.UnknownOption;
    }
    return options;
}

/// Take `<data>/daemon.lock`. When a background daemon holds it and this
/// is a plugin daemon, ask that one to stop and wait for it.
fn takeLock(io: Io, data_dir: Io.Dir, mode: Mode, gpa: Allocator) !Io.File {
    const file = try data_dir.createFile(io, paths.lock_name, .{ .read = true, .truncate = false });
    errdefer file.close(io);
    if (try file.tryLock(io, .exclusive)) return file;

    const holder = readLockInfo(gpa, io, data_dir);
    defer if (holder) |h| h.deinit();
    const info: paths.LockInfo = if (holder) |h| h.value else .{};
    if (mode == .plugin and std.mem.eql(u8, info.mode, "background") and info.socket.len > 0) {
        std.log.info("asking the background daemon (pid {d}) to hand over", .{info.pid});
        askExit(io, info.socket);
        var waited: u32 = 0;
        while (waited < 100) : (waited += 1) {
            if (try file.tryLock(io, .exclusive)) return file;
            io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
    }
    std.debug.print("omajot daemon: another omajot daemon (pid {d}, {s}) uses this data directory\n", .{ info.pid, if (info.mode.len > 0) info.mode else "unknown" });
    std.process.exit(exit_locked);
}

fn readLockInfo(gpa: Allocator, io: Io, data_dir: Io.Dir) ?std.json.Parsed(paths.LockInfo) {
    const bytes = data_dir.readFileAlloc(io, paths.lock_name, gpa, .limited(4096)) catch return null;
    defer gpa.free(bytes);
    return std.json.parseFromSlice(paths.LockInfo, gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

fn askExit(io: Io, socket: []const u8) void {
    const addr = Io.net.UnixAddress.init(socket) catch return;
    const stream = addr.connect(io) catch return;
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll("{\"id\":1,\"cmd\":\"daemon.exit\"}\n") catch return;
    w.interface.flush() catch return;
    var rbuf: [256]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    _ = r.interface.takeDelimiter('\n') catch {};
}

/// Listen on `path` (mode 0600). A stale socket file is replaced; a live one
/// (another data directory's daemon) is left alone.
fn listenSocket(io: Io, path: []const u8) !Io.net.Server {
    const addr = try Io.net.UnixAddress.init(path);
    if (addr.connect(io)) |s| {
        s.close(io);
        return error.SocketInUse;
    } else |_| {}
    Io.Dir.cwd().deleteFile(io, path) catch {};
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    const old = paths.setUmask(0o177);
    defer _ = paths.setUmask(old);
    const server = try addr.listen(io, .{});
    if (@import("builtin").os.tag != .windows) {
        Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o600), .{}) catch {};
    }
    return server;
}

pub fn main(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const gpa = init.gpa;
    const options = parseOptions(args) catch |err| {
        if (err != error.Help) std.debug.print("omajot daemon: {s}\n", .{@errorName(err)});
        std.debug.print("{s}", .{usage});
        std.process.exit(if (err == error.Help) 0 else 2);
    };
    const mode: Mode = if (options.background) .background else .plugin;

    var config_arena: std.heap.ArenaAllocator = .init(gpa);
    defer config_arena.deinit();
    const where = paths.resolve(config_arena.allocator(), io, init.environ_map, .{ .data = options.data, .socket = options.socket }) catch |err| {
        std.debug.print("omajot daemon: cannot resolve the config and data directory: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    const hub_url: ?[]const u8 = if (options.no_hub) null else options.hub orelse where.config.hub;
    const data_path = where.data;

    var data_dir = try Io.Dir.cwd().openDir(io, data_path, .{});
    defer data_dir.close(io);
    const lock_file = try takeLock(io, data_dir, mode, gpa);
    defer lock_file.close(io);
    {
        const info = try std.json.Stringify.valueAlloc(gpa, paths.LockInfo{ .pid = paths.currentPid(), .socket = where.socket, .mode = @tagName(mode) }, .{});
        defer gpa.free(info);
        lock_file.setLength(io, 0) catch {};
        lock_file.writePositionalAll(io, info, 0) catch {};
    }
    try data_dir.createDirPath(io, attachments.dir_name);
    var att_dir = try data_dir.openDir(io, attachments.dir_name, .{});
    defer att_dir.close(io);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);

    const d = try gpa.create(Daemon);
    defer gpa.destroy(d);
    d.* = .{
        .gpa = gpa,
        .io = io,
        .data_path = data_path,
        .data_dir = data_dir,
        .att_dir = att_dir,
        .mode = mode,
        .hub = if (hub_url) |url| hubclient.Hub.init(gpa, io, url) else null,
    };
    d.last_activity.store(d.nowMs(), .release);
    d.rep = try replica.Replica.open(gpa, io, data_dir, d);
    std.log.info("omajot daemon {s}: replica {s}, data {s}, hub {s}", .{ version, &d.rep.idHex(), data_path, hub_url orelse "(none)" });

    var stdio_client: Client = .{ .d = d, .kind = .stdio, .events = .init(true), .writer = &stdout_writer.interface };
    if (mode == .plugin) try d.addClient(&stdio_client);

    if (d.hub == null) {
        d.state = .offline;
        if (!options.no_hub) std.log.info("no hub configured: notes stay on this machine. Set \"hub\" in {s} to sync.", .{where.config_path});
    }
    d.syncChanged();

    var server: ?Io.net.Server = null;
    if (where.socket.len > 0 and Io.net.has_unix_sockets) {
        if (listenSocket(io, where.socket)) |s| {
            server = s;
            d.socket_path = where.socket;
            const t = try std.Thread.spawn(.{}, Daemon.acceptLoop, .{ d, &server.? });
            t.detach();
        } else |err| {
            std.log.warn("no socket at {s}: {s}; omajot commands cannot reach this daemon", .{ where.socket, @errorName(err) });
            if (mode == .background) std.process.exit(exit_locked);
        }
    }
    // Rewrite the lock info with the socket actually in use.
    if (d.socket_path.len == 0) {
        const info = try std.json.Stringify.valueAlloc(gpa, paths.LockInfo{ .pid = paths.currentPid(), .mode = @tagName(mode) }, .{});
        defer gpa.free(info);
        lock_file.setLength(io, 0) catch {};
        lock_file.writePositionalAll(io, info, 0) catch {};
    }

    if (d.hub != null) {
        const sync_thread = try std.Thread.spawn(.{}, Daemon.syncLoop, .{d});
        sync_thread.detach();
        const bell_thread = try std.Thread.spawn(.{}, Daemon.doorbellLoop, .{d});
        bell_thread.detach();
        d.wake.set(io);
    }

    if (mode == .background) {
        // No stdin: stop after the idle timeout, once local ops reached the hub
        // (or cannot reach it now).
        while (true) {
            io.sleep(.fromMilliseconds(1000), .awake) catch {};
            if (options.idle_exit_s == 0) continue;
            if (d.socket_clients.load(.acquire) > 0) continue;
            if (d.nowMs() - d.last_activity.load(.acquire) < @as(i64, options.idle_exit_s) * 1000) continue;
            d.lock.lockUncancelable(io);
            if (d.state == .online and d.rep.pending() > 0) {
                d.lock.unlock(io);
                continue;
            }
            std.log.info("idle for {d} s: stopping", .{options.idle_exit_s});
            d.shutdown();
        }
    }

    var line: Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;
    while (true) {
        const got = readLine(stdin, &line, max_line_bytes) catch |err| switch (err) {
            error.StreamTooLong => {
                d.replyError(&stdio_client, null, "request line too long");
                _ = stdin.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            else => break,
        } orelse break;
        const trimmed = std.mem.trim(u8, got, " \t\r");
        if (trimmed.len == 0) continue;
        d.handleLine(&stdio_client, trimmed);
    }
    // stdin closed: the plugin is gone. Leave without joining the network
    // threads (they may sit in a blocking read); everything is on disk.
    d.lock.lockUncancelable(io);
    d.shutdown();
}

test {
    _ = replica;
    _ = attachments;
    _ = hubclient;
    _ = paste;
    _ = paths;
}

test "parseOptions" {
    const o = try parseOptions(&.{ "--hub", "http://x:1/", "--data=/tmp/d", "--socket", "/tmp/s", "--background", "--idle-exit", "5" });
    try std.testing.expectEqualStrings("http://x:1/", o.hub.?);
    try std.testing.expectEqualStrings("/tmp/d", o.data.?);
    try std.testing.expectEqualStrings("/tmp/s", o.socket.?);
    try std.testing.expect(o.background);
    try std.testing.expectEqual(@as(u32, 5), o.idle_exit_s);
    try std.testing.expect((try parseOptions(&.{"--no-hub"})).no_hub);
    try std.testing.expect((try parseOptions(&.{ "--hub", "" })).no_hub);
    try std.testing.expect((try parseOptions(&.{})).hub == null);
}

test "readConfig: missing file is empty, fields parse, unknown fields ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const missing = try readConfig(arena.allocator(), io, "/nonexistent/omajot/config.json");
    try std.testing.expect(missing.hub == null and missing.data == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = "{\"hub\":\"https://h:1\",\"data\":\"~/n\",\"socket\":\"/s\",\"theme\":1}" });
    const path = try tmp.dir.realPathFileAlloc(io, "config.json", arena.allocator());
    const c = try readConfig(arena.allocator(), io, path);
    try std.testing.expectEqualStrings("https://h:1", c.hub.?);
    try std.testing.expectEqualStrings("~/n", c.data.?);
    try std.testing.expectEqualStrings("/s", c.socket.?);
}

test "isEmptyArray, patchNote, replyOk" {
    try std.testing.expect(isEmptyArray("[]"));
    try std.testing.expect(isEmptyArray(" [ ] "));
    try std.testing.expect(!isEmptyArray("[1]"));
    try std.testing.expectEqualStrings("n-00000000000000ab-3", patchNote("{\"ev\":\"patch\",\"note\":\"n-00000000000000ab-3\",\"base\":0}").?);
    try std.testing.expect(replyOk("{\"re\":1,\"ok\":true}\n{\"ev\":\"notes\"}\n"));
    try std.testing.expect(!replyOk("{\"re\":1,\"ok\":false,\"error\":\"x\"}\n{\"ok\":true}\n"));
    try std.testing.expectEqual(@as(i64, 7), requestId("{\"id\":7,\"cmd\":\"open\"}"));
}
