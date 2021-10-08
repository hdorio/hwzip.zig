// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const bs = @import("./bitstream.zig");
const bu = @import("./bits.zig"); // bits utilities
const hm = @import("./huffman.zig");
const lz = @import("./lz77.zig");
const tables = @import("./tables.zig");

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;

const SIZE_MAX = math.maxInt(u64);
const UINT8_MAX = math.maxInt(u8);

const LITLEN_EOB = 256;
const LITLEN_MAX = 285;
const LITLEN_TBL_OFFSET = 257;
const MIN_LEN = 3;
const MAX_LEN = 258;

const DISTSYM_MAX = 29;
const MIN_DISTANCE = 1;
const MAX_DISTANCE = 32768;

const MIN_CODELEN_LENS = 4;
const MAX_CODELEN_LENS = 19;

const MIN_LITLEN_LENS = 257;
const MAX_LITLEN_LENS = 288;

const MIN_DIST_LENS = 1;
const MAX_DIST_LENS = 32;

const CODELEN_MAX_LIT = 15;

const CODELEN_COPY = 16;
const CODELEN_COPY_MIN = 3;
const CODELEN_COPY_MAX = 6;

const CODELEN_ZEROS = 17;
const CODELEN_ZEROS_MIN = 3;
const CODELEN_ZEROS_MAX = 10;

const CODELEN_ZEROS2 = 18;
const CODELEN_ZEROS2_MIN = 11;
const CODELEN_ZEROS2_MAX = 138;

pub const inf_stat_t = enum {
    HWINF_OK, // Inflation was successful.
    HWINF_FULL, // Not enough room in the output buffer.
    HWINF_ERR, // Error in the input data.
};

fn inf_block(
    is: *bs.istream_t,
    dst: [*]u8,
    dst_cap: usize,
    dst_pos: *usize,
    litlen_dec: *const hm.huffman_decoder_t,
    dist_dec: *const hm.huffman_decoder_t,
) inf_stat_t {
    var bits: u64 = 0;
    var used: usize = 0;
    var used_tot: usize = 0;
    var dist: usize = 0;
    var len: usize = 0;
    var litlen: u32 = 0;
    var distsym: u32 = 0;
    var ebits: u16 = 0;

    while (true) {
        // Read a litlen symbol.
        bits = bs.istream_bits(is);
        litlen = hm.huffman_decode(litlen_dec, @truncate(u16, bits), &used) catch {
            return inf_stat_t.HWINF_ERR;
        };
        bits >>= @intCast(u6, used);
        used_tot = used;

        if (litlen < 0 or litlen > LITLEN_MAX) {
            // Failed to decode, or invalid symbol.
            return inf_stat_t.HWINF_ERR; // replaced by the catch above
        } else if (litlen <= UINT8_MAX) {
            // Literal.
            if (!bs.istream_advance(is, used_tot)) {
                return inf_stat_t.HWINF_ERR;
            }
            if (dst_pos.* == dst_cap) {
                return inf_stat_t.HWINF_FULL;
            }
            lz.lz77_output_lit(dst, dst_pos.*, @intCast(u8, litlen));
            dst_pos.* += 1;
            continue;
        } else if (litlen == LITLEN_EOB) {
            // End of block.
            if (!bs.istream_advance(is, used_tot)) {
                return inf_stat_t.HWINF_ERR;
            }
            return inf_stat_t.HWINF_OK;
        }

        // It is a back reference. Figure out the length.
        assert(litlen >= LITLEN_TBL_OFFSET and litlen <= LITLEN_MAX);
        len = tables.litlen_tbl[litlen - LITLEN_TBL_OFFSET].base_len;
        ebits = tables.litlen_tbl[litlen - LITLEN_TBL_OFFSET].ebits;
        if (ebits != 0) {
            len += bu.lsb(bits, @intCast(u6, ebits));
            bits >>= @intCast(u6, ebits);
            used_tot += ebits;
        }
        assert(len >= MIN_LEN and len <= MAX_LEN);

        // Get the distance.
        distsym = hm.huffman_decode(dist_dec, @truncate(u16, bits), &used) catch {
            return inf_stat_t.HWINF_ERR;
        };
        bits >>= @intCast(u6, used);
        used_tot += used;

        if (distsym < 0 or distsym > DISTSYM_MAX) {
            // Failed to decode, or invalid symbol.
            return inf_stat_t.HWINF_ERR; // replaced by the catch above
        }
        dist = tables.dist_tbl[distsym].base_dist;
        ebits = tables.dist_tbl[distsym].ebits;
        if (ebits != 0) {
            dist += bu.lsb(bits, @intCast(u6, ebits));
            bits >>= @intCast(u6, ebits);
            used_tot += ebits;
        }
        assert(dist >= MIN_DISTANCE and dist <= MAX_DISTANCE);

        assert(used_tot <= bs.ISTREAM_MIN_BITS);
        if (!bs.istream_advance(is, used_tot)) {
            return inf_stat_t.HWINF_ERR;
        }

        // Bounds check and output the backref.
        if (dist > dst_pos.*) {
            return inf_stat_t.HWINF_ERR;
        }
        if (bu.round_up(len, 8) <= dst_cap - dst_pos.*) {
            lz.lz77_output_backref64(dst, dst_pos.*, dist, len);
        } else if (len <= dst_cap - dst_pos.*) {
            lz.lz77_output_backref(dst, dst_pos.*, dist, len);
        } else {
            return inf_stat_t.HWINF_FULL;
        }
        dst_pos.* += len;
    }
}

