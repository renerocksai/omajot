//! The omajot engine: one replica's notes, folders and CRDT state, driven by
//! the client protocol (docs/PROTOCOL.md §1) and by ops from other replicas.
//! Pure: no std.Io, no clock, no randomness, no globals (§3).
//!
//! Op format (JSON, v1). Every op: {"v":1,"k":kind,"r":"<replica hex16>",
//! "c":counter,"t":hlc_ms, …}. Counters are Lamport clocks shared by all
//! replicas (the next local counter is the highest counter seen + 1); an
//! insert of n UTF-16 units consumes counters c … c+n-1. `t` is a hybrid
//! logical clock in milliseconds (max(now, highest t seen + 1)); it orders
//! last-writer-wins registers with (t, replica, counter).
//!
//!   nc   note create     "f": folder id | null
//!   ins  text insert     "n": note, "o": origin "<hex>-<c>" | null, "s": UTF-8 text
//!   del  text delete     "n": note, "d": [["<hex>-<c>", n], …]
//!   ns   note set        "n": note, "p": "folder"|"pinned"|"trashed", "x": value
//!   fc   folder create   "name": text, "parent": folder id | null
//!   fs   folder set      "f": folder, "p": "name"|"parent"|"deleted", "x": value
//!
//! Folder tree rule: parent assignments are replayed in register-stamp
//! order; one that would close a cycle is dropped and that folder becomes a
//! root. A deleted folder's subfolders hang from its nearest live ancestor;
//! notes whose folder is deleted or unknown have folder null.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Writer = std.Io.Writer;

const text = @import("text.zig");
const rga = @import("rga.zig");
const ot = @import("ot.zig");

pub const Id = rga.Id;
pub const version = "0.1.0";

const Stamp = struct {
    t: i64,
    r: u64,
    c: u64,

    const zero: Stamp = .{ .t = std.math.minInt(i64), .r = 0, .c = 0 };

    fn greater(a: Stamp, b: Stamp) bool {
        if (a.t != b.t) return a.t > b.t;
        if (a.r != b.r) return a.r > b.r;
        return a.c > b.c;
    }
};

fn Reg(comptime T: type) type {
    return struct { value: T, stamp: Stamp };
}

const Note = struct {
    id: Id,
    seq: rga.Seq = .{},
    folder: Reg(?Id),
    pinned: Reg(bool) = .{ .value = false, .stamp = .zero },
    trashed: Reg(bool) = .{ .value = false, .stamp = .zero },
    created: i64,
    updated: i64,
    /// UTF-8 of the visible text; null when stale.
    utf8: ?[]u8 = null,

    // Client session state (not replicated).
    open: bool = false,
    last_seq: u64 = 0,
    pseq: u64 = 0,
    /// Patches sent that the client has not acknowledged, rewritten over the
    /// client's later edits. Texts live in `unacked_arena`.
    unacked: []ot.Prim = &.{},
    unacked_arena: ?std.heap.ArenaAllocator = null,

    fn deinit(n: *Note, gpa: Allocator) void {
        n.seq.deinit(gpa);
        if (n.utf8) |s| gpa.free(s);
        if (n.unacked_arena) |*a| a.deinit();
    }

    fn textUtf8(n: *Note, gpa: Allocator) ![]const u8 {
        if (n.utf8) |s| return s;
        const units = try n.seq.toUtf16(gpa);
        defer gpa.free(units);
        n.utf8 = try text.toUtf8(gpa, units);
        return n.utf8.?;
    }

    fn touched(n: *Note, gpa: Allocator) void {
        if (n.utf8) |s| gpa.free(s);
        n.utf8 = null;
    }

    fn setUnacked(n: *Note, gpa: Allocator, prims: []const ot.Prim) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const copy = try a.alloc(ot.Prim, prims.len);
        for (prims, copy) |p, *c| {
            c.* = p;
            c.text = try a.dupe(u16, p.text);
        }
        if (n.unacked_arena) |*old| old.deinit();
        n.unacked_arena = arena;
        n.unacked = copy;
    }

    fn clearSession(n: *Note) void {
        if (n.unacked_arena) |*a| a.deinit();
        n.unacked_arena = null;
        n.unacked = &.{};
    }
};

const Folder = struct {
    id: Id,
    name: Reg([]u8),
    parent: Reg(?Id),
    deleted: Reg(bool) = .{ .value = false, .stamp = .zero },
};

const Pending = struct { id: Id, op: []u8 };

pub const Error = error{
    BadRequest,
    UnknownCommand,
    UnknownNote,
    UnknownFolder,
    OutOfRange,
    SplitsSurrogatePair,
    InvalidUtf8,
    FolderCycle,
    NotHandledByEngine,
};

