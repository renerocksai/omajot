// From technologylab-ai/furhat-vershofen web/src/qrgen.zig (same author), with the
// v3 block-buffer overflow fixed in addEccAndInterleave.
//! Self-contained, dependency-free QR Code encoder.
//!
//! Scope (deliberately narrow — the only consumer is a terminal render of a
//! short ASCII URL):
//!   - Byte mode (8-bit) only.
//!   - Error-correction level M (qrencode's default; ~15% recovery).
//!   - Versions 1..10 (21x21 .. 57x57).
//!   - Full mask selection (all 8 masks scored by the 4 penalty rules).
//!   - No heap allocation: fixed-size buffers sized for the v10 worst case.
//!
//! The algorithm follows the Nayuki QR Code reference implementation.

const std = @import("std");

pub const Error = error{DataTooLong};

pub const QrCode = struct {
    size: usize, // modules per side (21..57)
    cells: [57][57]bool, // dark = true; only [0..size][0..size] valid
    reserved: [57][57]bool, // function/format modules (internal use)

    pub fn get(self: *const QrCode, x: usize, y: usize) bool {
        return self.cells[y][x];
    }

    fn setFunction(self: *QrCode, x: usize, y: usize, dark: bool) void {
        self.cells[y][x] = dark;
        self.reserved[y][x] = true;
    }
};

// Error-correction characteristics for level M, versions 1..10. The group
// structure (short/long blocks) is derived at runtime from these three fields
// (see addEccAndInterleave), so only the totals are tabulated here.
const VersionInfo = struct {
    total_data_cw: u16, // data codewords across all blocks
    ec_per_block: u8, // EC codewords per block
    num_blocks: u8, // number of EC blocks
};

const VERSIONS = [10]VersionInfo{
    .{ .total_data_cw = 16, .ec_per_block = 10, .num_blocks = 1 }, // v1
    .{ .total_data_cw = 28, .ec_per_block = 16, .num_blocks = 1 }, // v2
    .{ .total_data_cw = 44, .ec_per_block = 26, .num_blocks = 1 }, // v3
    .{ .total_data_cw = 64, .ec_per_block = 18, .num_blocks = 2 }, // v4
    .{ .total_data_cw = 86, .ec_per_block = 24, .num_blocks = 2 }, // v5
    .{ .total_data_cw = 108, .ec_per_block = 16, .num_blocks = 4 }, // v6
    .{ .total_data_cw = 124, .ec_per_block = 18, .num_blocks = 4 }, // v7
    .{ .total_data_cw = 154, .ec_per_block = 22, .num_blocks = 4 }, // v8
    .{ .total_data_cw = 182, .ec_per_block = 22, .num_blocks = 5 }, // v9
    .{ .total_data_cw = 216, .ec_per_block = 26, .num_blocks = 5 }, // v10
};

// Alignment-pattern center coordinates per version (level-independent).
const ALIGN_POS = [10][]const usize{
    &.{}, // v1: none
    &.{ 6, 18 },
    &.{ 6, 22 },
    &.{ 6, 26 },
    &.{ 6, 30 },
    &.{ 6, 34 },
    &.{ 6, 22, 38 },
    &.{ 6, 24, 42 },
    &.{ 6, 26, 46 },
    &.{ 6, 28, 50 },
};

// ---------------------------------------------------------------------------
// GF(256) arithmetic — primitive polynomial 0x11D.
// ---------------------------------------------------------------------------

const GF = blk: {
    @setEvalBranchQuota(2000);
    var exp = [_]u8{0} ** 256;
    var logt = [_]u8{0} ** 256;
    var x: u16 = 1;
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        exp[i] = @intCast(x);
        logt[@as(usize, @intCast(x))] = @intCast(i);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11D;
    }
    exp[255] = 1; // period is 255, so exp[255] == exp[0]
    break :blk .{ .exp = exp, .log = logt };
};

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    const s = @as(usize, GF.log[a]) + @as(usize, GF.log[b]);
    return GF.exp[s % 255];
}

