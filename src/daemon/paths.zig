//! Where the daemon keeps its data and its socket. `omajot daemon` and the
//! command line compute the same paths from the same flags and config, so a
//! command finds the daemon that owns a data directory.
//!
//!   data    --data, else "data" in the config, else $XDG_DATA_HOME/omajot
//!           or ~/.local/share/omajot
//!   socket  --socket, else "socket" in the config, else
//!             $XDG_RUNTIME_DIR/omajot.sock          (default data directory)
//!             $XDG_RUNTIME_DIR/omajot-<hash>.sock   (other data directories)
//!             <data>/daemon.sock                     (no XDG_RUNTIME_DIR, e.g. macOS)
//!             $TMPDIR/omajot-<hash>.sock             (when <data> is too long)
//!   lock    <data>/daemon.lock: one daemon per data directory
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const lock_name = "daemon.lock";
pub const log_name = "daemon.log";

/// `config.json` in `$XDG_CONFIG_HOME/omajot` or `~/.config/omajot`; every field optional.
pub const Config = struct {
    hub: ?[]const u8 = null,
    data: ?[]const u8 = null,
    socket: ?[]const u8 = null,
};

/// The user's home: $HOME, else %USERPROFILE% (Windows usually has no HOME).
fn homeDir(env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("HOME")) |h| if (h.len > 0) return h;
    if (env.get("USERPROFILE")) |h| if (h.len > 0) return h;
    return null;
}

/// $XDG_CONFIG_HOME/omajot/config.json, else ~/.config/omajot/config.json;
/// on Windows %APPDATA%\omajot\config.json when neither XDG nor HOME is set.
pub fn configPath(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| if (xdg.len > 0) return std.fs.path.join(gpa, &.{ xdg, "omajot", "config.json" });
    if (builtin.os.tag == .windows and env.get("HOME") == null) {
        if (env.get("APPDATA")) |app| if (app.len > 0) return std.fs.path.join(gpa, &.{ app, "omajot", "config.json" });
    }
    const home = homeDir(env) orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".config", "omajot", "config.json" });
}

/// A missing file is an empty config; a malformed one is an error.
pub fn readConfig(arena: Allocator, io: Io, path: []const u8) !Config {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(Config, arena, bytes, .{ .ignore_unknown_fields = true });
}

/// Expand a leading `~/` against HOME.
pub fn expandHome(gpa: Allocator, env: *const std.process.Environ.Map, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = homeDir(env) orelse return error.NoHome;
        return std.fs.path.join(gpa, &.{ home, path[2..] });
    }
    return gpa.dupe(u8, path);
}

/// $XDG_DATA_HOME/omajot, else ~/.local/share/omajot; on Windows
/// %LOCALAPPDATA%\omajot when neither XDG nor HOME is set.
pub fn defaultDataDir(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| if (xdg.len > 0) return std.fs.path.join(gpa, &.{ xdg, "omajot" });
    if (builtin.os.tag == .windows and env.get("HOME") == null) {
        if (env.get("LOCALAPPDATA")) |local| if (local.len > 0) return std.fs.path.join(gpa, &.{ local, "omajot" });
    }
    const home = homeDir(env) orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".local", "share", "omajot" });
}

pub const Flags = struct {
    data: ?[]const u8 = null,
    socket: ?[]const u8 = null,
};

pub const Resolved = struct {
    config_path: []const u8,
    config: Config,
    /// Absolute; the directory exists.
    data: []const u8,
    /// Empty: no socket.
    socket: []const u8,
};

/// Resolve config, data directory (created if missing) and socket path.
/// Everything is allocated from `arena`.
pub fn resolve(arena: Allocator, io: Io, env: *const std.process.Environ.Map, flags: Flags) !Resolved {
    const config_path = try configPath(arena, env);
    const config = try readConfig(arena, io, config_path);
    const default_data = try defaultDataDir(arena, env);
    const data_rel = if (flags.data orelse config.data) |d| try expandHome(arena, env, d) else default_data;
    try Io.Dir.cwd().createDirPath(io, data_rel);
    const data = try Io.Dir.cwd().realPathFileAlloc(io, data_rel, arena);
    const socket = if (flags.socket orelse config.socket) |s|
        try expandHome(arena, env, s)
    else
        try defaultSocket(arena, io, env, data, default_data);
    return .{ .config_path = config_path, .config = config, .data = data, .socket = socket };
}