pub const Engine = struct {
    gpa: Allocator,
    replica: u64,
    /// Highest Lamport counter seen from any replica.
    clock: u64 = 0,
    /// Highest hybrid logical time seen.
    hlc: i64 = 0,
    notes: std.AutoArrayHashMapUnmanaged(Id, *Note) = .empty,
    folders: std.AutoArrayHashMapUnmanaged(Id, *Folder) = .empty,
    /// First id of every applied op (dedupe).
    applied: std.AutoHashMapUnmanaged(Id, void) = .empty,
    /// Ops waiting for a dependency (an origin, a note, a folder).
    pending: std.ArrayList(Pending) = .empty,
    /// Comma-separated local ops since the last takeNewOps.
    new_ops: std.ArrayList(u8) = .empty,
    dirty_notes: std.AutoArrayHashMapUnmanaged(Id, void) = .empty,
    folders_dirty: bool = false,

    pub fn init(gpa: Allocator, replica: u64) !Engine {
        return .{ .gpa = gpa, .replica = replica };
    }

    pub fn deinit(self: *Engine) void {
        const gpa = self.gpa;
        for (self.notes.values()) |n| {
            n.deinit(gpa);
            gpa.destroy(n);
        }
        self.notes.deinit(gpa);
        for (self.folders.values()) |f| {
            gpa.free(f.name.value);
            gpa.destroy(f);
        }
        self.folders.deinit(gpa);
        self.applied.deinit(gpa);
        for (self.pending.items) |p| gpa.free(p.op);
        self.pending.deinit(gpa);
        self.new_ops.deinit(gpa);
        self.dirty_notes.deinit(gpa);
        self.* = undefined;
    }

    /// Ops still waiting for dependencies (should be 0 once all ops arrived).
    pub fn pendingCount(self: *const Engine) usize {
        return self.pending.items.len;
    }

    // ------------------------------------------------------------------ API

    pub fn call(self: *Engine, request: []const u8, now_ms: i64, out: *std.ArrayList(u8)) !void {
        var aw = Writer.Allocating.fromArrayList(self.gpa, out);
        defer out.* = aw.toArrayList();
        const w = &aw.writer;

        const parsed = json.parseFromSlice(json.Value, self.gpa, request, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return writeError(w, 0, "invalid JSON"),
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return writeError(w, 0, "request must be an object"),
        };
        const id: i64 = if (obj.get("id")) |v| switch (v) {
            .integer => |i| i,
            else => 0,
        } else 0;

        var fields = Writer.Allocating.init(self.gpa);
        defer fields.deinit();
        self.dispatch(obj, now_ms, &fields.writer) catch |err| {
            if (err == error.OutOfMemory or err == error.WriteFailed) return error.OutOfMemory;
            try writeError(w, id, errorText(err));
            try self.flushEvents(w);
            return;
        };
        try w.print("{{\"re\":{d},\"ok\":true", .{id});
        try w.writeAll(fields.written());
        try w.writeAll("}\n");
        try self.flushEvents(w);
    }

    pub fn ingest(self: *Engine, ops: []const u8, out: *std.ArrayList(u8)) !void {
        var aw = Writer.Allocating.fromArrayList(self.gpa, out);
        defer out.* = aw.toArrayList();
        const w = &aw.writer;

        const parsed = json.parseFromSlice(json.Value, self.gpa, ops, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidOps,
        };
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return error.InvalidOps,
        };
        for (arr.items) |v| try self.ingestValue(v, w);
        try self.retryPending(w);
        try self.flushEvents(w);
    }

    pub fn takeNewOps(self: *Engine, gpa: Allocator) ![]u8 {
        const result = try std.mem.concat(gpa, u8, &.{ "[", self.new_ops.items, "]" });
        self.new_ops.clearRetainingCapacity();
        return result;
    }

    // ------------------------------------------------------------ requests

    fn dispatch(self: *Engine, obj: json.ObjectMap, now: i64, w: *Writer) !void {
        const cmd = try getStr(obj, "cmd");
        const eql = std.mem.eql;
        if (eql(u8, cmd, "hello")) {
            try w.print(",\"replica\":\"{x:0>16}\",\"version\":\"{s}\"", .{ self.replica, version });
        } else if (eql(u8, cmd, "list")) {
            try self.writeList(w);
        } else if (eql(u8, cmd, "open")) {
            const n = try self.getNote(obj, "note");
            n.open = true;
            n.clearSession();
            try w.writeAll(",\"text\":");
            try json.Stringify.encodeJsonString(try n.textUtf8(self.gpa), .{}, w);
            try w.print(",\"seq\":{d},\"pseq\":{d}", .{ n.last_seq, n.pseq });
        } else if (eql(u8, cmd, "close")) {
            const n = try self.getNote(obj, "note");
            n.open = false;
            n.clearSession();
        } else if (eql(u8, cmd, "edit")) {
            try self.cmdEdit(obj, now);
        } else if (eql(u8, cmd, "create")) {
            const folder = try self.optLiveFolder(obj, "folder");
            const body = if (obj.get("text")) |v| switch (v) {
                .string => |s| s,
                .null => "",
                else => return error.BadRequest,
            } else "";
            const units = try text.toUtf16(self.gpa, body);
            defer self.gpa.free(units);
            const nid = try self.localNoteCreate(folder, now);
            if (units.len > 0) try self.localInsert(self.notes.get(nid).?, 0, units, now);
            try w.writeAll(",\"note\":");
            try writeNoteId(w, nid);
        } else if (eql(u8, cmd, "set")) {
            const n = try self.getNote(obj, "note");
            if (obj.get("folder")) |_| {
                const f = try self.optLiveFolder(obj, "folder");
                try self.localNoteSet(n.id, "folder", if (f) |fid| .{ .folder = fid } else .none, now);
            }
            if (obj.get("pinned")) |v| try self.localNoteSet(n.id, "pinned", .{ .boolean = try asBool(v) }, now);
            if (obj.get("trashed")) |v| try self.localNoteSet(n.id, "trashed", .{ .boolean = try asBool(v) }, now);
        } else if (eql(u8, cmd, "folder.create")) {
            const name = try getStr(obj, "name");
            const parent = try self.optLiveFolder(obj, "parent");
            const fid = try self.localFolderCreate(name, parent, now);
            try w.writeAll(",\"folder\":");
            try writeFolderId(w, fid);
        } else if (eql(u8, cmd, "folder.rename")) {
            const f = try self.getLiveFolder(obj, "folder");
            try self.localFolderSet(f.id, "name", .{ .string = try getStr(obj, "name") }, now);
        } else if (eql(u8, cmd, "folder.move")) {
            const f = try self.getLiveFolder(obj, "folder");
            const parent = try self.optLiveFolder(obj, "parent");
            if (parent) |p| if (try self.isSelfOrDescendant(p, f.id)) return error.FolderCycle;
            try self.localFolderSet(f.id, "parent", if (parent) |p| .{ .folder = p } else .none, now);
        } else if (eql(u8, cmd, "folder.delete")) {
            const f = try self.getLiveFolder(obj, "folder");
            try self.localFolderSet(f.id, "deleted", .{ .boolean = true }, now);
        } else if (eql(u8, cmd, "search")) {
            try self.writeSearch(try getStr(obj, "q"), w);
        } else if (eql(u8, cmd, "paste")) {
            return error.NotHandledByEngine;
        } else if (eql(u8, cmd, "status")) {
            // The shells (daemon, PWA) answer this themselves.
            try w.writeAll(",\"sync\":\"offline\",\"hub\":null,\"pending\":0,\"head\":0");
        } else {
            return error.UnknownCommand;
        }
    }

    fn cmdEdit(self: *Engine, obj: json.ObjectMap, now: i64) !void {
        const n = try self.getNote(obj, "note");
        const seq = try getUint(obj, "seq");
        if (seq <= n.last_seq) return; // resend
        const pos = try getUsize(obj, "pos");
        const del_len = if (obj.get("del")) |_| try getUsize(obj, "del") else 0;
        const ins = if (obj.get("ins")) |v| switch (v) {
            .string => |s| s,
            else => return error.BadRequest,
        } else "";
        const ack = if (obj.get("ack")) |_| try getUint(obj, "ack") else n.pseq;
        const units = try text.toUtf16(self.gpa, ins);
        defer self.gpa.free(units);

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var buf: [2]ot.Prim = undefined;
        const edit = ot.fromEdit(&buf, pos, del_len, units, seq);
        var unseen: std.ArrayList(ot.Prim) = .empty;
        for (n.unacked) |p| if (p.tag > ack) try unseen.append(arena, p);
        const r = try ot.xform(arena, edit, unseen.items, false);

        // Bounds check the whole rewritten edit before touching state.
        var len = n.seq.visible;
        for (r.a) |p| switch (p.kind) {
            .ins => {
                if (p.pos > len) return error.OutOfRange;
                len += p.text.len;
            },
            .del => {
                if (p.pos + p.len > len) return error.OutOfRange;
                len -= p.len;
            },
        };
        try self.checkBoundary(n, r.a[0..@min(r.a.len, 1)]);

        try n.setUnacked(self.gpa, r.b);
        n.last_seq = seq;
        for (r.a, 0..) |p, i| {
            if (i > 0) try self.checkBoundary(n, r.a[i .. i + 1]);
            switch (p.kind) {
                .ins => try self.localInsert(n, p.pos, p.text, now),
                .del => try self.localDelete(n, p.pos, p.len, now),
            }
        }
    }

    /// Reject a primitive whose boundary would split a surrogate pair,
    /// checked against the text it is about to apply to.
    fn checkBoundary(self: *Engine, n: *Note, prims: []const ot.Prim) !void {
        _ = self;
        if (prims.len == 0) return;
        const p = prims[0];
        const vis = n.seq.visible;
        const bad = struct {
            fn at(seq: *const rga.Seq, pos: usize) bool {
                return pos > 0 and pos < seq.visible and text.isLow(seq.unitAt(pos));
            }
        }.at;
        if (p.pos > vis) return;
        if (bad(&n.seq, p.pos)) return error.SplitsSurrogatePair;
        if (p.kind == .del and p.pos + p.len <= vis and bad(&n.seq, p.pos + p.len)) return error.SplitsSurrogatePair;
    }

    // ---------------------------------------------------------- local ops

    const Value = union(enum) { none, boolean: bool, folder: Id, string: []const u8 };

    fn nextStamp(self: *Engine, now: i64) Stamp {
        return .{ .t = @max(now, self.hlc + 1), .r = self.replica, .c = self.clock + 1 };
    }

    fn opHeader(w: *Writer, kind: []const u8, s: Stamp) !void {
        try w.print("{{\"v\":1,\"k\":\"{s}\",\"r\":\"{x:0>16}\",\"c\":{d},\"t\":{d}", .{ kind, s.r, s.c, s.t });
    }

    fn writeValue(w: *Writer, v: Value) !void {
        switch (v) {
            .none => try w.writeAll("null"),
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .folder => |f| try writeFolderId(w, f),
            .string => |s| try json.Stringify.encodeJsonString(s, .{}, w),
        }
    }

    /// Record a locally made op and apply it through the same path as remote ops.
    fn commit(self: *Engine, aw: *Writer.Allocating) !void {
        const op = aw.written();
        const parsed = try json.parseFromSlice(json.Value, self.gpa, op, .{});
        defer parsed.deinit();
        const result = try self.applyValue(parsed.value, null);
        std.debug.assert(result == .applied);
        if (self.new_ops.items.len > 0) try self.new_ops.append(self.gpa, ',');
        try self.new_ops.appendSlice(self.gpa, op);
    }

    fn localNoteCreate(self: *Engine, folder: ?Id, now: i64) !Id {
        const s = self.nextStamp(now);
        var aw = Writer.Allocating.init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try opHeader(w, "nc", s);
        try w.writeAll(",\"f\":");
        try writeValue(w, if (folder) |f| .{ .folder = f } else .none);
        try w.writeAll("}");
        try self.commit(&aw);
        return .{ .r = s.r, .c = s.c };
    }

    fn localInsert(self: *Engine, n: *Note, pos: usize, units: []const u16, now: i64) !void {
        if (units.len == 0) return;
        const s = self.nextStamp(now);
        const utf8 = try text.toUtf8(self.gpa, units);
        defer self.gpa.free(utf8);
        var aw = Writer.Allocating.init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try opHeader(w, "ins", s);
        try w.writeAll(",\"n\":");
        try writeNoteId(w, n.id);
        try w.writeAll(",\"o\":");
        if (n.seq.originFor(pos)) |o| try writeCharId(w, o) else try w.writeAll("null");
        try w.writeAll(",\"s\":");
        try json.Stringify.encodeJsonString(utf8, .{}, w);
        try w.writeAll("}");
        try self.commit(&aw);
    }

    fn localDelete(self: *Engine, n: *Note, pos: usize, len: usize, now: i64) !void {
        if (len == 0) return;
        var ranges: std.ArrayList(rga.Range) = .empty;
        defer ranges.deinit(self.gpa);
        try n.seq.rangesOf(self.gpa, pos, len, &ranges);
        const s = self.nextStamp(now);
        var aw = Writer.Allocating.init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try opHeader(w, "del", s);
        try w.writeAll(",\"n\":");
        try writeNoteId(w, n.id);
        try w.writeAll(",\"d\":[");
        for (ranges.items, 0..) |r, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("[");
            try writeCharId(w, .{ .r = r.r, .c = r.c });
            try w.print(",{d}]", .{r.n});
        }
        try w.writeAll("]}");
        try self.commit(&aw);
    }

    fn localNoteSet(self: *Engine, note: Id, field: []const u8, v: Value, now: i64) !void {
        const s = self.nextStamp(now);
        var aw = Writer.Allocating.init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try opHeader(w, "ns", s);
        try w.writeAll(",\"n\":");
        try writeNoteId(w, note);
        try w.print(",\"p\":\"{s}\",\"x\":", .{field});
        try writeValue(w, v);
        try w.writeAll("}");
        try self.commit(&aw);
    }

    fn localFolderCreate(self: *Engine, name: []const u8, parent: ?Id, now: i64) !Id {
        const s = self.nextStamp(now);
        var aw = Writer.Allocating.init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try opHeader(w, "fc", s);
        try w.writeAll(",\"name\":");
        try json.Stringify.encodeJsonString(name, .{}, w);
        try w.writeAll(",\"parent\":");
        try writeValue(w, if (parent) |p| .{ .folder = p } else .none);
        try w.writeAll("}");
        try self.commit(&aw);
        return .{ .r = s.r, .c = s.c };
    }

    fn localFolderSet(self: *Engine, folder: Id, field: []const u8, v: Value, now: i64) !void {
        const s = self.nextStamp(now);
        var aw = Writer.Allocating.init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try opHeader(w, "fs", s);
        try w.writeAll(",\"f\":");
        try writeFolderId(w, folder);
        try w.print(",\"p\":\"{s}\",\"x\":", .{field});
        try writeValue(w, v);
        try w.writeAll("}");
        try self.commit(&aw);
    }

    // ------------------------------------------------------- applying ops

    const Applied = enum { applied, blocked, duplicate };

    fn ingestValue(self: *Engine, v: json.Value, w: *Writer) !void {
        const result = self.applyValue(v, w) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
            else => {
                try w.writeAll("{\"ev\":\"error\",\"error\":");
                try json.Stringify.encodeJsonString(errorText(err), .{}, w);
                try w.writeAll("}\n");
                return;
            },
        };
        if (result != .blocked) return;
        const id = try opId(v.object);
        for (self.pending.items) |p| if (p.id.eql(id)) return;
        const copy = try json.Stringify.valueAlloc(self.gpa, v, .{});
        errdefer self.gpa.free(copy);
        try self.pending.append(self.gpa, .{ .id = id, .op = copy });
    }

    fn retryPending(self: *Engine, w: *Writer) !void {
        var progress = true;
        while (progress) {
            progress = false;
            var i: usize = 0;
            while (i < self.pending.items.len) {
                const p = self.pending.items[i];
                const parsed = try json.parseFromSlice(json.Value, self.gpa, p.op, .{});
                defer parsed.deinit();
                const result = self.applyValue(parsed.value, w) catch |err| switch (err) {
                    error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
                    else => .duplicate, // cannot become valid later; drop it
                };
                if (result == .blocked) {
                    i += 1;
                    continue;
                }
                self.gpa.free(p.op);
                _ = self.pending.orderedRemove(i);
                progress = true;
            }
        }
    }

    /// Apply one op. `w` receives patch events for open notes; null for local ops.
    fn applyValue(self: *Engine, v: json.Value, w: ?*Writer) !Applied {
        const obj = switch (v) {
            .object => |o| o,
            else => return error.BadOp,
        };
        const ver = try getUint(obj, "v");
        if (ver != 1) return error.UnsupportedOpVersion;
        const id = try opId(obj);
        if (self.applied.contains(id)) return .duplicate;
        const t = try getInt(obj, "t");
        const kind = try getStr(obj, "k");
        const stamp: Stamp = .{ .t = t, .r = id.r, .c = id.c };
        const eql = std.mem.eql;

        var units_used: u64 = 1;
        if (eql(u8, kind, "nc")) {
            const folder = try optFolderRef(obj, "f");
            const n = try self.gpa.create(Note);
            errdefer self.gpa.destroy(n);
            n.* = .{ .id = id, .folder = .{ .value = folder, .stamp = stamp }, .created = t, .updated = t };
            try self.notes.put(self.gpa, id, n);
            try self.dirty_notes.put(self.gpa, id, {});
        } else if (eql(u8, kind, "ins")) {
            const n = self.notes.get(try parseNoteId(try getStr(obj, "n"))) orelse return .blocked;
            const origin: ?Id = switch (obj.get("o") orelse return error.BadOp) {
                .null => null,
                .string => |s| try parseCharId(s),
                else => return error.BadOp,
            };
            if (origin) |o| if (!n.seq.has(o)) return .blocked;
            const units = try text.toUtf16(self.gpa, try getStr(obj, "s"));
            defer self.gpa.free(units);
            if (units.len == 0) return error.BadOp;
            units_used = units.len;
            const pos = try n.seq.integrate(self.gpa, id, origin, units);
            n.updated = @max(n.updated, t);
            n.touched(self.gpa);
            try self.dirty_notes.put(self.gpa, n.id, {});
            if (w) |out| if (n.open) try self.emitPatch(n, ot.Prim.ins(pos, units, 0), out);
        } else if (eql(u8, kind, "del")) {
            const n = self.notes.get(try parseNoteId(try getStr(obj, "n"))) orelse return .blocked;
            const list = switch (obj.get("d") orelse return error.BadOp) {
                .array => |a| a,
                else => return error.BadOp,
            };
            var ranges: std.ArrayList(rga.Range) = .empty;
            defer ranges.deinit(self.gpa);
            for (list.items) |item| {
                const pair = switch (item) {
                    .array => |a| a,
                    else => return error.BadOp,
                };
                if (pair.items.len != 2) return error.BadOp;
                const start = try parseCharId(switch (pair.items[0]) {
                    .string => |s| s,
                    else => return error.BadOp,
                });
                const count: u64 = switch (pair.items[1]) {
                    .integer => |i| if (i > 0) @intCast(i) else return error.BadOp,
                    else => return error.BadOp,
                };
                try ranges.append(self.gpa, .{ .r = start.r, .c = start.c, .n = count });
            }
            for (ranges.items) |r| if (!n.seq.covers(r)) return .blocked;
            var segs: std.ArrayList(rga.Seg) = .empty;
            defer segs.deinit(self.gpa);
            for (ranges.items) |r| try n.seq.delete(self.gpa, r, &segs);
            n.updated = @max(n.updated, t);
            n.touched(self.gpa);
            try self.dirty_notes.put(self.gpa, n.id, {});
            if (w) |out| if (n.open) for (segs.items) |s| try self.emitPatch(n, ot.Prim.del(s.pos, s.len, 0), out);
        } else if (eql(u8, kind, "ns")) {
            const n = self.notes.get(try parseNoteId(try getStr(obj, "n"))) orelse return .blocked;
            const field = try getStr(obj, "p");
            const x = obj.get("x") orelse return error.BadOp;
            if (eql(u8, field, "folder")) {
                const f = try folderRefValue(x);
                if (stamp.greater(n.folder.stamp)) n.folder = .{ .value = f, .stamp = stamp };
            } else if (eql(u8, field, "pinned")) {
                const b = try asBool(x);
                if (stamp.greater(n.pinned.stamp)) n.pinned = .{ .value = b, .stamp = stamp };
            } else if (eql(u8, field, "trashed")) {
                const b = try asBool(x);
                if (stamp.greater(n.trashed.stamp)) n.trashed = .{ .value = b, .stamp = stamp };
            } else return error.BadOp;
            try self.dirty_notes.put(self.gpa, n.id, {});
        } else if (eql(u8, kind, "fc")) {
            const name = try self.gpa.dupe(u8, try getStr(obj, "name"));
            errdefer self.gpa.free(name);
            const parent = try optFolderRef(obj, "parent");
            const f = try self.gpa.create(Folder);
            errdefer self.gpa.destroy(f);
            f.* = .{ .id = id, .name = .{ .value = name, .stamp = stamp }, .parent = .{ .value = parent, .stamp = stamp } };
            try self.folders.put(self.gpa, id, f);
            try self.folderChanged(id);
        } else if (eql(u8, kind, "fs")) {
            const f = self.folders.get(try parseFolderId(try getStr(obj, "f"))) orelse return .blocked;
            const field = try getStr(obj, "p");
            const x = obj.get("x") orelse return error.BadOp;
            if (eql(u8, field, "name")) {
                const s = switch (x) {
                    .string => |s| s,
                    else => return error.BadOp,
                };
                if (stamp.greater(f.name.stamp)) {
                    const copy = try self.gpa.dupe(u8, s);
                    self.gpa.free(f.name.value);
                    f.name = .{ .value = copy, .stamp = stamp };
                }
            } else if (eql(u8, field, "parent")) {
                const p = try folderRefValue(x);
                if (stamp.greater(f.parent.stamp)) f.parent = .{ .value = p, .stamp = stamp };
            } else if (eql(u8, field, "deleted")) {
                const b = try asBool(x);
                if (stamp.greater(f.deleted.stamp)) f.deleted = .{ .value = b, .stamp = stamp };
            } else return error.BadOp;
            try self.folderChanged(f.id);
        } else return error.BadOp;

        try self.applied.put(self.gpa, id, {});
        self.clock = @max(self.clock, id.c + units_used - 1);
        self.hlc = @max(self.hlc, t);
        return .applied;
    }

    fn folderChanged(self: *Engine, folder: Id) !void {
        self.folders_dirty = true;
        // Notes filed there may change their effective folder.
        for (self.notes.values()) |n| {
            if (n.folder.value) |f| if (f.eql(folder)) try self.dirty_notes.put(self.gpa, n.id, {});
        }
    }

    fn emitPatch(self: *Engine, n: *Note, prim: ot.Prim, w: *Writer) !void {
        n.pseq += 1;
        var p = prim;
        p.tag = n.pseq;
        const all = try std.mem.concat(self.gpa, ot.Prim, &.{ n.unacked, &.{p} });
        defer self.gpa.free(all);
        try n.setUnacked(self.gpa, all);

        try w.writeAll("{\"ev\":\"patch\",\"note\":");
        try writeNoteId(w, n.id);
        try w.print(",\"base\":{d},\"pseq\":{d},\"pos\":{d},\"del\":{d},\"ins\":", .{
            n.last_seq, n.pseq, p.pos, if (p.kind == .del) p.len else 0,
        });
        if (p.kind == .ins) {
            const utf8 = try text.toUtf8(self.gpa, p.text);
            defer self.gpa.free(utf8);
            try json.Stringify.encodeJsonString(utf8, .{}, w);
        } else try w.writeAll("\"\"");
        try w.writeAll("}\n");
    }

    // ------------------------------------------------------ materializing

    const Tree = struct {
        /// Effective parent of every live folder.
        parent: std.AutoHashMapUnmanaged(Id, ?Id) = .empty,

        fn deinit(t: *Tree, gpa: Allocator) void {
            t.parent.deinit(gpa);
        }

        fn live(t: *const Tree, id: Id) bool {
            return t.parent.contains(id);
        }
    };

    fn stampLess(_: void, a: *Folder, b: *Folder) bool {
        return b.parent.stamp.greater(a.parent.stamp);
    }

    fn tree(self: *Engine) !Tree {
        const gpa = self.gpa;
        const all = try gpa.dupe(*Folder, self.folders.values());
        defer gpa.free(all);
        std.mem.sort(*Folder, all, {}, stampLess);

        var raw: std.AutoHashMapUnmanaged(Id, ?Id) = .empty;
        defer raw.deinit(gpa);
        for (all) |f| try raw.put(gpa, f.id, null);
        for (all) |f| {
            const want = f.parent.value orelse continue;
            if (!self.folders.contains(want)) continue;
            var cur: ?Id = want;
            var cycle = false;
            while (cur) |c| {
                if (c.eql(f.id)) {
                    cycle = true;
                    break;
                }
                cur = raw.get(c).?;
            }
            if (!cycle) try raw.put(gpa, f.id, want);
        }

        var t: Tree = .{};
        errdefer t.deinit(gpa);
        for (all) |f| {
            if (f.deleted.value) continue;
            var p = raw.get(f.id).?;
            while (p) |pid| {
                if (!self.folders.get(pid).?.deleted.value) break;
                p = raw.get(pid).?;
            }
            try t.parent.put(gpa, f.id, p);
        }
        return t;
    }

    fn isSelfOrDescendant(self: *Engine, candidate: Id, ancestor: Id) !bool {
        var t = try self.tree();
        defer t.deinit(self.gpa);
        var cur: ?Id = candidate;
        while (cur) |c| {
            if (c.eql(ancestor)) return true;
            cur = t.parent.get(c) orelse null;
        }
        return false;
    }

    fn noteLess(_: void, a: *Note, b: *Note) bool {
        if (a.updated != b.updated) return a.updated > b.updated;
        if (a.id.r != b.id.r) return a.id.r < b.id.r;
        return a.id.c < b.id.c;
    }

    fn folderLess(_: void, a: *Folder, b: *Folder) bool {
        switch (std.mem.order(u8, a.name.value, b.name.value)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        if (a.id.r != b.id.r) return a.id.r < b.id.r;
        return a.id.c < b.id.c;
    }

    fn writeSummary(self: *Engine, n: *Note, t: *const Tree, w: *Writer) !void {
        const utf8 = try n.textUtf8(self.gpa);
        try w.writeAll("{\"id\":");
        try writeNoteId(w, n.id);
        try w.writeAll(",\"title\":");
        try json.Stringify.encodeJsonString(text.title(utf8), .{}, w);
        const snip = try text.snippet(self.gpa, utf8);
        defer self.gpa.free(snip);
        try w.writeAll(",\"snippet\":");
        try json.Stringify.encodeJsonString(snip, .{}, w);
        try w.writeAll(",\"folder\":");
        const folder: ?Id = if (n.folder.value) |f| (if (t.live(f)) f else null) else null;
        try writeValue(w, if (folder) |f| .{ .folder = f } else .none);
        try w.writeAll(",\"tags\":[");
        const tags = try text.hashtags(self.gpa, utf8);
        defer text.freeTags(self.gpa, tags);
        for (tags, 0..) |tag, i| {
            if (i > 0) try w.writeAll(",");
            try json.Stringify.encodeJsonString(tag, .{}, w);
        }
        try w.print("],\"pinned\":{},\"trashed\":{},\"created\":{d},\"updated\":{d}}}", .{
            n.pinned.value, n.trashed.value, n.created, n.updated,
        });
    }

    fn writeFolders(self: *Engine, t: *const Tree, w: *Writer) !void {
        var live: std.ArrayList(*Folder) = .empty;
        defer live.deinit(self.gpa);
        for (self.folders.values()) |f| if (t.live(f.id)) try live.append(self.gpa, f);
        std.mem.sort(*Folder, live.items, {}, folderLess);
        try w.writeAll("[");
        for (live.items, 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"id\":");
            try writeFolderId(w, f.id);
            try w.writeAll(",\"name\":");
            try json.Stringify.encodeJsonString(f.name.value, .{}, w);
            try w.writeAll(",\"parent\":");
            const p = t.parent.get(f.id).?;
            try writeValue(w, if (p) |pid| .{ .folder = pid } else .none);
            try w.writeAll("}");
        }
        try w.writeAll("]");
    }

    fn sortedNotes(self: *Engine) ![]*Note {
        const all = try self.gpa.dupe(*Note, self.notes.values());
        std.mem.sort(*Note, all, {}, noteLess);
        return all;
    }

    fn writeList(self: *Engine, w: *Writer) !void {
        var t = try self.tree();
        defer t.deinit(self.gpa);
        const all = try self.sortedNotes();
        defer self.gpa.free(all);
        try w.writeAll(",\"notes\":[");
        for (all, 0..) |n, i| {
            if (i > 0) try w.writeAll(",");
            try self.writeSummary(n, &t, w);
        }
        try w.writeAll("],\"folders\":");
        try self.writeFolders(&t, w);
    }

    fn writeSearch(self: *Engine, q: []const u8, w: *Writer) !void {
        const needle = try self.gpa.dupe(u8, q);
        defer self.gpa.free(needle);
        text.foldCase(needle);
        const all = try self.sortedNotes();
        defer self.gpa.free(all);
        try w.writeAll(",\"ids\":[");
        var first = true;
        for (all) |n| {
            if (!try text.containsFolded(self.gpa, try n.textUtf8(self.gpa), needle)) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try writeNoteId(w, n.id);
        }
        try w.writeAll("]");
    }

    fn flushEvents(self: *Engine, w: *Writer) !void {
        if (self.dirty_notes.count() == 0 and !self.folders_dirty) return;
        var t = try self.tree();
        defer t.deinit(self.gpa);
        if (self.dirty_notes.count() > 0) {
            try w.writeAll("{\"ev\":\"notes\",\"upsert\":[");
            var first = true;
            for (self.dirty_notes.keys()) |id| {
                const n = self.notes.get(id) orelse continue;
                if (!first) try w.writeAll(",");
                first = false;
                try self.writeSummary(n, &t, w);
            }
            try w.writeAll("]}\n");
            self.dirty_notes.clearRetainingCapacity();
        }
        if (self.folders_dirty) {
            try w.writeAll("{\"ev\":\"folders\",\"folders\":");
            try self.writeFolders(&t, w);
            try w.writeAll("}\n");
            self.folders_dirty = false;
        }
    }

    // ------------------------------------------------------------ lookups

    fn getNote(self: *Engine, obj: json.ObjectMap, key: []const u8) !*Note {
        const id = parseNoteId(try getStr(obj, key)) catch return error.UnknownNote;
        return self.notes.get(id) orelse error.UnknownNote;
    }

    fn getLiveFolder(self: *Engine, obj: json.ObjectMap, key: []const u8) !*Folder {
        const id = parseFolderId(try getStr(obj, key)) catch return error.UnknownFolder;
        const f = self.folders.get(id) orelse return error.UnknownFolder;
        var t = try self.tree();
        defer t.deinit(self.gpa);
        if (!t.live(id)) return error.UnknownFolder;
        return f;
    }

    /// A folder id or null; a non-null id must name a live folder.
    fn optLiveFolder(self: *Engine, obj: json.ObjectMap, key: []const u8) !?Id {
        const v = obj.get(key) orelse return null;
        switch (v) {
            .null => return null,
            .string => return (try self.getLiveFolder(obj, key)).id,
            else => return error.BadRequest,
        }
    }
};