// RFC 1951, 3.2.7
const codelen_lengths_order: [MAX_CODELEN_LENS]usize = [_]usize{
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
};

fn init_dyn_decoders(
    is: *bs.istream_t,
    litlen_dec: *hm.huffman_decoder_t,
    dist_dec: *hm.huffman_decoder_t,
) inf_stat_t {
    var bits: u64 = 0;
    var num_litlen_lens: usize = 0;
    var num_dist_lens: usize = 0;
    var num_codelen_lens: usize = 0;
    var codelen_lengths: [MAX_CODELEN_LENS]u8 = undefined;
    mem.set(u8, codelen_lengths[0..], 0);
    var code_lengths: [MAX_LITLEN_LENS + MAX_DIST_LENS]u8 = undefined;
    mem.set(u8, code_lengths[0..], 0);
    var i: usize = 0;
    var n: usize = 0;
    var used: usize = 0;
    var sym: u32 = 0;
    var codelen_dec: hm.huffman_decoder_t = undefined;

    bits = bs.istream_bits(is);

    // Number of litlen codeword lengths (5 bits + 257).
    num_litlen_lens = @intCast(usize, bu.lsb(bits, 5) + MIN_LITLEN_LENS);
    bits >>= 5;
    assert(num_litlen_lens <= MAX_LITLEN_LENS);

    // Number of dist codeword lengths (5 bits + 1).
    num_dist_lens = @intCast(usize, bu.lsb(bits, 5) + MIN_DIST_LENS);
    bits >>= 5;
    assert(num_dist_lens <= MAX_DIST_LENS);

    // Number of code length lengths (4 bits + 4).
    num_codelen_lens = @intCast(usize, bu.lsb(bits, 4) + MIN_CODELEN_LENS);
    bits >>= 4;
    assert(num_codelen_lens <= MAX_CODELEN_LENS);

    if (!bs.istream_advance(is, 5 + 5 + 4)) {
        return inf_stat_t.HWINF_ERR;
    }

    // Read the codelen codeword lengths (3 bits each)
    // and initialize the codelen decoder.
    i = 0;
    while (i < num_codelen_lens) : (i += 1) {
        bits = bs.istream_bits(is);
        codelen_lengths[codelen_lengths_order[i]] = @intCast(u8, bu.lsb(bits, 3));
        if (!bs.istream_advance(is, 3)) {
            return inf_stat_t.HWINF_ERR;
        }
    }
    while (i < MAX_CODELEN_LENS) : (i += 1) {
        codelen_lengths[codelen_lengths_order[i]] = 0;
    }
    if (!hm.huffman_decoder_init(&codelen_dec, &codelen_lengths, MAX_CODELEN_LENS)) {
        return inf_stat_t.HWINF_ERR;
    }

    // Read the litlen and dist codeword lengths.
    i = 0;
    while (i < num_litlen_lens + num_dist_lens) {
        bits = bs.istream_bits(is);
        sym = hm.huffman_decode(&codelen_dec, @truncate(u16, bits), &used) catch {
            return inf_stat_t.HWINF_ERR;
        };
        bits >>= @intCast(u6, used);
        if (!bs.istream_advance(is, used)) {
            return inf_stat_t.HWINF_ERR;
        }

        if (sym >= 0 and sym <= CODELEN_MAX_LIT) {
            // A literal codeword length.
            code_lengths[i] = @intCast(u8, sym);
            i += 1;
        } else if (sym == CODELEN_COPY) {
            // Copy the previous codeword length 3--6 times.
            if (i < 1) {
                return inf_stat_t.HWINF_ERR; // No previous length.
            }
            // 2 bits + 3
            n = @intCast(usize, bu.lsb(bits, 2)) + CODELEN_COPY_MIN;
            if (!bs.istream_advance(is, 2)) {
                return inf_stat_t.HWINF_ERR;
            }
            assert(n >= CODELEN_COPY_MIN and n <= CODELEN_COPY_MAX);
            if (i + n > num_litlen_lens + num_dist_lens) {
                return inf_stat_t.HWINF_ERR;
            }
            while (n > 0) : (n -= 1) {
                code_lengths[i] = code_lengths[i - 1];
                i += 1;
            }
        } else if (sym == CODELEN_ZEROS) {
            // 3--10 zeros; 3 bits + 3
            n = @intCast(usize, bu.lsb(bits, 3) + CODELEN_ZEROS_MIN);
            if (!bs.istream_advance(is, 3)) {
                return inf_stat_t.HWINF_ERR;
            }
            assert(n >= CODELEN_ZEROS_MIN and n <= CODELEN_ZEROS_MAX);
            if (i + n > num_litlen_lens + num_dist_lens) {
                return inf_stat_t.HWINF_ERR;
            }
            while (n > 0) : (n -= 1) {
                code_lengths[i] = 0;
                i += 1;
            }
        } else if (sym == CODELEN_ZEROS2) {
            // 11--138 zeros; 7 bits + 138.
            n = @intCast(usize, bu.lsb(bits, 7) + CODELEN_ZEROS2_MIN);
            if (!bs.istream_advance(is, 7)) {
                return inf_stat_t.HWINF_ERR;
            }
            assert(n >= CODELEN_ZEROS2_MIN and n <= CODELEN_ZEROS2_MAX);
            if (i + n > num_litlen_lens + num_dist_lens) {
                return inf_stat_t.HWINF_ERR;
            }
            while (n > 0) : (n -= 1) {
                code_lengths[i] = 0;
                i += 1;
            }
        } else {
            // Invalid symbol.
            return inf_stat_t.HWINF_ERR;
        }
    }

    if (!hm.huffman_decoder_init(litlen_dec, &code_lengths, num_litlen_lens)) {
        return inf_stat_t.HWINF_ERR;
    }

    if (!hm.huffman_decoder_init(dist_dec, code_lengths[num_litlen_lens..].ptr, num_dist_lens)) {
        return inf_stat_t.HWINF_ERR;
    }

    return inf_stat_t.HWINF_OK;
}

