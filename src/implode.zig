// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const bs = @import("./bitstream.zig");
const hm = @import("./huffman.zig");
const lz = @import("./lz77.zig");
const tables = @import("./tables.zig");
const bits_utils = @import("./bits.zig");

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;

const UINT8_MAX = math.maxInt(u8);
const UINT16_MAX = math.maxInt(u16);

const BUFFER_CAP = 32 * 1024;

pub const explode_stat_t: type = enum {
    HWEXPLODE_OK, // Explode was successful.
    HWEXPLODE_ERR, // Error in the input data.
};

pub const implode_state_t: type = struct {
    large_wnd: bool,
    lit_tree: bool,

    buffer: [BUFFER_CAP]struct {
        dist: u16, // Backref dist, or 0 for literals.
        litlen: u16, // Literal byte (dist=0) or backref length.
    },
    buffer_size: usize,
    buffer_flushed: bool,

    lit_freqs: [256]u16,
    dist_sym_freqs: [64]u16,
    len_sym_freqs: [64]u16,

    os: bs.ostream_t,
    lit_encoder: hm.huffman_encoder_t,
    len_encoder: hm.huffman_encoder_t,
    dist_encoder: hm.huffman_encoder_t,
};

fn max_dist(large_wnd: bool) usize {
    return if (large_wnd) 8192 else 4096;
}

fn max_len(lit_tree: bool) usize {
    return (if (lit_tree) @as(usize, 3) else @as(usize, 2)) + 63 + 255;
}

fn dist_sym(dist_arg: usize, large_wnd: bool) u32 {
    var dist: usize = dist_arg;

    assert(dist >= 1);
    assert(dist <= max_dist(large_wnd));

    dist -= 1;

    return @intCast(u32, (dist >> (if (large_wnd) @as(u6, 7) else @as(u6, 6))));
}

fn len_sym(len_arg: usize, lit_tree: bool) u32 {
    var len: usize = len_arg;

    assert(len >= (if (lit_tree) @as(usize, 3) else @as(usize, 2)));
    assert(len <= max_len(lit_tree));

    len -= (if (lit_tree) @as(usize, 3) else @as(usize, 2));

    if (len < 63) {
        return @intCast(u32, len);
    }

    return 63; // The remainder is in a separate byte.
}

fn write_lit(s: *implode_state_t, lit: u8) bool {
    // Literal marker bit.
    if (!bs.ostream_write(&s.os, 0x1, 1)) {
        return false;
    }

    if (s.lit_tree) {
        // Huffman coded literal.
        return bs.ostream_write(
            &s.os,
            s.lit_encoder.codewords[lit],
            s.lit_encoder.lengths[lit],
        );
    }

    // Raw literal.
    return bs.ostream_write(&s.os, lit, 8);
}

fn write_backref(s: *implode_state_t, dist: usize, len: usize) bool {
    var d: u32 = 0;
    var l: u32 = 0;
    var num_dist_bits: u6 = 0;
    var extra_len: usize = 0;

    d = dist_sym(dist, s.large_wnd);
    l = len_sym(len, s.lit_tree);

    // Backref marker bit.
    if (!bs.ostream_write(&s.os, 0x0, 1)) {
        return false;
    }

    // Lower dist bits.
    assert(dist >= 1);
    num_dist_bits = if (s.large_wnd) @as(u6, 7) else @as(u6, 6);
    if (!bs.ostream_write(&s.os, bits_utils.lsb(dist - 1, num_dist_bits), num_dist_bits)) {
        return false;
    }

    // Upper 6 dist bits, Huffman coded.
    if (!bs.ostream_write(&s.os, s.dist_encoder.codewords[d], s.dist_encoder.lengths[d])) {
        return false;
    }

    // Huffman coded length.
    if (!bs.ostream_write(&s.os, s.len_encoder.codewords[l], s.len_encoder.lengths[l])) {
        return false;
    }

    if (l == 63) {
        // Extra length byte.
        extra_len = len - 63 - (if (s.lit_tree) @as(usize, 3) else @as(usize, 2));
        assert(extra_len <= UINT8_MAX);
        if (!bs.ostream_write(&s.os, extra_len, 8)) {
            return false;
        }
    }

    return true;
}