// ---------------------------------------------------------------------------
// Reed-Solomon error correction.
// ---------------------------------------------------------------------------

/// Build the generator polynomial of the given degree (number of EC codewords).
fn rsComputeDivisor(degree: usize, result: []u8) void {
    @memset(result, 0);
    result[degree - 1] = 1;
    var root: u8 = 1;
    var i: usize = 0;
    while (i < degree) : (i += 1) {
        var j: usize = 0;
        while (j < degree) : (j += 1) {
            result[j] = gfMul(result[j], root);
            if (j + 1 < degree) result[j] ^= result[j + 1];
        }
        root = gfMul(root, 0x02);
    }
}

/// Compute the EC codewords (remainder of polynomial division) for `data`.
fn rsComputeRemainder(data: []const u8, generator: []const u8, result: []u8) void {
    const degree = generator.len;
    @memset(result, 0);
    for (data) |b| {
        const factor = b ^ result[0];
        var j: usize = 0;
        while (j + 1 < degree) : (j += 1) result[j] = result[j + 1];
        result[degree - 1] = 0;
        j = 0;
        while (j < degree) : (j += 1) result[j] ^= gfMul(generator[j], factor);
    }
}

// ---------------------------------------------------------------------------
// Data encoding (byte mode).
// ---------------------------------------------------------------------------

/// Smallest version 1..10 whose level-M byte capacity fits `len` bytes.
fn pickVersion(len: usize) ?u8 {
    var v: u8 = 1;
    while (v <= 10) : (v += 1) {
        const vinfo = VERSIONS[v - 1];
        const cc_bits: usize = if (v <= 9) 8 else 16;
        const need_bits = 4 + cc_bits + 8 * len;
        if (need_bits <= @as(usize, vinfo.total_data_cw) * 8) return v;
    }
    return null;
}

/// MSB-first bit writer over a pre-zeroed byte buffer.
const BitWriter = struct {
    buf: []u8,
    bit_len: usize = 0,

    fn writeBits(self: *BitWriter, value: u32, n: usize) void {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            const bit: u8 = @intCast((value >> @intCast(i)) & 1);
            if (bit != 0) {
                const byte_idx = self.bit_len >> 3;
                const bit_idx: u3 = @intCast(7 - (self.bit_len & 7));
                self.buf[byte_idx] |= (@as(u8, 1) << bit_idx);
            }
            self.bit_len += 1;
        }
    }
};

/// Emit the byte-mode segment + padding into `out` (which must be zeroed and
/// sized to `vinfo.total_data_cw`).
fn buildDataCodewords(data: []const u8, ver: u8, out: []u8) void {
    var bw = BitWriter{ .buf = out };
    bw.writeBits(0b0100, 4); // byte mode indicator
    const cc_bits: usize = if (ver <= 9) 8 else 16;
    bw.writeBits(@intCast(data.len), cc_bits);
    for (data) |b| bw.writeBits(b, 8);

    const cap_bits = out.len * 8;
    const term = @min(@as(usize, 4), cap_bits - bw.bit_len);
    bw.writeBits(0, term); // terminator
    while (bw.bit_len % 8 != 0) bw.writeBits(0, 1); // pad to byte boundary

    var pad: u8 = 0xEC;
    while (bw.bit_len < cap_bits) {
        bw.writeBits(pad, 8);
        pad = if (pad == 0xEC) 0x11 else 0xEC;
    }
}