// -------------------------------------------------------------- helpers

fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.BadRequest => "bad request",
        error.UnknownCommand => "unknown command",
        error.UnknownNote => "unknown note",
        error.UnknownFolder => "unknown folder",
        error.OutOfRange => "position out of range",
        error.SplitsSurrogatePair => "position splits a surrogate pair",
        error.InvalidUtf8 => "invalid UTF-8",
        error.FolderCycle => "a folder cannot move into itself",
        error.NotHandledByEngine => "handled by the daemon, not the engine",
        error.BadOp, error.BadId => "malformed op",
        error.UnsupportedOpVersion => "unsupported op version",
        else => @errorName(err),
    };
}

fn writeError(w: *Writer, id: i64, msg: []const u8) !void {
    try w.print("{{\"re\":{d},\"ok\":false,\"error\":", .{id});
    try json.Stringify.encodeJsonString(msg, .{}, w);
    try w.writeAll("}\n");
}

fn getStr(obj: json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (obj.get(key) orelse return error.BadRequest) {
        .string => |s| s,
        else => error.BadRequest,
    };
}

fn getInt(obj: json.ObjectMap, key: []const u8) !i64 {
    return switch (obj.get(key) orelse return error.BadRequest) {
        .integer => |i| i,
        else => error.BadRequest,
    };
}