const rle_t: type = struct {
    len: u8,
    num: u8,
};

fn write_huffman_code(
    os: *bs.ostream_t,
    codeword_lengths: [*]const u8,
    num_syms: usize,
) bool {
    var rle: [256]rle_t = undefined;
    var rle_size: usize = 0;
    var i: usize = 0;

    assert(num_syms > 0);
    assert(num_syms <= rle.len);

    // Run-length encode the codeword lengths.
    rle[0].len = codeword_lengths[0];
    rle[0].num = 1;
    rle_size = 1;

    i = 1;
    while (i < num_syms) : (i += 1) {
        if (rle[rle_size - 1].len == codeword_lengths[i] and
            rle[rle_size - 1].num < 16)
        {
            rle[rle_size - 1].num += 1;
            continue;
        }

        assert(rle_size < rle.len);
        rle[rle_size].len = codeword_lengths[i];
        rle[rle_size].num = 1;
        rle_size += 1;
    }

    // Write the number of run-length encoded lengths.
    assert(rle_size >= 1);
    if (!bs.ostream_write(os, rle_size - 1, 8)) {
        return false;
    }

    // Write the run-length encoded lengths.
    i = 0;
    while (i < rle_size) : (i += 1) {
        assert(rle[i].num >= 1 and rle[i].num <= 16);
        assert(rle[i].len >= 1 and rle[i].len <= 16);
        if (!bs.ostream_write(os, rle[i].len - 1, 4) or
            !bs.ostream_write(os, rle[i].num - 1, 4))
        {
            return false;
        }
    }

    return true;
}

fn init_encoder(e: *hm.huffman_encoder_t, freqs: [*]u16, n: usize) void {
    var i: usize = 0;
    var scale_factor: usize = 0;
    var freq_sum: u16 = 0;
    var zero_freqs: u16 = 0;

    assert(BUFFER_CAP <= UINT16_MAX); // "Frequency sum must be guaranteed to fit in 16 bits."

    freq_sum = 0;
    zero_freqs = 0;

    i = 0;
    while (i < n) : (i += 1) {
        freq_sum += freqs[i];
        zero_freqs += if (freqs[i] == 0) @as(u16, 1) else @as(u16, 0);
    }

    scale_factor = UINT16_MAX / (freq_sum + zero_freqs);
    assert(scale_factor >= 1);

    i = 0;
    while (i < n) : (i += 1) {
        if (freqs[i] == 0) {
            // The Huffman encoder was designed for Deflate, which
            // excludes zero-frequency symbols from the code. That
            // doesn't work with Implode, so enforce a minimum
            // frequency of one.
            freqs[i] = 1;
            continue;
        }

        // Scale up to emphasise difference to the zero-freq symbols.
        freqs[i] *= @intCast(u16, scale_factor);
        assert(freqs[i] >= 1);
    }

    hm.huffman_encoder_init(
        e,
        freqs,
        n,
        16, //max_codeword_len=16
    );

    // Flip the bits to get the Implode-style canonical code.
    i = 0;
    while (i < n) : (i += 1) {
        assert(e.lengths[i] >= 1);
        e.codewords[i] = @intCast(u16, bits_utils.lsb(~e.codewords[i], @intCast(u6, e.lengths[i])));
    }
}