/// Split data into EC blocks, compute each block's EC codewords, and interleave
/// data then EC codewords into `out`. Returns the total number of codewords.
fn addEccAndInterleave(data_cw: []const u8, vinfo: VersionInfo, out: []u8) usize {
    const num_blocks: usize = vinfo.num_blocks;
    const ec_len: usize = vinfo.ec_per_block;
    const raw_cw: usize = @as(usize, vinfo.total_data_cw) + ec_len * num_blocks;
    const num_short = num_blocks - raw_cw % num_blocks;
    const short_block_len = raw_cw / num_blocks; // includes EC codewords
    const block_total_len = short_block_len + 1; // every block padded to this
    const gap_col = short_block_len - ec_len; // skipped column for short blocks

    var generator: [30]u8 = undefined;
    rsComputeDivisor(ec_len, generator[0..ec_len]);

    // blocks[b]: data, optional pad (short blocks), then EC codewords.
    // 71 = the longest padded block: v3-M, one block of 70 codewords + 1.
    // (Upstream had 70 here, which overflowed for every v3 input.)
    var blocks: [5][71]u8 = std.mem.zeroes([5][71]u8);
    var k: usize = 0;
    var i: usize = 0;
    while (i < num_blocks) : (i += 1) {
        const data_len = gap_col + (if (i < num_short) @as(usize, 0) else 1);
        const dat = data_cw[k .. k + data_len];
        k += data_len;
        @memcpy(blocks[i][0..data_len], dat);
        rsComputeRemainder(dat, generator[0..ec_len], blocks[i][block_total_len - ec_len .. block_total_len]);
    }

    var idx: usize = 0;
    var col: usize = 0;
    while (col < block_total_len) : (col += 1) {
        var j: usize = 0;
        while (j < num_blocks) : (j += 1) {
            if (col == gap_col and j < num_short) continue; // skip short-block pad
            out[idx] = blocks[j][col];
            idx += 1;
        }
    }
    return idx;
}

// ---------------------------------------------------------------------------
// Module placement.
// ---------------------------------------------------------------------------

fn getBit(v: u32, i: usize) bool {
    return ((v >> @intCast(i)) & 1) != 0;
}

fn drawFinder(qr: *QrCode, cx: usize, cy: usize) void {
    const sz: isize = @intCast(qr.size);
    var dy: isize = -4;
    while (dy <= 4) : (dy += 1) {
        var dx: isize = -4;
        while (dx <= 4) : (dx += 1) {
            const dist = @max(@as(isize, @intCast(@abs(dx))), @as(isize, @intCast(@abs(dy))));
            const xx = @as(isize, @intCast(cx)) + dx;
            const yy = @as(isize, @intCast(cy)) + dy;
            if (xx >= 0 and yy >= 0 and xx < sz and yy < sz)
                qr.setFunction(@intCast(xx), @intCast(yy), dist != 2 and dist != 4);
        }
    }
}

fn drawAlignment(qr: *QrCode, cx: usize, cy: usize) void {
    var dy: isize = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: isize = -2;
        while (dx <= 2) : (dx += 1) {
            const dist = @max(@as(isize, @intCast(@abs(dx))), @as(isize, @intCast(@abs(dy))));
            qr.setFunction(
                @intCast(@as(isize, @intCast(cx)) + dx),
                @intCast(@as(isize, @intCast(cy)) + dy),
                dist != 1,
            );
        }
    }
}

/// Write the 15-bit format information (level M + mask) to both copies, plus
/// the always-dark module. Also marks these positions reserved.
fn drawFormatBits(qr: *QrCode, mask: u3) void {
    const sz = qr.size;
    const data_bits: u32 = mask; // EC level M == 0b00, so data == mask
    var rem: u32 = data_bits;
    var c: usize = 0;
    while (c < 10) : (c += 1) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    const bits: u32 = ((data_bits << 10) | rem) ^ 0x5412;

    // First copy, around the top-left finder.
    var i: usize = 0;
    while (i < 6) : (i += 1) qr.setFunction(8, i, getBit(bits, i));
    qr.setFunction(8, 7, getBit(bits, 6));
    qr.setFunction(8, 8, getBit(bits, 7));
    qr.setFunction(7, 8, getBit(bits, 8));
    i = 9;
    while (i < 15) : (i += 1) qr.setFunction(14 - i, 8, getBit(bits, i));

    // Second copy, split across the top-right and bottom-left finders.
    i = 0;
    while (i < 8) : (i += 1) qr.setFunction(sz - 1 - i, 8, getBit(bits, i));
    i = 8;
    while (i < 15) : (i += 1) qr.setFunction(8, sz - 15 + i, getBit(bits, i));
    qr.setFunction(8, sz - 8, true); // always-dark module
}

