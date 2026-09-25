//! Ctrl+V on the desktop (docs/PROTOCOL.md §1 `paste`, spikes/paste/REPORT.md).
//! Reads the Wayland clipboard with wl-paste and turns it into markdown,
//! storing images and files as content-addressed attachments.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const attachments = @import("attachments.zig");
const html_md = @import("core").html_md;

pub const max_text_bytes: usize = 8 << 20;
pub const max_types_bytes: usize = 64 * 1024;
const clipboard_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };

pub const Paster = struct {
    gpa: Allocator,
    io: Io,
    att_dir: Io.Dir,
    /// For downloading remote images referenced by pasted HTML/markdown.
    http: *std.http.Client,
    /// Names of attachments stored by this paste (caller queues uploads).
    stored: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Paster) void {
        for (self.stored.items) |s| self.gpa.free(s);
        self.stored.deinit(self.gpa);
    }

    /// The markdown to insert for the current clipboard ("" if it is empty).
    pub fn paste(self: *Paster) ![]u8 {
        const types_raw = self.run(&.{ "wl-paste", "--list-types" }, max_types_bytes) catch |err| switch (err) {
            error.ClipboardEmpty => return self.gpa.dupe(u8, ""),
            else => return err,
        };
        defer self.gpa.free(types_raw);
        var types: std.ArrayList([]const u8) = .empty;
        defer types.deinit(self.gpa);
        var it = std.mem.tokenizeScalar(u8, types_raw, '\n');
        while (it.next()) |t| try types.append(self.gpa, std.mem.trim(u8, t, " \r"));
        const choice = choose(types.items) orelse return self.gpa.dupe(u8, "");

        switch (choice.kind) {
            .image => {
                const bytes = try self.run(&.{ "wl-paste", "--no-newline", "--type", choice.mime }, attachments.max_bytes);
                defer self.gpa.free(bytes);
                const ext = attachments.sniffExt(bytes) orelse attachments.extForMime(choice.mime);
                const name = try self.store(bytes, ext);
                return std.fmt.allocPrint(self.gpa, "![](attachments/{s})", .{name.slice()});
            },
            .uri_list => {
                const text = try self.run(&.{ "wl-paste", "--no-newline", "--type", choice.mime }, max_text_bytes);
                defer self.gpa.free(text);
                return self.files(text);
            },
            .markdown => {
                const text = try self.run(&.{ "wl-paste", "--no-newline", "--type", choice.mime }, max_text_bytes);
                defer self.gpa.free(text);
                return self.localizeImages(text);
            },
            .html => {
                const html = try self.run(&.{ "wl-paste", "--no-newline", "--type", choice.mime }, max_text_bytes);
                defer self.gpa.free(html);
                const md = try html_md.convert(self.gpa, html);
                defer self.gpa.free(md);
                return self.localizeImages(md);
            },
            .plain => return self.run(&.{ "wl-paste", "--no-newline", "--type", choice.mime }, max_text_bytes),
        }
    }

    fn run(self: *Paster, argv: []const []const u8, limit: usize) ![]u8 {
        const result = std.process.run(self.gpa, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(limit),
            .stderr_limit = .limited(4096),
            .timeout = clipboard_timeout,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.WlPasteMissing,
            else => return err,
        };
        defer self.gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                self.gpa.free(result.stdout);
                // wl-paste exits 1 with "Nothing is copied" / "No selection".
                return error.ClipboardEmpty;
            },
            else => {
                self.gpa.free(result.stdout);
                return error.WlPasteFailed;
            },
        }
        return result.stdout;
    }

    fn store(self: *Paster, bytes: []const u8, ext: []const u8) !attachments.Name {
        const name = try attachments.store(self.io, self.att_dir, bytes, ext);
        try self.stored.append(self.gpa, try self.gpa.dupe(u8, name.slice()));
        return name;
    }

    /// `text/uri-list`: copy each local file in; images become image links.
    fn files(self: *Paster, text: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const path = try fileUriPath(self.gpa, line) orelse continue;
            defer self.gpa.free(path);
            const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(attachments.max_bytes)) catch continue;
            defer self.gpa.free(bytes);
            const base = std.fs.path.basename(path);
            const dot = std.mem.findScalarLast(u8, base, '.');
            const ext = attachments.sniffExt(bytes) orelse if (dot) |d| attachments.normalizeExt(base[d + 1 ..]) else "bin";
            const name = try self.store(bytes, ext);
            if (out.items.len > 0) try out.append(self.gpa, '\n');
            const is_image = attachments.sniffExt(bytes) != null and !std.mem.eql(u8, ext, "pdf");
            try out.print(self.gpa, "{s}[{s}](attachments/{s})", .{ if (is_image) "!" else "", base, name.slice() });
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Rewrite `![alt](url)` so data:, file:// and http(s) images become
    /// local attachments. Anything that fails keeps its original URL.
    pub fn localizeImages(self: *Paster, md: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        var i: usize = 0;
        while (std.mem.findPos(u8, md, i, "![")) |bang| {
            const close = std.mem.findPos(u8, md, bang + 2, "](") orelse break;
            const url_start = close + 2;
            var url_end = url_start;
            while (url_end < md.len and md[url_end] != ')' and md[url_end] != ' ' and md[url_end] != '\n') url_end += 1;
            try out.appendSlice(self.gpa, md[i..url_start]);
            const url = md[url_start..url_end];
            if (self.localize(url)) |name| {
                try out.print(self.gpa, "attachments/{s}", .{name.slice()});
            } else |_| {
                try out.appendSlice(self.gpa, url);
            }
            i = url_end;
        }
        try out.appendSlice(self.gpa, md[i..]);
        return out.toOwnedSlice(self.gpa);
    }

    fn localize(self: *Paster, url: []const u8) !attachments.Name {
        if (std.mem.startsWith(u8, url, "data:")) {
            const comma = std.mem.findScalar(u8, url, ',') orelse return error.NotLocalizable;
            const meta = url[5..comma];
            if (!std.mem.endsWith(u8, meta, ";base64")) return error.NotLocalizable;
            const mime = meta[0 .. meta.len - ";base64".len];
            const decoder = std.base64.standard.Decoder;
            const payload = url[comma + 1 ..];
            const size = try decoder.calcSizeForSlice(payload);
            if (size > attachments.max_bytes) return error.AttachmentTooLarge;
            const bytes = try self.gpa.alloc(u8, size);
            defer self.gpa.free(bytes);
            try decoder.decode(bytes, payload);
            return self.store(bytes, attachments.sniffExt(bytes) orelse attachments.extForMime(mime));
        }
        if (std.mem.startsWith(u8, url, "file://")) {
            const path = try fileUriPath(self.gpa, url) orelse return error.NotLocalizable;
            defer self.gpa.free(path);
            const bytes = try Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(attachments.max_bytes));
            defer self.gpa.free(bytes);
            const dot = std.mem.findScalarLast(u8, path, '.');
            return self.store(bytes, attachments.sniffExt(bytes) orelse if (dot) |d| attachments.normalizeExt(path[d + 1 ..]) else "bin");
        }
        if (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) {
            var body: Io.Writer.Allocating = .init(self.gpa);
            defer body.deinit();
            const result = try self.http.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
            if (result.status != .ok) return error.DownloadFailed;
            const bytes = body.written();
            if (bytes.len > attachments.max_bytes) return error.AttachmentTooLarge;
            const ext = attachments.sniffExt(bytes) orelse return error.NotAnImage;
            return self.store(bytes, ext);
        }
        return error.NotLocalizable;
    }
};

