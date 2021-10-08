// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const sort = std.sort;

const bits_utils = @import("./bits.zig");
const bs = @import("./bitstream.zig");
const lz = @import("./lz77.zig");

const UINT8_MAX = math.maxInt(u8);

pub const expand_stat_t = enum {
    HWEXPAND_OK, // Expand was successful.
    HWEXPAND_ERR, // Error in the input data.
};

fn block_sort(items: []follower_t, t: anytype, comptime lessThan: anytype) void {
    _ = sort.sort(t, items, {}, lessThan);
}

// Number of bits used to represent indices in a follower set of size n.
fn num_to_follower_idx_bw(n: usize) u8 {
    assert(n <= 32);

    if (n > 16) {
        return 5;
    }
    if (n > 8) {
        return 4;
    }
    if (n > 4) {
        return 3;
    }
    if (n > 2) {
        return 2;
    }
    if (n > 0) {
        return 1;
    }
    return 0;
}

const follower_set_t: type = struct {
    size: u8,
    idx_bw: u8,
    followers: [32]u8,
};

// Read the follower sets from is into fsets. Returns true on success.
fn read_follower_sets(is: *bs.istream_t, fsets: [*]follower_set_t) bool {
    var i: u8 = 0;
    var j: u8 = 0;
    var n: u8 = 0;

    i = 255;
    while (i >= 0) : (i -= 1) {
        n = @intCast(u8, bits_utils.lsb(bs.istream_bits(is), 6));
        if (n > 32) {
            return false;
        }
        if (!bs.istream_advance(is, 6)) {
            return false;
        }
        fsets[i].size = n;
        fsets[i].idx_bw = num_to_follower_idx_bw(n);

        j = 0;
        while (j < fsets[i].size) : (j += 1) {
            fsets[i].followers[j] = @truncate(u8, bs.istream_bits(is));
            if (!bs.istream_advance(is, 8)) {
                return false;
            }
        }

        if (i == 0) break;
    }

    return true;
}

// Read the next byte from is, decoded based on prev_byte and the follower sets.
// The byte is returned in *out_byte. The function returns true on success,
// and false on bad data or end of input.
fn read_next_byte(is: *bs.istream_t, prev_byte: u8, fsets: [*]const follower_set_t, out_byte: *u8) bool {
    var bits: u64 = 0;
    var idx_bw: u8 = 0;
    var follower_idx: u8 = 0;

    bits = bs.istream_bits(is);

    if (fsets[prev_byte].size == 0) {
        // No followers; read a literal byte.
        out_byte.* = @truncate(u8, bits);
        return bs.istream_advance(is, 8);
    }

    if (bits_utils.lsb(bits, 1) == 1) {
        // Don't use the follower set; read a literal byte.
        out_byte.* = @truncate(u8, bits >> 1);
        return bs.istream_advance(is, 1 + 8);
    }

    // The bits represent the index of a follower byte.
    idx_bw = fsets[prev_byte].idx_bw;
    follower_idx = @intCast(u8, bits_utils.lsb(bits >> 1, @intCast(u6, idx_bw)));
    if (follower_idx >= fsets[prev_byte].size) {
        return false;
    }
    out_byte.* = fsets[prev_byte].followers[follower_idx];
    return bs.istream_advance(is, 1 + idx_bw);
}

fn max_len(comp_factor: u3) usize {
    var v_len_bits: usize = @as(usize, 8) - @intCast(usize, comp_factor);

    assert(comp_factor >= 1 and comp_factor <= 4);

    // Bits in V + extra len byte + implicit 3.
    return ((@as(u16, 1) << @intCast(u4, v_len_bits)) - 1) + 255 + 3;
}

fn max_dist(comp_factor: u3) usize {
    var v_dist_bits: usize = @intCast(usize, comp_factor);

    assert(comp_factor >= 1 and comp_factor <= 4);

    // Bits in V * 256 + W byte + implicit 1.
    return ((@as(u16, 1) << @intCast(u4, v_dist_bits)) - 1) * 256 + 255 + 1;
}

const DLE_BYTE = 144;

