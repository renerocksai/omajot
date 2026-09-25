//! The commands' connection to the daemon: the client protocol
//! (docs/PROTOCOL.md §1) on the daemon's unix socket. Starts a background
//! daemon when none runs (unless --no-start).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const paths = @import("../daemon/paths.zig");
const daemon = @import("../daemon/daemon.zig");

pub const Options = struct {
    data: ?[]const u8 = null,
    socket: ?[]const u8 = null,
    hub: ?[]const u8 = null,
    no_hub: bool = false,
    no_start: bool = false,
};

pub const Error = error{
    /// The daemon answered `ok:false`; the message is in `Client.last_error`.
    Refused,
    /// No daemon, and none could be started.
    DaemonUnavailable,
    ConnectionLost,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    rbuf: [64 * 1024]u8 = undefined,
    wbuf: [64 * 1024]u8 = undefined,
    sr: Io.net.Stream.Reader = undefined,
    sw: Io.net.Stream.Writer = undefined,
    line: Io.Writer.Allocating,
    next_id: i64 = 1,
    /// The message of the last `ok:false` reply (valid until the next request).
    last_error: []u8 = &.{},
    /// Filled in by `open`: the daemon's data directory and socket.
    data: []const u8 = "",
    socket: []const u8 = "",
    /// How the connection came about, for messages.
    started: bool = false,

    pub fn deinit(c: *Client) void {
        c.stream.close(c.io);
        c.line.deinit();
        c.gpa.free(c.last_error);
        c.gpa.destroy(c);
    }

    /// Send `{"id":N,"cmd":cmd, …fields}` and return the reply object
    /// (allocated from `arena`). Events on the way are skipped.
    pub fn call(c: *Client, arena: Allocator, cmd: []const u8, fields: anytype) !json.ObjectMap {
        const id = c.next_id;
        c.next_id += 1;
        const w = &c.sw.interface;
        w.print("{{\"id\":{d},\"cmd\":", .{id}) catch return error.ConnectionLost;
        json.Stringify.encodeJsonString(cmd, .{}, w) catch return error.ConnectionLost;
        inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |f| {
            w.writeAll(",\"" ++ f.name ++ "\":") catch return error.ConnectionLost;
            json.Stringify.value(@field(fields, f.name), .{}, w) catch return error.ConnectionLost;
        }
        w.writeAll("}\n") catch return error.ConnectionLost;
        w.flush() catch return error.ConnectionLost;
        while (true) {
            const got = (daemon.readLine(&c.sr.interface, &c.line, std.math.maxInt(usize)) catch return error.ConnectionLost) orelse return error.ConnectionLost;
            if (!std.mem.startsWith(u8, got, "{\"re\":")) continue;
            const v = json.parseFromSliceLeaky(json.Value, arena, got, .{ .allocate = .alloc_always }) catch return error.ConnectionLost;
            const obj = switch (v) {
                .object => |o| o,
                else => continue,
            };
            const re = obj.get("re") orelse continue;
            if (re != .integer or re.integer != id) continue;
            const ok = obj.get("ok") orelse return error.ConnectionLost;
            if (ok == .bool and ok.bool) return obj;
            c.gpa.free(c.last_error);
            c.last_error = c.gpa.dupe(u8, if (obj.get("error")) |e| (if (e == .string) e.string else "error") else "error") catch &.{};
            return error.Refused;
        }
    }
};

fn tryConnect(io: Io, path: []const u8) ?Io.net.Stream {
    const addr = Io.net.UnixAddress.init(path) catch return null;
    return addr.connect(io) catch null;
}

/// Connect to the daemon of the data directory (starting one if needed) and
/// say hello. `where` comes from paths.resolve.
pub fn open(gpa: Allocator, io: Io, where: paths.Resolved, opts: Options, stderr_note: *std.ArrayList(u8)) !*Client {
    if (where.socket.len == 0) return error.DaemonUnavailable;
    var started = false;
    const stream = tryConnect(io, where.socket) orelse blk: {
        if (opts.no_start) return error.DaemonUnavailable;
        try startDaemon(gpa, io, where, opts);
        started = true;
        var waited: u32 = 0;
        while (waited < 200) : (waited += 1) {
            if (tryConnect(io, where.socket)) |s| break :blk s;
            io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
        stderr_note.print(gpa, "the daemon did not start; see {s}/{s}\n", .{ where.data, paths.log_name }) catch {};
        return error.DaemonUnavailable;
    };
    const c = try gpa.create(Client);
    c.* = .{ .gpa = gpa, .io = io, .stream = stream, .line = .init(gpa), .started = started };
    c.sr = stream.reader(io, &c.rbuf);
    c.sw = stream.writer(io, &c.wbuf);
    errdefer c.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const hello = try c.call(arena_state.allocator(), "hello", .{ .client = "cli" });
    const data = if (hello.get("data")) |d| (if (d == .string) d.string else "") else "";
    if (!std.mem.eql(u8, data, where.data)) {
        stderr_note.print(gpa, "the daemon on {s} uses {s}, not {s}\n", .{ where.socket, data, where.data }) catch {};
        return error.DaemonUnavailable;
    }
    return c;
}

fn startDaemon(gpa: Allocator, io: Io, where: paths.Resolved, opts: Options) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const exe = try std.process.executablePathAlloc(io, arena);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ exe, "daemon", "--background", "--data", where.data, "--socket", where.socket });
    if (opts.no_hub) try argv.append(arena, "--no-hub") else if (opts.hub) |h| try argv.appendSlice(arena, &.{ "--hub", h });

    var data_dir = try Io.Dir.cwd().openDir(io, where.data, .{});
    defer data_dir.close(io);
    const log = try data_dir.createFile(io, paths.log_name, .{});
    defer log.close(io);
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .{ .file = log },
        // Own process group: Ctrl+C in this terminal does not stop it.
        .pgid = if (@import("builtin").os.tag == .windows) null else 0,
    }) catch return error.DaemonUnavailable;
    // Not waited for: it outlives this command and stops when idle.
    _ = &child;
}