/// Write the 18-bit version information (v7..10 only) to both copies.
fn drawVersion(qr: *QrCode, ver: u8) void {
    if (ver < 7) return;
    const sz = qr.size;
    var rem: u32 = ver;
    var c: usize = 0;
    while (c < 12) : (c += 1) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    const bits: u32 = (@as(u32, ver) << 12) | rem;

    var i: usize = 0;
    while (i < 18) : (i += 1) {
        const bit = getBit(bits, i);
        const a = sz - 11 + i % 3;
        const b = i / 3;
        qr.setFunction(a, b, bit);
        qr.setFunction(b, a, bit);
    }
}

fn drawFunctionPatterns(qr: *QrCode, ver: u8) void {
    const sz = qr.size;

    // Timing patterns (drawn first; finders overwrite the overlapping ends).
    var i: usize = 0;
    while (i < sz) : (i += 1) {
        qr.setFunction(6, i, i % 2 == 0);
        qr.setFunction(i, 6, i % 2 == 0);
    }

    // Finder patterns + separators at three corners.
    drawFinder(qr, 3, 3);
    drawFinder(qr, sz - 4, 3);
    drawFinder(qr, 3, sz - 4);

    // Alignment patterns (v2+), skipping the three finder corners.
    const pos = ALIGN_POS[ver - 1];
    const n = pos.len;
    var a: usize = 0;
    while (a < n) : (a += 1) {
        var b: usize = 0;
        while (b < n) : (b += 1) {
            if ((a == 0 and b == 0) or (a == 0 and b == n - 1) or (a == n - 1 and b == 0)) continue;
            drawAlignment(qr, pos[a], pos[b]);
        }
    }

    // Reserve the format-info region (placeholder mask 0) and version info.
    drawFormatBits(qr, 0);
    drawVersion(qr, ver);
}