fn inf_dyn_block(
    is: *bs.istream_t,
    dst: [*]u8,
    dst_cap: usize,
    dst_pos: *usize,
) inf_stat_t {
    var s: inf_stat_t = undefined;
    var litlen_dec: hm.huffman_decoder_t = hm.huffman_decoder_t{};
    var dist_dec: hm.huffman_decoder_t = hm.huffman_decoder_t{};

    s = init_dyn_decoders(is, &litlen_dec, &dist_dec);
    if (s != inf_stat_t.HWINF_OK) {
        return s;
    }

    return inf_block(is, dst, dst_cap, dst_pos, &litlen_dec, &dist_dec);
}

fn inf_fixed_block(
    is: *bs.istream_t,
    dst: [*]u8,
    dst_cap: usize,
    dst_pos: *usize,
) inf_stat_t {
    var litlen_dec: hm.huffman_decoder_t = hm.huffman_decoder_t{};
    var dist_dec: hm.huffman_decoder_t = hm.huffman_decoder_t{};

    _ = hm.huffman_decoder_init(
        &litlen_dec,
        &tables.fixed_litlen_lengths,
        tables.fixed_litlen_lengths.len,
    );
    _ = hm.huffman_decoder_init(
        &dist_dec,
        &tables.fixed_dist_lengths,
        tables.fixed_dist_lengths.len,
    );

    return inf_block(is, dst, dst_cap, dst_pos, &litlen_dec, &dist_dec);
}

fn inf_noncomp_block(
    is: *bs.istream_t,
    dst: [*]u8,
    dst_cap: usize,
    dst_pos: *usize,
) inf_stat_t {
    var p: [*]const u8 = undefined;
    var len: u16 = 0;
    var nlen: u16 = 0;

    p = @ptrCast([*]const u8, bs.istream_byte_align(is));

    // Read len and nlen (2 x 16 bits).
    if (!bs.istream_advance(is, 32)) {
        return inf_stat_t.HWINF_ERR; // Not enough input.
    }
    len = bu.read16le(p);
    nlen = bu.read16le(p + 2);
    p += 4;

    if (nlen != (~len & 0xffff)) {
        return inf_stat_t.HWINF_ERR;
    }

    if (!bs.istream_advance(is, @intCast(usize, len) * 8)) {
        return inf_stat_t.HWINF_ERR; // Not enough input.
    }

    if (dst_cap - dst_pos.* < len) {
        return inf_stat_t.HWINF_FULL; // Not enough room to output.
    }

    mem.copy(u8, dst[(dst_pos.*)..(dst_pos.* + len)], p[0..len]);
    dst_pos.* += len;

    return inf_stat_t.HWINF_OK;
}