fn defaultSocket(arena: Allocator, io: Io, env: *const std.process.Environ.Map, data: []const u8, default_data: []const u8) ![]u8 {
    const is_default = blk: {
        const real = Io.Dir.cwd().realPathFileAlloc(io, default_data, arena) catch break :blk false;
        break :blk std.mem.eql(u8, real, data);
    };
    var hash_buf: [8]u8 = undefined;
    const hash = std.fmt.bufPrint(&hash_buf, "{x:0>8}", .{@as(u32, @truncate(std.hash.Wyhash.hash(0, data)))}) catch unreachable;
    if (env.get("XDG_RUNTIME_DIR")) |run| if (run.len > 0) {
        if (is_default) return std.fs.path.join(arena, &.{ run, "omajot.sock" });
        return std.fmt.allocPrint(arena, "{s}/omajot-{s}.sock", .{ run, hash });
    };
    const in_data = try std.fs.path.join(arena, &.{ data, "daemon.sock" });
    if (in_data.len < 100) return in_data;
    const tmp = env.get("TMPDIR") orelse "/tmp";
    return std.fmt.allocPrint(arena, "{s}/omajot-{s}.sock", .{ std.mem.trimEnd(u8, tmp, "/"), hash });
}

/// Contents of daemon.lock, written by the daemon that holds it.
pub const LockInfo = struct {
    pid: i64 = 0,
    socket: []const u8 = "",
    /// "plugin" (stdin/stdout, started by the Omarchy plugin) or "background"
    /// (started by a command; hands over to a plugin daemon on request).
    mode: []const u8 = "",
};

pub fn currentPid() i64 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        .macos, .ios, .freebsd, .netbsd, .openbsd => std.c.getpid(),
        else => 0,
    };
}

/// Set the file mode creation mask; returns the previous one (0 where unsupported).
pub fn setUmask(mask: u32) u32 {
    return switch (builtin.os.tag) {
        .linux => @truncate(std.os.linux.syscall1(.umask, mask)),
        .macos, .ios, .freebsd, .netbsd, .openbsd => @intCast(std.c.umask(@intCast(mask))),
        else => 0,
    };
}

const testing = std.testing;

test "resolve: flags win, default socket follows the data directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", root);
    try env.put("XDG_CONFIG_HOME", try std.fs.path.join(arena, &.{ root, "cfg" }));
    try env.put("XDG_DATA_HOME", try std.fs.path.join(arena, &.{ root, "share" }));
    try env.put("XDG_RUNTIME_DIR", "/run/user/1");

    const def = try resolve(arena, io, &env, .{});
    try testing.expectEqualStrings("/run/user/1/omajot.sock", def.socket);
    try testing.expect(std.mem.endsWith(u8, def.data, "/share/omajot"));

    const other = try resolve(arena, io, &env, .{ .data = "~/other" });
    try testing.expect(std.mem.startsWith(u8, other.socket, "/run/user/1/omajot-"));
    try testing.expect(!std.mem.eql(u8, other.socket, def.socket));

    const explicit = try resolve(arena, io, &env, .{ .data = "~/other", .socket = "~/s.sock" });
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "s.sock" }), explicit.socket);

    _ = env.swapRemove("XDG_RUNTIME_DIR");
    const mac = try resolve(arena, io, &env, .{ .data = "~/d" });
    try testing.expect(std.mem.endsWith(u8, mac.socket, "/d/daemon.sock") or std.mem.indexOf(u8, mac.socket, "omajot-") != null);
}

test "home falls back to USERPROFILE when HOME is missing (Windows)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(arena);
    try env.put("USERPROFILE", "/Users/someone");
    if (builtin.os.tag != .windows) {
        try testing.expectEqualStrings("/Users/someone/.config/omajot/config.json", try configPath(arena, &env));
        try testing.expectEqualStrings("/Users/someone/.local/share/omajot", try defaultDataDir(arena, &env));
    }
    var empty: std.process.Environ.Map = .init(arena);
    try testing.expectError(error.NoHome, configPath(arena, &empty));
}