/// Fill the data region in the standard zigzag order, skipping reserved modules
/// and the vertical timing column.
fn drawCodewords(qr: *QrCode, data: []const u8) void {
    const sz: isize = @intCast(qr.size);
    var bit_index: usize = 0;
    var right: isize = sz - 1;
    while (right >= 1) : (right -= 2) {
        if (right == 6) right = 5; // skip the vertical timing column
        var vert: usize = 0;
        while (vert < qr.size) : (vert += 1) {
            var j: usize = 0;
            while (j < 2) : (j += 1) {
                const x: usize = @intCast(right - @as(isize, @intCast(j)));
                const upward = ((right + 1) & 2) == 0;
                const y = if (upward) qr.size - 1 - vert else vert;
                if (!qr.reserved[y][x] and bit_index < data.len * 8) {
                    qr.cells[y][x] = getBit(data[bit_index >> 3], 7 - (bit_index & 7));
                    bit_index += 1;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Masking.
// ---------------------------------------------------------------------------

fn maskBit(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (x / 3 + y / 2) % 2 == 0,
        5 => (x * y) % 2 + (x * y) % 3 == 0,
        6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
        7 => ((x + y) % 2 + (x * y) % 3) % 2 == 0,
    };
}

/// XOR the mask pattern onto non-reserved modules (self-inverse: calling twice
/// restores the original).
fn applyMask(qr: *QrCode, mask: u3) void {
    var y: usize = 0;
    while (y < qr.size) : (y += 1) {
        var x: usize = 0;
        while (x < qr.size) : (x += 1) {
            if (qr.reserved[y][x]) continue;
            if (maskBit(mask, x, y)) qr.cells[y][x] = !qr.cells[y][x];
        }
    }
}

const PAT_A = [11]bool{ true, false, true, true, true, false, true, false, false, false, false };
const PAT_B = [11]bool{ false, false, false, false, true, false, true, true, true, false, true };

fn penaltyScore(qr: *const QrCode) u64 {
    const sz = qr.size;
    var result: u64 = 0;
    const N1: u64 = 3;
    const N2: u64 = 3;
    const N3: u64 = 40;
    const N4: u64 = 10;

    // Rule 1: runs of >=5 same-color modules, in rows then columns.
    var y: usize = 0;
    while (y < sz) : (y += 1) {
        var run_color = qr.get(0, y);
        var run_len: usize = 1;
        var x: usize = 1;
        while (x < sz) : (x += 1) {
            const ccol = qr.get(x, y);
            if (ccol == run_color) {
                run_len += 1;
                if (run_len == 5) result += N1 else if (run_len > 5) result += 1;
            } else {
                run_color = ccol;
                run_len = 1;
            }
        }
    }
    var x: usize = 0;
    while (x < sz) : (x += 1) {
        var run_color = qr.get(x, 0);
        var run_len: usize = 1;
        var yy: usize = 1;
        while (yy < sz) : (yy += 1) {
            const ccol = qr.get(x, yy);
            if (ccol == run_color) {
                run_len += 1;
                if (run_len == 5) result += N1 else if (run_len > 5) result += 1;
            } else {
                run_color = ccol;
                run_len = 1;
            }
        }
    }

    // Rule 2: 2x2 blocks of one color.
    y = 0;
    while (y + 1 < sz) : (y += 1) {
        x = 0;
        while (x + 1 < sz) : (x += 1) {
            const ccol = qr.get(x, y);
            if (ccol == qr.get(x + 1, y) and ccol == qr.get(x, y + 1) and ccol == qr.get(x + 1, y + 1))
                result += N2;
        }
    }

    // Rule 3: finder-like 1:1:3:1:1 patterns with a 4-module quiet run.
    y = 0;
    while (y < sz) : (y += 1) {
        x = 0;
        while (x + 11 <= sz) : (x += 1) {
            var ma = true;
            var mb = true;
            var t: usize = 0;
            while (t < 11) : (t += 1) {
                const ccol = qr.get(x + t, y);
                if (ccol != PAT_A[t]) ma = false;
                if (ccol != PAT_B[t]) mb = false;
            }
            if (ma or mb) result += N3;
        }
    }
    x = 0;
    while (x < sz) : (x += 1) {
        y = 0;
        while (y + 11 <= sz) : (y += 1) {
            var ma = true;
            var mb = true;
            var t: usize = 0;
            while (t < 11) : (t += 1) {
                const ccol = qr.get(x, y + t);
                if (ccol != PAT_A[t]) ma = false;
                if (ccol != PAT_B[t]) mb = false;
            }
            if (ma or mb) result += N3;
        }
    }

    // Rule 4: deviation of dark-module proportion from 50%.
    var dark: usize = 0;
    y = 0;
    while (y < sz) : (y += 1) {
        x = 0;
        while (x < sz) : (x += 1) {
            if (qr.get(x, y)) dark += 1;
        }
    }
    const total: i64 = @intCast(sz * sz);
    const d: i64 = @intCast(dark);
    const val = d * 20 - total * 10;
    const diff: i64 = if (val < 0) -val else val;
    const k = @divTrunc(diff + total - 1, total) - 1;
    result += @as(u64, @intCast(k)) * N4;

    return result;
}

// ---------------------------------------------------------------------------
// Public entry point.
// ---------------------------------------------------------------------------

/// Byte mode, EC level M, versions 1..10, automatic best mask.
pub fn encode(data: []const u8) Error!QrCode {
    const ver = pickVersion(data.len) orelse return error.DataTooLong;
    const vinfo = VERSIONS[ver - 1];

    var data_cw = std.mem.zeroes([216]u8);
    buildDataCodewords(data, ver, data_cw[0..vinfo.total_data_cw]);

    var all_cw: [346]u8 = undefined;
    const total = addEccAndInterleave(data_cw[0..vinfo.total_data_cw], vinfo, &all_cw);

    var qr = QrCode{
        .size = 17 + 4 * @as(usize, ver),
        .cells = std.mem.zeroes([57][57]bool),
        .reserved = std.mem.zeroes([57][57]bool),
    };
    drawFunctionPatterns(&qr, ver);
    drawCodewords(&qr, all_cw[0..total]);

    // Try all 8 masks; keep the one with the lowest penalty.
    var best_mask: u3 = 0;
    var min_penalty: u64 = std.math.maxInt(u64);
    var m: u3 = 0;
    while (true) : (m += 1) {
        applyMask(&qr, m);
        drawFormatBits(&qr, m);
        const p = penaltyScore(&qr);
        if (p < min_penalty) {
            min_penalty = p;
            best_mask = m;
        }
        applyMask(&qr, m); // undo (XOR is self-inverse)
        if (m == 7) break;
    }
    applyMask(&qr, best_mask);
    drawFormatBits(&qr, best_mask);

    return qr;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "GF(256) arithmetic" {
    try std.testing.expectEqual(@as(u8, 1), GF.exp[0]);
    try std.testing.expectEqual(@as(u8, 2), GF.exp[1]);

    // antilog/log round-trip over all nonzero elements
    var i: usize = 1;
    while (i < 256) : (i += 1) {
        const a: u8 = @intCast(i);
        try std.testing.expectEqual(a, GF.exp[GF.log[a]]);
    }

    try std.testing.expectEqual(@as(u8, 4), gfMul(2, 2));
    try std.testing.expectEqual(@as(u8, 29), gfMul(2, 128)); // x^8 mod 0x11D
    try std.testing.expectEqual(@as(u8, 7), gfMul(7, 1));
    try std.testing.expectEqual(@as(u8, 0), gfMul(0, 5));
    try std.testing.expectEqual(gfMul(11, 23), gfMul(23, 11)); // commutative
}

test "Reed-Solomon HELLO WORLD vector" {
    // Data codewords for "HELLO WORLD" encoded as version 1, level M.
    const data = [_]u8{ 32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17 };
    var generator: [10]u8 = undefined;
    rsComputeDivisor(10, &generator);
    var ecc: [10]u8 = undefined;
    rsComputeRemainder(&data, &generator, &ecc);

    const expected = [_]u8{ 196, 35, 39, 119, 235, 215, 231, 226, 93, 23 };
    try std.testing.expectEqualSlices(u8, &expected, &ecc);
}

test "encode smoke test (tablet URL)" {
    const url = "http://192.168.1.123:8090/furhat_vershofen/tablet";
    const code = try encode(url);

    // 49-byte URL selects version 4 -> 33x33.
    try std.testing.expectEqual(@as(usize, 33), code.size);

    // Finder patterns at three corners.
    try std.testing.expect(code.get(0, 0)); // TL outer corner
    try std.testing.expect(code.get(3, 3)); // TL center
    try std.testing.expect(!code.get(1, 1)); // TL inner ring (light)
    try std.testing.expect(code.get(32, 0)); // TR outer corner
    try std.testing.expect(code.get(0, 32)); // BL outer corner
}

test "capacity boundary" {
    // v10-M holds 216 data codewords -> 213 bytes max in byte mode.
    var ok = [_]u8{'A'} ** 213;
    const code = try encode(&ok);
    try std.testing.expectEqual(@as(usize, 57), code.size); // v10

    var too_long = [_]u8{'A'} ** 214;
    try std.testing.expectError(error.DataTooLong, encode(&too_long));
}

test "every supported length encodes without overflow (all versions 1..10)" {
    var buf: [256]u8 = undefined;
    for (&buf, 0..) |*c, i| c.* = "abcdefghijklmnopqrstuvwxyz0123456789:/."[i % 39];
    var len: usize = 1;
    var last_size: usize = 0;
    while (len <= buf.len) : (len += 1) {
        const code = encode(buf[0..len]) catch |err| {
            try std.testing.expectEqual(error.DataTooLong, err);
            try std.testing.expect(len > 200); // v10-M holds 213 bytes
            break;
        };
        try std.testing.expect(code.size >= last_size and (code.size - 17) % 4 == 0);
        last_size = code.size;
    }
    try std.testing.expectEqual(@as(usize, 57), last_size);
}