// Decompress (inflate) the Deflate stream in src. The number of input bytes
// used, at most src_len, is stored in *src_used on success. Output is written
// to dst. The number of bytes written, at most dst_cap, is stored in *dst_used
// on success. src[0..src_len-1] and dst[0..dst_cap-1] must not overlap.
pub fn hwinflate(
    src: [*]const u8,
    src_len: usize,
    src_used: *usize,
    dst: [*]u8,
    dst_cap: usize,
    dst_used: *usize,
) inf_stat_t {
    var is: bs.istream_t = undefined;
    var dst_pos: usize = 0;
    var bits: u64 = 0;
    var bfinal: u1 = 0;
    var s: inf_stat_t = undefined;

    bs.istream_init(&is, src, src_len);
    dst_pos = 0;

    while (bfinal == 0) {
        // Read the 3-bit block header.
        bits = bs.istream_bits(&is);
        if (!bs.istream_advance(&is, 3)) {
            return inf_stat_t.HWINF_ERR;
        }
        bfinal = @truncate(u1, bits & @as(u64, 1));
        bits >>= 1;

        s = switch (bu.lsb(bits, 2)) {
            // 00: No compression.
            0 => inf_noncomp_block(&is, dst, dst_cap, &dst_pos),
            // 01: Compressed with fixed Huffman codes.
            1 => inf_fixed_block(&is, dst, dst_cap, &dst_pos),
            // 10: Compressed with "dynamic" Huffman codes.
            2 => inf_dyn_block(&is, dst, dst_cap, &dst_pos),
            // Invalid block type.
            else => return inf_stat_t.HWINF_ERR,
        };

        if (s != inf_stat_t.HWINF_OK) {
            return s;
        }
    }

    src_used.* = bs.istream_bytes_read(&is);

    assert(dst_pos <= dst_cap);
    dst_used.* = dst_pos;

    return inf_stat_t.HWINF_OK;
}

// The largest number of bytes that will fit in any kind of block is 65,534.
// It will fit in an uncompressed block (max 65,535 bytes) and a Huffman
// block with only literals (65,535 symbols including end-of-block marker). */
const MAX_BLOCK_LEN_BYTES = 65534;

const deflate_state_t: type = struct {
    os: bs.ostream_t,
    block_src: [*]const u8, // First src byte in the block.

    block_len: usize, // Number of symbols in the current block.
    block_len_bytes: usize, // Number of src bytes in the block.

    // Symbol frequencies for the current block.
    litlen_freqs: [LITLEN_MAX + 1]u16,
    dist_freqs: [DISTSYM_MAX + 1]u16,
    block: [MAX_BLOCK_LEN_BYTES + 1]struct {
        distance: u16, // Backref distance.
        u: packed union {
            lit: u16, // Literal byte or end-of-block.
            len: u16, // Backref length (distance != 0).
        },
    },
};

fn reset_block(s: *deflate_state_t) void {
    s.block_len = 0;
    s.block_len_bytes = 0;

    mem.set(u16, s.litlen_freqs[0..], 0);
    mem.set(u16, s.dist_freqs[0..], 0);
}

const codelen_sym_t: type = struct {
    sym: u8,
    count: u8, // For symbols 16, 17, 18.
};

inline fn min(a: usize, b: usize) usize {
    return if (a < b) a else b;
}

// Encode the n code lengths in lens into encoded, returning the number of
// elements in encoded.
fn encode_lens(lens: [*]const u8, n: usize, encoded: [*]codelen_sym_t) usize {
    var i: usize = 0;
    var j: usize = 0;
    var num_encoded: usize = 0;
    var count: u8 = 0;

    i = 0;
    num_encoded = 0;
    while (i < n) {
        if (lens[i] == 0) {
            // Scan past the end of this zero run (max 138).
            j = i;
            while (j < min(n, i + CODELEN_ZEROS2_MAX) and lens[j] == 0) : (j += 1) {}
            count = @intCast(u8, j - i);

            if (count < CODELEN_ZEROS_MIN) {
                // Output a single zero.
                encoded[num_encoded].sym = 0;
                num_encoded += 1;
                i += 1;
                continue;
            }

            // Output a repeated zero.
            if (count <= CODELEN_ZEROS_MAX) {
                // Repeated zero 3--10 times.
                assert(count >= CODELEN_ZEROS_MIN and count <= CODELEN_ZEROS_MAX);
                encoded[num_encoded].sym = CODELEN_ZEROS;
                encoded[num_encoded].count = count;
                num_encoded += 1;
            } else {
                // Repeated zero 11--138 times.
                assert(count >= CODELEN_ZEROS2_MIN and count <= CODELEN_ZEROS2_MAX);
                encoded[num_encoded].sym = CODELEN_ZEROS2;
                encoded[num_encoded].count = count;
                num_encoded += 1;
            }
            i = j;
            continue;
        }

        // Output len.
        encoded[num_encoded].sym = lens[i];
        i += 1;
        num_encoded += 1;

        // Scan past the end of the run of this len (max 6).
        j = i;
        while (j < min(n, i + CODELEN_COPY_MAX) and lens[j] == lens[i - 1]) : (j += 1) {}
        count = @intCast(u8, j - i);

        if (count >= CODELEN_COPY_MIN) {
            // Repeat last len 3--6 times.
            assert(count >= CODELEN_COPY_MIN and count <= CODELEN_COPY_MAX);
            encoded[num_encoded].sym = CODELEN_COPY;
            encoded[num_encoded].count = count;
            num_encoded += 1;
            i = j;
            continue;
        }
    }

    return num_encoded;
}