pub const Kind = enum { image, uri_list, markdown, html, plain };
pub const Choice = struct { kind: Kind, mime: []const u8 };

/// Our priority, independent of the order wl-paste lists the types in.
pub fn choose(types: []const []const u8) ?Choice {
    for (types) |t| if (std.mem.startsWith(u8, t, "image/")) return .{ .kind = .image, .mime = t };
    for (types) |t| if (std.mem.eql(u8, t, "text/uri-list")) return .{ .kind = .uri_list, .mime = t };
    for (types) |t| if (std.mem.startsWith(u8, t, "text/markdown")) return .{ .kind = .markdown, .mime = t };
    for (types) |t| if (std.mem.startsWith(u8, t, "text/html")) return .{ .kind = .html, .mime = t };
    const plain = [_][]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT" };
    for (plain) |p| for (types) |t| if (std.mem.eql(u8, t, p)) return .{ .kind = .plain, .mime = t };
    return null;
}

/// `file:///a%20b/c.png` → "/a b/c.png" (caller frees); null for other schemes.
pub fn fileUriPath(gpa: Allocator, uri: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, uri, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "file://")) return null;
    var rest = trimmed["file://".len..];
    // Skip an optional host ("file://localhost/…").
    if (rest.len > 0 and rest[0] != '/') rest = rest[(std.mem.findScalar(u8, rest, '/') orelse return null)..];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const byte = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch {
                try out.append(gpa, '%');
                continue;
            };
            try out.append(gpa, byte);
            i += 2;
        } else try out.append(gpa, rest[i]);
    }
    return try out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "choose follows omajot's priority, not the listed order" {
    // Chromium "Copy image" lists text/html before image/png.
    try testing.expectEqual(Kind.image, choose(&.{ "text/x-moz-url", "text/html", "image/png" }).?.kind);
    // LibreOffice offers markdown next to html and rtf.
    try testing.expectEqual(Kind.markdown, choose(&.{ "text/rtf", "text/html", "text/markdown", "text/plain;charset=utf-8" }).?.kind);
    try testing.expectEqual(Kind.html, choose(&.{ "text/plain", "text/html" }).?.kind);
    try testing.expectEqualStrings("text/plain;charset=utf-8", choose(&.{ "TEXT", "text/plain;charset=utf-8" }).?.mime);
    try testing.expectEqual(Kind.uri_list, choose(&.{ "x-special/gnome-copied-files", "text/uri-list", "text/plain" }).?.kind);
    try testing.expect(choose(&.{"application/x-weird"}) == null);
}

test "fileUriPath" {
    const p = (try fileUriPath(testing.allocator, "file:///tmp/a%20b.png")).?;
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/tmp/a b.png", p);
    const h = (try fileUriPath(testing.allocator, "file://localhost/x.txt")).?;
    defer testing.allocator.free(h);
    try testing.expectEqualStrings("/x.txt", h);
    try testing.expect(try fileUriPath(testing.allocator, "https://x") == null);
}

test "localizeImages turns data: and file:// images into attachments" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    var p: Paster = .{ .gpa = testing.allocator, .io = testing.io, .att_dir = tmp.dir, .http = &client };
    defer p.deinit();
    // 1x1 PNG.
    const png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
    const md = "a ![x](data:image/png;base64," ++ png_b64 ++ ") b ![y](nowhere.png \"t\")";
    const out = try p.localizeImages(md);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "a ![x](attachments/"));
    try testing.expect(std.mem.endsWith(u8, out, ".png) b ![y](nowhere.png \"t\")"));
    try testing.expectEqual(@as(usize, 1), p.stored.items.len);
}