fn flush_buffer(s: *implode_state_t) bool {
    var i: usize = 0;

    assert(!s.buffer_flushed);

    if (s.lit_tree) {
        init_encoder(&s.lit_encoder, &s.lit_freqs, 256);
        if (!write_huffman_code(&s.os, &s.lit_encoder.lengths, 256)) {
            return false;
        }
    }

    init_encoder(&s.len_encoder, &s.len_sym_freqs, 64);
    if (!write_huffman_code(&s.os, &s.len_encoder.lengths, 64)) {
        return false;
    }

    init_encoder(&s.dist_encoder, &s.dist_sym_freqs, 64);
    if (!write_huffman_code(&s.os, &s.dist_encoder.lengths, 64)) {
        return false;
    }

    i = 0;
    while (i < s.buffer_size) : (i += 1) {
        if (s.buffer[i].dist == 0) {
            if (!write_lit(s, @intCast(u8, s.buffer[i].litlen))) {
                return false;
            }
        } else {
            if (!write_backref(s, s.buffer[i].dist, s.buffer[i].litlen)) {
                return false;
            }
        }
    }

    s.buffer_flushed = true;

    return true;
}

fn lit_callback(lit: u8, aux: anytype) bool {
    var s: *implode_state_t = aux;

    if (s.buffer_flushed) {
        return write_lit(s, lit);
    }

    assert(s.buffer_size < BUFFER_CAP);
    s.buffer[s.buffer_size].dist = 0;
    s.buffer[s.buffer_size].litlen = lit;
    s.buffer_size += 1;

    s.lit_freqs[lit] += 1;

    if (s.buffer_size == BUFFER_CAP) {
        return flush_buffer(s);
    }

    return true;
}

fn backref_callback(dist: usize, len: usize, aux: anytype) bool {
    var s: *implode_state_t = aux;

    assert(dist >= 1);
    assert(dist <= max_dist(s.large_wnd));
    assert(len >= (if (s.lit_tree) @as(usize, 3) else @as(usize, 2)));
    assert(len <= max_len(s.lit_tree));

    if (s.buffer_flushed) {
        return write_backref(s, dist, len);
    }

    assert(s.buffer_size < BUFFER_CAP);
    s.buffer[s.buffer_size].dist = @intCast(u16, dist);
    s.buffer[s.buffer_size].litlen = @intCast(u16, len);
    s.buffer_size += 1;

    s.dist_sym_freqs[dist_sym(dist, s.large_wnd)] += 1;
    s.len_sym_freqs[len_sym(len, s.lit_tree)] += 1;

    if (s.buffer_size == BUFFER_CAP) {
        return flush_buffer(s);
    }

    return true;
}

// PKZip Method 6: Implode / Explode.

// Compress (implode) the data in src into dst, using a large window and Huffman
// coding of literals as specified by the flags. The number of bytes output, at
// most dst_cap, is stored in *dst_used. Returns false if there is not enough
// room in dst.
pub fn hwimplode(
    src: [*]const u8,
    src_len: usize,
    large_wnd: bool,
    lit_tree: bool,
    dst: [*]u8,
    dst_cap: usize,
    dst_used: *usize,
) bool {
    var s: implode_state_t = undefined;

    s.large_wnd = large_wnd;
    s.lit_tree = lit_tree;
    s.buffer_size = 0;
    s.buffer_flushed = false;
    mem.set(u16, s.dist_sym_freqs[0..], 0);
    mem.set(u16, s.len_sym_freqs[0..], 0);
    mem.set(u16, s.lit_freqs[0..], 0);
    bs.ostream_init(&s.os, dst, dst_cap);

    if (!lz.lz77_compress(
        src,
        src_len,
        max_dist(large_wnd),
        max_len(lit_tree),
        true, //allow_overlap=true
        lit_callback,
        backref_callback,
        &s,
    )) {
        return false;
    }

    if (!s.buffer_flushed and !flush_buffer(&s)) {
        return false;
    }

    dst_used.* = bs.ostream_bytes_written(&s.os);

    return true;
}