// Zlib always emits two non-zero distance codeword lengths (see build_trees),
// and versions before 1.2.1.1 (and possibly other implementations) would fail
// to inflate compressed data where that's not the case. See comment in
// https://github.com/google/zopfli/blob/zopfli-1.0.3/src/zopfli/deflate.c#L75
// Tweak the encoder to ensure compatibility.
fn tweak_dist_encoder(e: *hm.huffman_encoder_t) void {
    var i: usize = 0;
    var n: usize = 0;
    var nonzero_idx: usize = SIZE_MAX;

    n = 0;
    i = 0;
    while (i <= DISTSYM_MAX) : (i += 1) {
        if (e.lengths[i] != 0) {
            n += 1;
            nonzero_idx = i;

            if (n == 2) {
                return;
            }
        }
    }

    assert(n < 2);

    if (n == 0) {
        // Give symbols 0 and 1 codewords of length 1.
        e.lengths[0] = 1;
        e.lengths[1] = 1;
        e.codewords[0] = 0;
        e.codewords[1] = 1;
        return;
    }

    assert(n == 1);
    assert(nonzero_idx != SIZE_MAX);

    if (nonzero_idx == 0) {
        // Symbol 0 already has a codeword of length 1.
        // Give symbol 1 a codeword of length 1.
        assert(e.lengths[0] == 1);
        assert(e.codewords[0] == 0);
        e.lengths[1] = 1;
        e.codewords[1] = 1;
    } else {
        // Give symbol 0 a codeword of length 1 ("0") and
        // update the other symbol's codeword to "1".
        assert(e.lengths[0] == 0);
        assert(e.codewords[nonzero_idx] == 0);
        e.lengths[0] = 1;
        e.codewords[0] = 0;
        e.codewords[nonzero_idx] = 1;
    }
}

// Encode litlen_lens and dist_lens into encoded. *num_litlen_lens and
// *num_dist_lens will be set to the number of encoded litlen and dist lens,
// respectively. Returns the number of elements in encoded.
fn encode_dist_litlen_lens(
    litlen_lens: [*]const u8,
    dist_lens: [*]const u8,
    encoded: [*]codelen_sym_t,
    num_litlen_lens: *usize,
    num_dist_lens: *usize,
) usize {
    var i: usize = 0;
    var n: usize = 0;
    var lens: [LITLEN_MAX + 1 + DISTSYM_MAX + 1]u8 = undefined;

    num_litlen_lens.* = LITLEN_MAX + 1;
    num_dist_lens.* = DISTSYM_MAX + 1;

    // Drop trailing zero litlen lengths.
    assert(litlen_lens[LITLEN_EOB] != 0); // "EOB len should be non-zero."
    while (litlen_lens[num_litlen_lens.* - 1] == 0) {
        num_litlen_lens.* -= 1;
    }
    assert(num_litlen_lens.* >= MIN_LITLEN_LENS);

    // Drop trailing zero dist lengths, keeping at least one.
    while (dist_lens[num_dist_lens.* - 1] == 0 and num_dist_lens.* > 1) {
        num_dist_lens.* -= 1;
    }
    assert(num_dist_lens.* >= MIN_DIST_LENS);

    // Copy the lengths into a unified array.
    n = 0;
    i = 0;
    while (i < num_litlen_lens.*) : (i += 1) {
        lens[n] = litlen_lens[i];
        n += 1;
    }
    i = 0;
    while (i < num_dist_lens.*) : (i += 1) {
        lens[n] = dist_lens[i];
        n += 1;
    }

    return encode_lens(&lens, n, encoded);
}

// Count the number of significant (not trailing zeros) codelen lengths.
fn count_codelen_lens(codelen_lens: [*]const u8) usize {
    var n: usize = MAX_CODELEN_LENS;

    // Drop trailing zero lengths.
    while (codelen_lens[codelen_lengths_order[n - 1]] == 0) {
        n -= 1;
    }

    // The first 4 lengths in the order (16, 17, 18, 0) cannot be used to
    // encode any non-zero lengths. Since there will always be at least
    // one non-zero codeword length (for EOB), n will be >= 4.
    assert(n >= MIN_CODELEN_LENS and n <= MAX_CODELEN_LENS);

    return n;
}

// Calculate the number of bits for an uncompressed block, including header.
fn uncomp_block_len(s: *const deflate_state_t) usize {
    var bit_pos: usize = 0;
    var padding: usize = 0;

    // Bit position after writing the block header.
    bit_pos = bs.ostream_bit_pos(&s.os) + 3;
    padding = bu.round_up(bit_pos, 8) - bit_pos;

    // Header + padding + len/nlen + block contents.
    return 3 + padding + 2 * 16 + s.block_len_bytes * 8;
}