fn getUint(obj: json.ObjectMap, key: []const u8) !u64 {
    const i = try getInt(obj, key);
    if (i < 0) return error.BadRequest;
    return @intCast(i);
}

fn getUsize(obj: json.ObjectMap, key: []const u8) !usize {
    return std.math.cast(usize, try getUint(obj, key)) orelse error.OutOfRange;
}

fn asBool(v: json.Value) !bool {
    return switch (v) {
        .bool => |b| b,
        else => error.BadRequest,
    };
}

fn opId(obj: json.ObjectMap) !Id {
    const r = std.fmt.parseInt(u64, try getStr(obj, "r"), 16) catch return error.BadOp;
    return .{ .r = r, .c = try getUint(obj, "c") };
}

fn optFolderRef(obj: json.ObjectMap, key: []const u8) !?Id {
    return folderRefValue(obj.get(key) orelse return error.BadOp);
}

fn folderRefValue(v: json.Value) !?Id {
    return switch (v) {
        .null => null,
        .string => |s| try parseFolderId(s),
        else => error.BadOp,
    };
}

/// "<hex16>-<counter>"
fn parseCharId(s: []const u8) !Id {
    const dash = std.mem.findScalar(u8, s, '-') orelse return error.BadId;
    return .{
        .r = std.fmt.parseInt(u64, s[0..dash], 16) catch return error.BadId,
        .c = std.fmt.parseInt(u64, s[dash + 1 ..], 10) catch return error.BadId,
    };
}

fn parsePrefixed(s: []const u8, prefix: []const u8) !Id {
    if (!std.mem.startsWith(u8, s, prefix)) return error.BadId;
    return parseCharId(s[prefix.len..]);
}

pub fn parseNoteId(s: []const u8) !Id {
    return parsePrefixed(s, "n-");
}

pub fn parseFolderId(s: []const u8) !Id {
    return parsePrefixed(s, "f-");
}

fn writeCharId(w: *Writer, id: Id) !void {
    try w.print("\"{x:0>16}-{d}\"", .{ id.r, id.c });
}

fn writeNoteId(w: *Writer, id: Id) !void {
    try w.print("\"n-{x:0>16}-{d}\"", .{ id.r, id.c });
}

fn writeFolderId(w: *Writer, id: Id) !void {
    try w.print("\"f-{x:0>16}-{d}\"", .{ id.r, id.c });
}

test {
    _ = @import("engine_test.zig");
}