// Initialize the Huffman decoder d with num_lens codeword lengths read from is.
// Returns false if the input is invalid.
fn read_huffman_code(
    is: *bs.istream_t,
    num_lens: usize,
    d: *hm.huffman_decoder_t,
) bool {
    var lens: [256]u8 = [1]u8{0} ** 256;
    var byte: u8 = 0;
    var codeword_len: u8 = 0;
    var run_length: u8 = 0;
    var num_bytes: usize = 0;
    var byte_idx: usize = 0;
    var codeword_idx: usize = 0;
    var i: usize = 0;
    var len_count: [17]u16 = [1]u16{0} ** 17;
    var avail_codewords: i32 = 0;
    var ok: bool = false;

    assert(num_lens <= lens.len);

    // Number of bytes representing the Huffman code.
    byte = @intCast(u8, bits_utils.lsb(bs.istream_bits(is), 8));
    num_bytes = @intCast(usize, byte) + 1;
    if (!bs.istream_advance(is, 8)) {
        return false;
    }

    codeword_idx = 0;
    byte_idx = 0;
    while (byte_idx < num_bytes) : (byte_idx += 1) {
        byte = @intCast(u8, bits_utils.lsb(bs.istream_bits(is), 8));
        if (!bs.istream_advance(is, 8)) {
            return false;
        }

        codeword_len = (byte & 0xf) + 1; // Low four bits plus one.
        run_length = (byte >> 4) + 1; // High four bits plus one.

        assert(codeword_len >= 1 and codeword_len <= 16);
        assert(codeword_len < len_count.len);
        len_count[codeword_len] += run_length;

        if (codeword_idx + run_length > num_lens) {
            return false; // Too many codeword lengths.
        }
        i = 0;
        while (i < run_length) : (i += 1) {
            assert(codeword_idx < num_lens);
            lens[codeword_idx] = codeword_len;
            codeword_idx += 1;
        }
    }

    assert(codeword_idx <= num_lens);
    if (codeword_idx < num_lens) {
        return false; // Too few codeword lengths.
    }

    // Check that the Huffman tree is full.
    avail_codewords = 1;
    i = 1;
    while (i <= 16) : (i += 1) {
        assert(avail_codewords >= 0);
        avail_codewords *= 2;
        avail_codewords -= len_count[i];
        if (avail_codewords < 0) {
            // Higher count than available codewords.
            return false;
        }
    }
    if (avail_codewords != 0) {
        // Not all codewords were used.
        return false;
    }

    ok = hm.huffman_decoder_init(d, &lens, num_lens);
    assert(ok); // "The checks above mean the tree should be valid."

    return true;
}