// Calculate the number of bits for a Huffman encoded block body. */
fn huffman_block_body_len(
    s: *const deflate_state_t,
    litlen_lens: [*]const u8,
    dist_lens: [*]const u8,
) usize {
    var i: usize = 0;
    var freq: usize = 0;
    var len: usize = 0;

    len = 0;

    i = 0;
    while (i <= LITLEN_MAX) : (i += 1) {
        freq = s.litlen_freqs[i];
        len += litlen_lens[i] * freq;

        if (i >= LITLEN_TBL_OFFSET) {
            len += tables.litlen_tbl[i - LITLEN_TBL_OFFSET].ebits * freq;
        }
    }

    i = 0;
    while (i <= DISTSYM_MAX) : (i += 1) {
        freq = s.dist_freqs[i];
        len += dist_lens[i] * freq;
        len += tables.dist_tbl[i].ebits * freq;
    }

    return len;
}

// Calculate the number of bits for a dynamic Huffman block.
fn dyn_block_len(
    s: *const deflate_state_t,
    num_codelen_lens: usize,
    codelen_freqs: [*]const u16,
    codelen_enc: *const hm.huffman_encoder_t,
    litlen_enc: *const hm.huffman_encoder_t,
    dist_enc: *const hm.huffman_encoder_t,
) usize {
    var len: usize = 0;
    var i: usize = 0;
    var freq: usize = 0;

    // Block header.
    len = 3;

    // Nbr of litlen, dist, and codelen lengths.
    len += 5 + 5 + 4;

    // Codelen lengths.
    len += 3 * num_codelen_lens;

    // Codelen encoding.
    i = 0;
    while (i < MAX_CODELEN_LENS) : (i += 1) {
        freq = codelen_freqs[i];
        len += codelen_enc.lengths[i] * freq;

        // Extra bits.
        if (i == CODELEN_COPY) {
            len += 2 * freq;
        } else if (i == CODELEN_ZEROS) {
            len += 3 * freq;
        } else if (i == CODELEN_ZEROS2) {
            len += 7 * freq;
        }
    }

    return len + huffman_block_body_len(s, &litlen_enc.lengths, &dist_enc.lengths);
}

fn distance2dist(distance: usize) u8 {
    assert(distance >= 1 and distance <= MAX_DISTANCE);

    return if (distance <= 256) tables.distance2dist_lo[(distance - 1)] else tables.distance2dist_hi[(distance - 1) >> 7];
}

fn write_huffman_block(
    s: *deflate_state_t,
    litlen_enc: *const hm.huffman_encoder_t,
    dist_enc: *const hm.huffman_encoder_t,
) bool {
    var i: usize = 0;
    var nbits: usize = 0;
    var distance: u16 = 0;
    var dist: u16 = 0;
    var len: u16 = 0;
    var litlen: u16 = 0;
    var bits: u64 = 0;
    var ebits: u64 = 0;

    i = 0;
    while (i < s.block_len) : (i += 1) {
        if (s.block[i].distance == 0) {
            // Literal or EOB.
            litlen = s.block[i].u.lit;
            assert(litlen <= LITLEN_EOB);
            if (!bs.ostream_write(&s.os, litlen_enc.codewords[litlen], litlen_enc.lengths[litlen])) {
                return false;
            }
            continue;
        }

        // Back reference length.
        len = s.block[i].u.len;
        litlen = tables.len2litlen[len];

        // litlen bits
        bits = litlen_enc.codewords[litlen];
        nbits = litlen_enc.lengths[litlen];

        // ebits
        ebits = len - tables.litlen_tbl[litlen - LITLEN_TBL_OFFSET].base_len;
        bits |= ebits << @intCast(u6, nbits);
        nbits += tables.litlen_tbl[litlen - LITLEN_TBL_OFFSET].ebits;

        // Back reference distance.
        distance = s.block[i].distance;
        dist = distance2dist(distance);

        // dist bits
        bits |= @intCast(u64, dist_enc.codewords[dist]) << @intCast(u6, nbits);
        nbits += dist_enc.lengths[dist];

        // ebits
        ebits = distance - tables.dist_tbl[dist].base_dist;
        bits |= ebits << @intCast(u6, nbits);
        nbits += tables.dist_tbl[dist].ebits;

        if (!bs.ostream_write(&s.os, bits, nbits)) {
            return false;
        }
    }

    return true;
}

