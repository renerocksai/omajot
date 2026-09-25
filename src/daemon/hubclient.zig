//! HTTP access to the hub (docs/PROTOCOL.md §2) over std.http.Client, which
//! handles the Let's Encrypt `*.ts.net` certificate with the system CA bundle.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const blobs = @import("../hub/blobs.zig");

pub const max_response_bytes: usize = 32 << 20;

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: Response, gpa: Allocator) void {
        gpa.free(self.body);
    }
};

pub const Hub = struct {
    gpa: Allocator,
    io: Io,
    /// Without trailing slash, e.g. "https://host.tail.ts.net:8443".
    base: []const u8,
    client: std.http.Client,

    pub fn init(gpa: Allocator, io: Io, base: []const u8) Hub {
        return .{
            .gpa = gpa,
            .io = io,
            .base = std.mem.trimEnd(u8, base, "/"),
            .client = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(self: *Hub) void {
        self.client.deinit();
    }

    /// One request; the whole response body is returned (thread-safe).
    pub fn send(self: *Hub, method: std.http.Method, path: []const u8, payload: ?[]const u8, content_type: ?[]const u8) !Response {
        const url = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ self.base, path });
        defer self.gpa.free(url);
        var body: Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .response_writer = &body.writer,
            .headers = .{ .content_type = if (content_type) |ct| .{ .override = ct } else .default },
        });
        if (body.written().len > max_response_bytes) return error.ResponseTooLarge;
        return .{ .status = @intFromEnum(result.status), .body = try body.toOwnedSlice() };
    }

    /// Upload one attachment: a single PUT when it fits in one request
    /// body, else resumable chunks (`?offset=&total=`).
    pub fn putBlob(self: *Hub, name: []const u8, bytes: []const u8) !void {
        var path_buf: [192]u8 = undefined;
        if (bytes.len <= blobs.max_chunk_bytes) {
            const path = try std.fmt.bufPrint(&path_buf, "/api/blobs/{s}", .{name});
            const response = try self.send(.PUT, path, bytes, "application/octet-stream");
            defer response.deinit(self.gpa);
            if (response.status != 200 and response.status != 201) return error.UploadRejected;
            return;
        }
        var offset: usize = 0;
        var attempts: usize = 0;
        while (offset < bytes.len) {
            attempts += 1;
            if (attempts > 4 * (bytes.len / blobs.max_chunk_bytes + 2)) return error.UploadStuck;
            const end = @min(offset + blobs.max_chunk_bytes, bytes.len);
            const path = try std.fmt.bufPrint(&path_buf, "/api/blobs/{s}?offset={d}&total={d}", .{ name, offset, bytes.len });
            const response = try self.send(.PUT, path, bytes[offset..end], "application/octet-stream");
            defer response.deinit(self.gpa);
            switch (response.status) {
                200, 201 => return,
                202 => offset = end,
                409 => {
                    // Resume where the hub actually is.
                    const parsed = std.json.parseFromSlice(struct { received: u64 }, self.gpa, response.body, .{}) catch return error.UploadRejected;
                    defer parsed.deinit();
                    offset = @intCast(@min(parsed.value.received, bytes.len));
                },
                else => return error.UploadRejected,
            }
        }
    }

    /// Download an attachment; null if the hub doesn't have it (yet).
    pub fn getBlob(self: *Hub, name: []const u8) !?[]u8 {
        var path_buf: [192]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/api/blobs/{s}", .{name});
        const response = try self.send(.GET, path, null, null);
        if (response.status == 404) {
            response.deinit(self.gpa);
            return null;
        }
        if (response.status != 200) {
            response.deinit(self.gpa);
            return error.DownloadFailed;
        }
        return response.body;
    }

    /// Follow the SSE doorbell until the stream ends or fails. Calls
    /// `on_connect(ctx)` once the stream is open and `on_head(ctx, head)` per
    /// `head` event. A clean end returns normally; the caller reconnects.
    pub fn followEvents(self: *Hub, cursor: u64, ctx: anytype, comptime on_connect: fn (@TypeOf(ctx)) void, comptime on_head: fn (@TypeOf(ctx), u64) void) !void {
        const url = try std.fmt.allocPrint(self.gpa, "{s}/api/events", .{self.base});
        defer self.gpa.free(url);
        var id_buf: [24]u8 = undefined;
        const last_id = try std.fmt.bufPrint(&id_buf, "{d}", .{cursor});
        var request = try self.client.request(.GET, try std.Uri.parse(url), .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "Accept", .value = "text/event-stream" },
                .{ .name = "Last-Event-ID", .value = last_id },
            },
        });
        defer request.deinit();
        try request.sendBodiless();
        var redirect_buffer: [1024]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        if (response.head.status != .ok) return error.EventsRejected;
        on_connect(ctx);
        var transfer_buffer: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var event_name: [16]u8 = undefined;
        var event_len: usize = 0;
        var head: ?u64 = null;
        while (true) {
            const raw = (try reader.takeDelimiter('\n')) orelse return;
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) {
                // Dispatch the event.
                if (head) |h| if (std.mem.eql(u8, event_name[0..event_len], "head")) on_head(ctx, h);
                head = null;
                event_len = 0;
                continue;
            }
            if (std.mem.startsWith(u8, line, "event:")) {
                const name = std.mem.trim(u8, line["event:".len..], " ");
                event_len = @min(name.len, event_name.len);
                @memcpy(event_name[0..event_len], name[0..event_len]);
            } else if (std.mem.startsWith(u8, line, "id:")) {
                head = std.fmt.parseInt(u64, std.mem.trim(u8, line["id:".len..], " "), 10) catch null;
            }
        }
    }
};