// Decompress (explode) the data in src. The uncompressed data is uncomp_len
// bytes long. large_wnd is true if a large window was used for compression,
// lit_tree is true if literals were Huffman coded, and pk101_bug_compat is
// true if compatibility with PKZip 1.01/1.02 is desired. The number of input
// bytes used, at most src_len, is written to *src_used on success. Output is
// written to dst.
pub fn hwexplode(
    src: [*]const u8,
    src_len: usize,
    uncomp_len: usize,
    large_wnd: bool,
    lit_tree: bool,
    pk101_bug_compat: bool,
    src_used: *usize,
    dst: [*]u8,
) !explode_stat_t {
    var is: bs.istream_t = undefined;
    var lit_decoder: hm.huffman_decoder_t = undefined;
    var len_decoder: hm.huffman_decoder_t = undefined;
    var dist_decoder: hm.huffman_decoder_t = undefined;
    var dst_pos: usize = 0;
    var used: usize = 0;
    var used_tot: usize = 0;
    var dist: usize = 0;
    var len: usize = 0;
    var i: usize = 0;
    var bits: u64 = 0;
    var sym: u32 = 0;
    var min_len: u32 = 0;

    bs.istream_init(&is, src, src_len);

    if (lit_tree) {
        if (!read_huffman_code(&is, 256, &lit_decoder)) {
            return explode_stat_t.HWEXPLODE_ERR;
        }
    }
    if (!read_huffman_code(&is, 64, &len_decoder) or
        !read_huffman_code(&is, 64, &dist_decoder))
    {
        return explode_stat_t.HWEXPLODE_ERR;
    }

    if (pk101_bug_compat) {
        min_len = if (large_wnd) 3 else 2;
    } else {
        min_len = if (lit_tree) 3 else 2;
    }

    dst_pos = 0;
    while (dst_pos < uncomp_len) {
        bits = bs.istream_bits(&is);

        if (bits_utils.lsb(bits, 1) == 0x1) {
            // Literal.
            bits >>= 1;
            if (lit_tree) {
                sym = try hm.huffman_decode(
                    &lit_decoder,
                    @truncate(u16, ~bits),
                    &used,
                );
                assert(sym >= 0); // "huffman decode successful"
                if (!bs.istream_advance(&is, 1 + used)) {
                    return explode_stat_t.HWEXPLODE_ERR;
                }
            } else {
                sym = @intCast(u32, bits_utils.lsb(bits, 8));
                if (!bs.istream_advance(&is, 1 + 8)) {
                    return explode_stat_t.HWEXPLODE_ERR;
                }
            }
            assert(sym >= 0 and sym <= UINT8_MAX);
            dst[dst_pos] = @intCast(u8, sym);
            dst_pos += 1;
            continue;
        }

        // Backref.
        assert(bits_utils.lsb(bits, 1) == 0x0);
        used_tot = 1;
        bits >>= 1;

        // Read the low dist bits.
        if (large_wnd) {
            dist = @intCast(usize, bits_utils.lsb(bits, 7));
            bits >>= 7;
            used_tot += 7;
        } else {
            dist = @intCast(usize, bits_utils.lsb(bits, 6));
            bits >>= 6;
            used_tot += 6;
        }

        // Read the Huffman-encoded high dist bits.
        sym = try hm.huffman_decode(&dist_decoder, @truncate(u16, ~bits), &used);
        assert(sym >= 0); // "huffman decode successful"
        used_tot += used;
        bits >>= @intCast(u6, used);
        dist |= @intCast(usize, sym) << if (large_wnd) @intCast(u6, 7) else @intCast(u6, 6);
        dist += 1;

        // Read the Huffman-encoded len.
        sym = try hm.huffman_decode(&len_decoder, @truncate(u16, ~bits), &used);
        assert(sym >= 0); // "huffman decode successful"
        used_tot += used;
        bits >>= @intCast(u6, used);
        len = @intCast(usize, sym + min_len);

        if (sym == 63) {
            // Read an extra len byte.
            len += @intCast(usize, bits_utils.lsb(bits, 8));
            used_tot += 8;
            bits >>= 8;
        }

        assert(used_tot <= bs.ISTREAM_MIN_BITS);
        if (!bs.istream_advance(&is, used_tot)) {
            return explode_stat_t.HWEXPLODE_ERR;
        }

        if (bits_utils.round_up(len, 8) <= uncomp_len - dst_pos and
            dist <= dst_pos)
        {
            // Enough room and no implicit zeros; chunked copy.
            lz.lz77_output_backref64(dst, dst_pos, dist, len);
            dst_pos += len;
        } else if (len > uncomp_len - dst_pos) {
            // Not enough room.
            return explode_stat_t.HWEXPLODE_ERR;
        } else {
            // Copy, handling overlap and implicit zeros.
            i = 0;
            while (i < len) : (i += 1) {
                if (dist > dst_pos) {
                    dst[dst_pos] = 0;
                    dst_pos += 1;
                    continue;
                }
                dst[dst_pos] = dst[dst_pos - dist];
                dst_pos += 1;
            }
        }
    }

    src_used.* = bs.istream_bytes_read(&is);
    return explode_stat_t.HWEXPLODE_OK;
}