fn write_dynamic_block(
    s: *deflate_state_t,
    final: bool,
    num_litlen_lens: usize,
    num_dist_lens: usize,
    num_codelen_lens: usize,
    codelen_enc: *const hm.huffman_encoder_t,
    encoded_lens: [*]const codelen_sym_t,
    num_encoded_lens: usize,
    litlen_enc: *const hm.huffman_encoder_t,
    dist_enc: *const hm.huffman_encoder_t,
) bool {
    var i: usize = 0;
    var codelen: u8 = 0;
    var sym: u8 = 0;
    var nbits: u6 = 0;
    var bits: u64 = 0;
    var hlit: u64 = 0;
    var hdist: u64 = 0;
    var hclen: u64 = 0;
    var count: u64 = 0;

    // Block header.
    var is_final: u64 = if (final) 1 else 0;
    bits = (0x2 << 1) | is_final;
    nbits = 3;

    // hlit (5 bits)
    hlit = num_litlen_lens - MIN_LITLEN_LENS;
    bits |= hlit << nbits;
    nbits += 5;

    // hdist (5 bits)
    hdist = num_dist_lens - MIN_DIST_LENS;
    bits |= hdist << nbits;
    nbits += 5;

    // hclen (4 bits)
    hclen = num_codelen_lens - MIN_CODELEN_LENS;
    bits |= hclen << nbits;
    nbits += 4;

    if (!bs.ostream_write(&s.os, bits, nbits)) {
        return false;
    }

    // Codelen lengths.
    i = 0;
    while (i < num_codelen_lens) : (i += 1) {
        codelen = codelen_enc.lengths[codelen_lengths_order[i]];
        if (!bs.ostream_write(&s.os, codelen, 3)) {
            return false;
        }
    }

    // Litlen and dist code lengths.
    i = 0;
    while (i < num_encoded_lens) : (i += 1) {
        sym = encoded_lens[i].sym;

        bits = codelen_enc.codewords[sym];
        nbits = @intCast(u6, codelen_enc.lengths[sym]);

        count = encoded_lens[i].count;
        if (sym == CODELEN_COPY) { // 2 ebits
            bits |= (count - CODELEN_COPY_MIN) << nbits;
            nbits += 2;
        } else if (sym == CODELEN_ZEROS) { // 3 ebits
            bits |= (count - CODELEN_ZEROS_MIN) << nbits;
            nbits += 3;
        } else if (sym == CODELEN_ZEROS2) { // 7 ebits
            bits |= (count - CODELEN_ZEROS2_MIN) << nbits;
            nbits += 7;
        }

        if (!bs.ostream_write(&s.os, bits, nbits)) {
            return false;
        }
    }

    return write_huffman_block(s, litlen_enc, dist_enc);
}

fn write_static_block(s: *deflate_state_t, final: bool) bool {
    var litlen_enc: hm.huffman_encoder_t = undefined;
    var dist_enc: hm.huffman_encoder_t = undefined;

    // Write the block header.
    var is_final: u64 = if (final) 1 else 0;
    if (!bs.ostream_write(&s.os, @as(u64, 0b10) | is_final, 3)) {
        return false;
    }

    hm.huffman_encoder_init2(
        &litlen_enc,
        &tables.fixed_litlen_lengths,
        tables.fixed_litlen_lengths.len,
    );
    hm.huffman_encoder_init2(
        &dist_enc,
        &tables.fixed_dist_lengths,
        tables.fixed_dist_lengths.len,
    );

    return write_huffman_block(s, &litlen_enc, &dist_enc);
}

fn write_uncomp_block(s: *deflate_state_t, final: bool) bool {
    var len_nlen: [4]u8 = undefined;

    // Write the block header.
    var is_final: u64 = if (final) 1 else 0;
    if (!bs.ostream_write(&s.os, is_final, 3)) {
        return false;
    }

    len_nlen[0] = @truncate(u8, s.block_len_bytes >> 0);
    len_nlen[1] = @intCast(u8, s.block_len_bytes >> 8);
    len_nlen[2] = ~len_nlen[0];
    len_nlen[3] = ~len_nlen[1];

    if (!bs.ostream_write_bytes_aligned(&s.os, &len_nlen, len_nlen.len)) {
        return false;
    }

    if (!bs.ostream_write_bytes_aligned(&s.os, s.block_src, s.block_len_bytes)) {
        return false;
    }

    return true;
}