// Decompress (expand) the data in src. The uncompressed data is uncomp_len
// bytes long and was compressed with comp_factor. The number of input bytes
// used, at most src_len, is written to *src_used on success. Output is written
// to dst.
pub fn hwexpand(
    src: [*]const u8,
    src_len: usize,
    uncomp_len: usize,
    comp_factor: u3,
    src_used: *usize,
    dst: [*]u8,
) expand_stat_t {
    var is: bs.istream_t = undefined;
    var fsets: [256]follower_set_t = undefined;
    var v_len_bits: usize = 0;
    var dst_pos: usize = 0;
    var len: usize = 0;
    var dist: usize = 0;
    var i: usize = 0;
    var curr_byte: u8 = 0;
    var v: u8 = 0;

    assert(comp_factor >= 1 and comp_factor <= 4);

    bs.istream_init(&is, src, src_len);
    if (!read_follower_sets(&is, &fsets)) {
        return expand_stat_t.HWEXPAND_ERR;
    }

    // Number of bits in V used for backref length.
    v_len_bits = @as(usize, 8) - @intCast(usize, comp_factor);

    dst_pos = 0;
    curr_byte = 0; // The first "previous byte" is implicitly zero.

    while (dst_pos < uncomp_len) {
        // Read a literal byte or DLE marker.
        if (!read_next_byte(&is, curr_byte, &fsets, &curr_byte)) {
            return expand_stat_t.HWEXPAND_ERR;
        }
        if (curr_byte != DLE_BYTE) {
            // Output a literal byte.
            dst[dst_pos] = curr_byte;
            dst_pos += 1;
            continue;
        }

        // Read the V byte which determines the length.
        if (!read_next_byte(&is, curr_byte, &fsets, &curr_byte)) {
            return expand_stat_t.HWEXPAND_ERR;
        }
        if (curr_byte == 0) {
            // Output a literal DLE byte.
            dst[dst_pos] = DLE_BYTE;
            dst_pos += 1;
            continue;
        }
        v = curr_byte;
        len = @intCast(usize, bits_utils.lsb(v, @intCast(u6, v_len_bits)));
        if (len == (@as(u16, 1) << @intCast(u4, v_len_bits)) - 1) {
            // Read an extra length byte.
            if (!read_next_byte(&is, curr_byte, &fsets, &curr_byte)) {
                return expand_stat_t.HWEXPAND_ERR;
            }
            len += curr_byte;
        }
        len += 3;

        // Read the W byte, which together with V gives the distance.
        if (!read_next_byte(&is, curr_byte, &fsets, &curr_byte)) {
            return expand_stat_t.HWEXPAND_ERR;
        }
        dist = @intCast(usize, (v >> @intCast(u3, v_len_bits))) * 256 + curr_byte + 1;

        assert(len <= max_len(comp_factor));
        assert(dist <= max_dist(comp_factor));

        // Output the back reference.
        if (bits_utils.round_up(len, 8) <= uncomp_len - dst_pos and
            dist <= dst_pos)
        {
            // Enough room and no implicit zeros; chunked copy.
            lz.lz77_output_backref64(dst, dst_pos, dist, len);
            dst_pos += len;
        } else if (len > uncomp_len - dst_pos) {
            // Not enough room.
            return expand_stat_t.HWEXPAND_ERR;
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

    return expand_stat_t.HWEXPAND_OK;
}

const RAW_BYTES_SZ = (64 * 1024);
const NO_FOLLOWER_IDX = UINT8_MAX;

const reduce_state_t: type = struct {
    os: bs.ostream_t,
    comp_factor: u3,
    prev_byte: u8,
    raw_bytes_flushed: bool,

    // Raw bytes buffer.
    raw_bytes: [RAW_BYTES_SZ]u8,
    num_raw_bytes: usize,

    // Map from (prev_byte,curr_byte) to follower_idx or NO_FOLLOWER_IDX.
    follower_idx: [256][256]u8,
    follower_idx_bw: [256]u8,
};

const follower_t: type = struct {
    byte: u8,
    count: usize,
};

fn follower_cmp(context: void, a: follower_t, b: follower_t) bool {
    _ = context;
    var l: follower_t = a;
    var r: follower_t = b;

    // Sort descending by count.
    if (l.count > r.count) {
        return true;
    }
    if (l.count < r.count) {
        return false;
    }

    // Break ties by sorting ascending by byte.
    if (l.byte < r.byte) {
        return true;
    }
    if (l.byte > r.byte) {
        return false;
    }

    assert(l.count == r.count and l.byte == r.byte);
    return false;
}

// The cost in bits for writing the follower bytes using follower set size n.
fn followers_cost(followers: [*]const follower_t, n: usize) usize {
    var cost: usize = 0;
    var i: usize = 0;

    // Cost for storing the follower set.
    cost = n * 8;

    // Cost for follower bytes in the set.
    i = 0;
    while (i < n) : (i += 1) {
        cost += followers[i].count * (1 + num_to_follower_idx_bw(n));
    }
    // Cost for follower bytes not in the set.
    while (i < 256) : (i += 1) {
        if (n == 0) {
            cost += followers[i].count * 8;
        } else {
            cost += followers[i].count * (1 + 8);
        }
    }

    return cost;
}

// Compute and write the follower sets based on the raw bytes buffer.
fn write_follower_sets(s: *reduce_state_t) bool {
    var follower_count: [256][256]usize = [_][256]usize{[1]usize{0} ** 256} ** 256;
    var followers: [256]follower_t = undefined;
    var prev_byte: u8 = 0;
    var curr_byte: u8 = 0;
    var i: usize = 0;
    var cost: usize = 0;
    var min_cost: usize = 0;
    var min_cost_size: usize = 0;

    // Count followers.
    prev_byte = 0;
    i = 0;
    while (i < s.num_raw_bytes) : (i += 1) {
        curr_byte = s.raw_bytes[i];
        follower_count[prev_byte][curr_byte] += 1;
        prev_byte = curr_byte;
    }

    curr_byte = UINT8_MAX;
    while (curr_byte >= 0) : (curr_byte -= 1) {
        // Initialize follower indices to invalid.
        i = 0;
        while (i <= UINT8_MAX) : (i += 1) {
            s.follower_idx[curr_byte][i] = NO_FOLLOWER_IDX;
            if (i == UINT8_MAX) break;
        }

        // Sort the followers for curr_byte.
        i = 0;
        while (i <= UINT8_MAX) : (i += 1) {
            followers[i].byte = @intCast(u8, i);
            followers[i].count = follower_count[curr_byte][i];
            if (i == UINT8_MAX) break; // avoid i overflow
        }
        block_sort(&followers, follower_t, follower_cmp); // originaly qsort() C function replaced by block_sort for convenience

        // Find the follower set size with the lowest cost.
        min_cost_size = 0;
        min_cost = followers_cost(&followers, 0);
        i = 1;
        while (i <= 32) : (i += 1) {
            cost = followers_cost(&followers, i);
            if (cost < min_cost) {
                min_cost_size = i;
                min_cost = cost;
            }
        }

        // Save the follower indices.
        i = 0;
        while (i < min_cost_size) : (i += 1) {
            s.follower_idx[curr_byte][followers[i].byte] = @intCast(u8, i);
        }
        s.follower_idx_bw[curr_byte] = num_to_follower_idx_bw(min_cost_size);

        // Write the followers.
        if (!bs.ostream_write(&s.os, min_cost_size, 6)) {
            return false;
        }
        i = 0;
        while (i < min_cost_size) : (i += 1) {
            if (!bs.ostream_write(&s.os, followers[i].byte, 8)) {
                return false;
            }
        }

        if (curr_byte == 0) break; // avoid curr_byte underflow
    }

    return true;
}

fn flush_raw_bytes(s: *reduce_state_t) bool {
    var i: usize = 0;

    s.raw_bytes_flushed = true;

    if (!write_follower_sets(s)) {
        return false;
    }

    i = 0;
    while (i < s.num_raw_bytes) : (i += 1) {
        if (!write_byte(s, s.raw_bytes[i])) {
            return false;
        }
    }

    return true;
}

fn write_byte(s: *reduce_state_t, byte: u8) bool {
    var follower_idx: u8 = 0;
    var follower_idx_bw: u8 = 0;

    if (!s.raw_bytes_flushed) {
        // Accumulate bytes which will be used for computing the follower sets.
        assert(s.num_raw_bytes < RAW_BYTES_SZ);
        s.raw_bytes[s.num_raw_bytes] = byte;
        s.num_raw_bytes += 1;

        if (s.num_raw_bytes == RAW_BYTES_SZ) {
            // Write follower sets and flush the bytes.
            return flush_raw_bytes(s);
        }

        return true;
    }

    follower_idx = s.follower_idx[s.prev_byte][byte];
    follower_idx_bw = s.follower_idx_bw[s.prev_byte];
    s.prev_byte = byte;

    if (follower_idx != NO_FOLLOWER_IDX) {
        // Write (LSB-first) a 0 bit followed by the follower index.
        return bs.ostream_write(
            &s.os,
            @intCast(u64, follower_idx) << 1,
            follower_idx_bw + 1,
        );
    }

    if (follower_idx_bw != 0) {
        // Not using the follower set.
        // Write (LSB-first) a 1 bit followed by the literal byte.
        return bs.ostream_write(&s.os, (@intCast(u64, byte) << 1) | 0x1, 9);
    }

    // No follower set; write the literal byte.
    return bs.ostream_write(&s.os, byte, 8);
}

fn lit_callback(lit: u8, aux: anytype) bool {
    var s: *reduce_state_t = aux;

    if (!write_byte(s, lit)) {
        return false;
    }

    if (lit == DLE_BYTE) {
        return write_byte(s, 0);
    }

    return true;
}

inline fn min(a: usize, b: usize) usize {
    return if (a < b) a else b;
}

fn backref_callback(distance: usize, length: usize, aux: anytype) bool {
    var s: *reduce_state_t = aux;
    var v_len_bits: usize = @as(usize, 8) - @intCast(usize, s.comp_factor);
    var v: u8 = 0;
    var elb: u8 = 0;
    var w: u8 = 0;
    var len: usize = 0;
    var dist: usize = 0;

    len = length;
    dist = distance;

    assert(len >= 3 and len <= max_len(s.comp_factor));
    assert(dist >= 1 and dist <= max_dist(s.comp_factor));

    assert(len <= dist); // "Backref shouldn't self-overlap."

    // The implicit part of len and dist are not encoded.
    len -= 3;
    dist -= 1;

    // Write the DLE marker.
    if (!write_byte(s, DLE_BYTE)) {
        return false;
    }

    // Write V.
    v = @intCast(u8, min(len, (@as(u16, 1) << @intCast(u4, v_len_bits)) - 1));
    assert(dist / 256 <= (@as(u16, 1) << @intCast(u4, s.comp_factor)) - 1);
    v |= @intCast(u8, (dist / 256) << @intCast(u6, v_len_bits));
    assert(v != 0); // "The byte following DLE must be non-zero."
    if (!write_byte(s, v)) {
        return false;
    }

    if (len >= (@as(u16, 1) << @intCast(u4, v_len_bits)) - 1) {
        // Write extra length byte.
        assert(len - ((@as(u16, 1) << @intCast(u4, v_len_bits)) - 1) <= UINT8_MAX);
        elb = @intCast(u8, len - ((@as(u16, 1) << @intCast(u4, v_len_bits)) - 1));
        if (!write_byte(s, elb)) {
            return false;
        }
    }

    // Write W.
    w = @intCast(u8, dist % 256);

    if (!write_byte(s, w)) {
        return false;
    }

    return true;
}

// Compress (reduce) the data in src into dst using the specified compression
// factor (1--4). The number of bytes output, at most dst_cap, is stored in
// *dst_used. Returns false if there is not enough room in dst.
pub fn hwreduce(
    src: [*]const u8,
    src_len: usize,
    comp_factor: u3,
    dst: [*]u8,
    dst_cap: usize,
    dst_used: *usize,
) bool {
    var s: reduce_state_t = undefined;

    bs.ostream_init(&s.os, dst, dst_cap);
    s.comp_factor = comp_factor;
    s.prev_byte = 0;
    s.raw_bytes_flushed = false;
    s.num_raw_bytes = 0;

    if (!lz.lz77_compress(
        src,
        src_len,
        max_dist(comp_factor),
        max_len(comp_factor),
        false, // allow_overlap=false,
        lit_callback,
        backref_callback,
        &s,
    )) {
        return false;
    }

    if (!s.raw_bytes_flushed and !flush_raw_bytes(&s)) {
        return false;
    }

    dst_used.* = bs.ostream_bytes_written(&s.os);

    return true;
}
