//! Times for people: local time from the TZif zone (/etc/localtime or $TZ),
//! and the time arguments of `cat --at` and `restore`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const epoch = std.time.epoch;

pub const Zone = struct {
    tz: ?std.tz.Tz = null,

    /// The local zone; UTC when none can be read.
    pub fn load(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Zone {
        var path_buf: [512]u8 = undefined;
        const path = blk: {
            if (env.get("TZ")) |tz| {
                const name = std.mem.trimStart(u8, tz, ":");
                if (name.len == 0 or std.mem.eql(u8, name, "UTC")) return .{};
                if (name[0] == '/') break :blk name;
                break :blk std.fmt.bufPrint(&path_buf, "/usr/share/zoneinfo/{s}", .{name}) catch return .{};
            }
            break :blk "/etc/localtime";
        };
        const file = Io.Dir.cwd().openFile(io, path, .{}) catch return .{};
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var r = file.reader(io, &buf);
        const tz = std.tz.Tz.parse(gpa, &r.interface) catch return .{};
        return .{ .tz = tz };
    }

    pub fn deinit(z: *Zone) void {
        if (z.tz) |*t| t.deinit();
    }

    /// Seconds east of UTC at `t_s` (Unix seconds).
    pub fn offset(z: *const Zone, t_s: i64) i32 {
        const tz = z.tz orelse return 0;
        var off: i32 = if (tz.timetypes.len > 0) tz.timetypes[0].offset else 0;
        for (tz.transitions) |tr| {
            if (tr.ts > t_s) break;
            off = tr.timetype.offset;
        }
        return off;
    }
};

pub const Civil = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8 };

fn civil(t_s: i64) Civil {
    const secs: u64 = @intCast(@max(t_s, 0));
    const es: epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .year = yd.year,
        .month = md.month.numeric(),
        .day = @as(u8, md.day_index) + 1,
        .hour = ds.getHoursIntoDay(),
        .minute = ds.getMinutesIntoHour(),
        .second = ds.getSecondsIntoMinute(),
    };
}

/// "2026-09-26 14:03" in the local zone.
pub fn local(buf: []u8, zone: *const Zone, t_ms: i64) []const u8 {
    const t_s = @divFloor(t_ms, 1000);
    const c = civil(t_s + zone.offset(t_s));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ c.year, c.month, c.day, c.hour, c.minute }) catch buf[0..0];
}

/// "2026-09-26T12:03:05Z".
pub fn isoUtc(buf: []u8, t_ms: i64) []const u8 {
    const c = civil(@divFloor(t_ms, 1000));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ c.year, c.month, c.day, c.hour, c.minute, c.second }) catch buf[0..0];
}

/// "5 min ago", "3 h ago", "2 days ago".
pub fn ago(buf: []u8, now_ms: i64, t_ms: i64) []const u8 {
    const s = @divFloor(now_ms - t_ms, 1000);
    if (s < 60) return "just now";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d} min ago", .{@divFloor(s, 60)}) catch "";
    if (s < 86400) return std.fmt.bufPrint(buf, "{d} h ago", .{@divFloor(s, 3600)}) catch "";
    return std.fmt.bufPrint(buf, "{d} days ago", .{@divFloor(s, 86400)}) catch "";
}

fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    // Howard Hinnant's algorithm.
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const ParseError = error{BadTime};

/// A point in time (ms) from: Unix ms (13+ digits), "YYYY-MM-DD[ |T]HH:MM[:SS][Z]"
/// (local time unless it ends in Z), "YYYY-MM-DD" (local midnight), or a
/// duration ago: "90s", "15m", "2h", "3d", "1w".
pub fn parse(s: []const u8, now_ms: i64, zone: *const Zone) ParseError!i64 {
    if (s.len == 0) return error.BadTime;
    if (s.len >= 12 and allDigits(s)) return std.fmt.parseInt(i64, s, 10) catch error.BadTime;
    const unit = s[s.len - 1];
    if (s.len >= 2 and allDigits(s[0 .. s.len - 1]) and std.mem.findScalar(u8, "smhdw", unit) != null) {
        const n = std.fmt.parseInt(i64, s[0 .. s.len - 1], 10) catch return error.BadTime;
        const mult: i64 = switch (unit) {
            's' => 1000,
            'm' => 60_000,
            'h' => 3_600_000,
            'd' => 86_400_000,
            'w' => 7 * 86_400_000,
            else => unreachable,
        };
        return now_ms - n * mult;
    }
    // Calendar time.
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return error.BadTime;
    const y = num(s[0..4]) orelse return error.BadTime;
    const mo = num(s[5..7]) orelse return error.BadTime;
    const d = num(s[8..10]) orelse return error.BadTime;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return error.BadTime;
    var rest = s[10..];
    var h: i64 = 0;
    var mi: i64 = 0;
    var sec: i64 = 0;
    var utc = false;
    if (rest.len > 0) {
        if (rest[0] != ' ' and rest[0] != 'T') return error.BadTime;
        rest = rest[1..];
        if (rest.len > 0 and rest[rest.len - 1] == 'Z') {
            utc = true;
            rest = rest[0 .. rest.len - 1];
        }
        if (rest.len != 5 and rest.len != 8) return error.BadTime;
        if (rest[2] != ':') return error.BadTime;
        h = num(rest[0..2]) orelse return error.BadTime;
        mi = num(rest[3..5]) orelse return error.BadTime;
        if (rest.len == 8) {
            if (rest[5] != ':') return error.BadTime;
            sec = num(rest[6..8]) orelse return error.BadTime;
        }
        if (h > 23 or mi > 59 or sec > 60) return error.BadTime;
    }
    const as_utc = daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec;
    const t_s = if (utc) as_utc else as_utc - zone.offset(as_utc - zone.offset(as_utc));
    // The whole second: include every op in that second.
    return t_s * 1000 + 999;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn num(s: []const u8) ?i64 {
    if (!allDigits(s)) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

const testing = std.testing;

test "parse and format times" {
    const utc: Zone = .{};
    const now: i64 = 1_790_000_000_000;
    try testing.expectEqual(now - 15 * 60_000, try parse("15m", now, &utc));
    try testing.expectEqual(now - 2 * 86_400_000, try parse("2d", now, &utc));
    try testing.expectEqual(@as(i64, 1_790_000_000_123), try parse("1790000000123", now, &utc));
    const t = try parse("2026-09-26T12:03:05Z", now, &utc);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("2026-09-26T12:03:05Z", isoUtc(&buf, t));
    try testing.expectEqualStrings("2026-09-26 12:03", local(&buf, &utc, t));
    try testing.expectEqual(try parse("2026-09-26 12:03", now, &utc), try parse("2026-09-26T12:03:00Z", now, &utc));
    try testing.expectError(error.BadTime, parse("yesterday", now, &utc));
    try testing.expectError(error.BadTime, parse("2026-13-01", now, &utc));
    try testing.expectEqualStrings("3 h ago", ago(&buf, now, now - 3 * 3_600_000));
}