// Write the current deflate block, marking it final if that parameter is true,
// returning false if there is not enough room in the output stream.
fn write_block(s: *deflate_state_t, final: bool) bool {
    var old_bit_pos: usize = 0;
    var uncomp_len: usize = 0;
    var static_len: usize = 0;
    var dynamic_len: usize = 0;

    var dyn_litlen_enc: hm.huffman_encoder_t = undefined;
    var dyn_dist_enc: hm.huffman_encoder_t = undefined;
    var codelen_enc: hm.huffman_encoder_t = undefined;

    var num_encoded_lens: usize = 0;
    var num_litlen_lens: usize = 0;
    var num_dist_lens: usize = 0;

    var encoded_lens: [LITLEN_MAX + 1 + DISTSYM_MAX + 1]codelen_sym_t = undefined;
    var codelen_freqs: [MAX_CODELEN_LENS]u16 = [_]u16{0} ** MAX_CODELEN_LENS;
    var num_codelen_lens: usize = 0;
    var i: usize = 0;

    old_bit_pos = bs.ostream_bit_pos(&s.os);

    // Add the end-of-block marker in case we write a Huffman block.
    assert(s.block_len < s.block.len);
    assert(s.litlen_freqs[LITLEN_EOB] == 0);
    s.block[s.block_len].distance = 0;
    s.block[s.block_len].u.lit = LITLEN_EOB;
    s.block_len += 1;
    s.litlen_freqs[LITLEN_EOB] = 1;

    uncomp_len = uncomp_block_len(s);

    static_len = 3 + huffman_block_body_len(s, &tables.fixed_litlen_lengths, &tables.fixed_dist_lengths);

    // Compute "dynamic" Huffman codes.
    hm.huffman_encoder_init(&dyn_litlen_enc, &s.litlen_freqs, LITLEN_MAX + 1, 15);
    hm.huffman_encoder_init(&dyn_dist_enc, &s.dist_freqs, DISTSYM_MAX + 1, 15);
    tweak_dist_encoder(&dyn_dist_enc);

    // Encode the litlen and dist code lengths.
    num_encoded_lens = encode_dist_litlen_lens(
        &dyn_litlen_enc.lengths,
        &dyn_dist_enc.lengths,
        &encoded_lens,
        &num_litlen_lens,
        &num_dist_lens,
    );

    // Compute the codelen code.
    i = 0;
    while (i < num_encoded_lens) : (i += 1) {
        codelen_freqs[encoded_lens[i].sym] += 1;
    }
    hm.huffman_encoder_init(&codelen_enc, &codelen_freqs, MAX_CODELEN_LENS, 7);
    num_codelen_lens = count_codelen_lens(&codelen_enc.lengths);

    dynamic_len = dyn_block_len(
        s,
        num_codelen_lens,
        &codelen_freqs,
        &codelen_enc,
        &dyn_litlen_enc,
        &dyn_dist_enc,
    );

    if (uncomp_len <= dynamic_len and uncomp_len <= static_len) {
        if (!write_uncomp_block(s, final)) {
            return false;
        }
        assert(bs.ostream_bit_pos(&s.os) - old_bit_pos == uncomp_len);
    } else if (static_len <= dynamic_len) {
        if (!write_static_block(s, final)) {
            return false;
        }
        assert(bs.ostream_bit_pos(&s.os) - old_bit_pos == static_len);
    } else {
        if (!write_dynamic_block(
            s,
            final,
            num_litlen_lens,
            num_dist_lens,
            num_codelen_lens,
            &codelen_enc,
            &encoded_lens,
            num_encoded_lens,
            &dyn_litlen_enc,
            &dyn_dist_enc,
        )) {
            return false;
        }
        assert(bs.ostream_bit_pos(&s.os) - old_bit_pos == dynamic_len);
    }

    return true;
}

fn lit_callback(lit: u8, aux: anytype) bool {
    var s: *deflate_state_t = aux;

    if (s.block_len_bytes + 1 > MAX_BLOCK_LEN_BYTES) {
        if (!write_block(s, false)) {
            return false;
        }
        s.block_src += s.block_len_bytes;
        reset_block(s);
    }

    assert(s.block_len < s.block.len);
    s.block[s.block_len].distance = 0;
    s.block[s.block_len].u.lit = lit;
    s.block_len += 1;
    s.block_len_bytes += 1;

    s.litlen_freqs[lit] += 1;

    return true;
}

fn backref_callback(dist: usize, len: usize, aux: anytype) bool {
    var s: *deflate_state_t = aux;

    if (s.block_len_bytes + len > MAX_BLOCK_LEN_BYTES) {
        if (!write_block(s, false)) {
            return false;
        }
        s.block_src += s.block_len_bytes;
        reset_block(s);
    }

    assert(s.block_len < s.block.len);
    s.block[s.block_len].distance = @intCast(u16, dist);
    s.block[s.block_len].u.len = @intCast(u16, len);
    s.block_len += 1;
    s.block_len_bytes += len;

    assert(len >= MIN_LEN and len <= MAX_LEN);
    assert(dist >= MIN_DISTANCE and dist <= MAX_DISTANCE);
    s.litlen_freqs[tables.len2litlen[len]] += 1;
    s.dist_freqs[distance2dist(dist)] += 1;

    return true;
}

// PKZip Method 8: Deflate / Inflate.
// Compress (deflate) the data in src into dst. The number of bytes output, at
// most dst_cap, is stored in *dst_used. Returns false if there is not enough
// room in dst. src and dst must not overlap.
pub fn hwdeflate(src: [*]const u8, src_len: usize, dst: [*]u8, dst_cap: usize, dst_used: *usize) bool {
    var s: deflate_state_t = undefined;

    bs.ostream_init(&s.os, dst, dst_cap);
    reset_block(&s);
    s.block_src = src;

    if (!lz.lz77_compress(
        src,
        src_len,
        MAX_DISTANCE,
        MAX_LEN,
        true,
        lit_callback,
        backref_callback,
        &s,
    )) {
        return false;
    }

    if (!write_block(&s, true)) {
        return false;
    }

    // The end of the final block should match the end of src.
    assert(s.block_src + s.block_len_bytes == src + src_len);

    dst_used.* = bs.ostream_bytes_written(&s.os);

    return true;
}
