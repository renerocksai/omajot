//! The PWA's files, read once at startup and served from memory with baz's
//! borrowBody (the bytes live as long as the hub). `web/dist` is small.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_files = 512;
pub const max_file_bytes: usize = 32 << 20;
pub const max_total_bytes: usize = 128 << 20;

pub const Asset = struct { body: []const u8, content_type: []const u8 };

pub const Assets = struct {
    arena: std.heap.ArenaAllocator,
    /// Keyed by URL path, e.g. "/index.html", "/assets/app.js".
    map: std.StringHashMapUnmanaged(Asset) = .empty,
    root: []const u8 = "",

    pub fn empty(gpa: Allocator) Assets {
        return .{ .arena = .init(gpa) };
    }

    /// Load every regular file under `root` (skipping dotfiles).
    pub fn load(gpa: Allocator, io: Io, root: []const u8) !Assets {
        var self: Assets = .{ .arena = .init(gpa) };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.root = try arena.dupe(u8, root);
        var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        var total: usize = 0;
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.basename, ".")) continue;
            if (self.map.count() >= max_files) return error.TooManyFiles;
            const body = try entry.dir.readFileAlloc(io, entry.basename, arena, .limited(max_file_bytes));
            total += body.len;
            if (total > max_total_bytes) return error.WebDirTooLarge;
            const url = try std.fmt.allocPrint(arena, "/{s}", .{entry.path});
            // Windows-style separators never appear in URLs.
            std.mem.replaceScalar(u8, url, '\\', '/');
            try self.map.put(arena, url, .{ .body = body, .content_type = contentType(url) });
        }
        return self;
    }

    pub fn deinit(self: *Assets) void {
        self.arena.deinit();
    }

    /// Exact match, "/" → "/index.html", and SPA fallback to index.html for
    /// extension-less paths. Paths with an extension that do not exist are 404.
    pub fn lookup(self: *const Assets, path: []const u8) ?Asset {
        if (self.map.get(path)) |asset| return asset;
        if (std.mem.eql(u8, path, "/")) return self.map.get("/index.html");
        const last = path[(std.mem.findScalarLast(u8, path, '/') orelse 0)..];
        if (std.mem.findScalar(u8, last, '.') == null) return self.map.get("/index.html");
        return null;
    }
};

pub fn contentType(path: []const u8) []const u8 {
    const dot = std.mem.findScalarLast(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    const table = [_]struct { []const u8, []const u8 }{
        .{ "html", "text/html; charset=utf-8" },
        .{ "js", "text/javascript; charset=utf-8" },
        .{ "mjs", "text/javascript; charset=utf-8" },
        .{ "css", "text/css; charset=utf-8" },
        .{ "wasm", "application/wasm" },
        .{ "json", "application/json" },
        .{ "webmanifest", "application/manifest+json" },
        .{ "map", "application/json" },
        .{ "svg", "image/svg+xml" },
        .{ "png", "image/png" },
        .{ "jpg", "image/jpeg" },
        .{ "ico", "image/x-icon" },
        .{ "txt", "text/plain; charset=utf-8" },
        .{ "woff2", "font/woff2" },
        .{ "woff", "font/woff" },
    };
    for (table) |entry| if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    return "application/octet-stream";
}

const testing = std.testing;

test "load and lookup, including SPA fallback and content types" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "index.html", .data = "<!doctype html>" });
    try tmp.dir.createDirPath(testing.io, "assets");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets/core.wasm", .data = "\x00asm" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".hidden", .data = "x" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buf);
    var assets = try Assets.load(testing.allocator, testing.io, root_buf[0..root_len]);
    defer assets.deinit();

    try testing.expectEqualStrings("application/wasm", assets.lookup("/assets/core.wasm").?.content_type);
    try testing.expectEqualStrings("<!doctype html>", assets.lookup("/").?.body);
    try testing.expectEqualStrings("<!doctype html>", assets.lookup("/notes/some-id").?.body);
    try testing.expect(assets.lookup("/missing.js") == null);
    try testing.expect(assets.lookup("/.hidden") == null);
}
