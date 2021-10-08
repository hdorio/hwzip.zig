// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;

const bits = @import("./bits.zig");

pub const LZ_WND_SIZE = 32768;
const HASH_SIZE = 15;
const NO_POS = math.maxInt(usize);
const MIN_LEN = 4;

// Output a literal byte at dst_pos in dst.
pub inline fn lz77_output_lit(dst: [*]u8, dst_pos: usize, lit: u8) void {
    dst[dst_pos] = lit;
}

// Output the (dist,len) back reference at dst_pos in dst.
pub inline fn lz77_output_backref(dst: [*]u8, dst_pos: usize, dist: usize, len: usize) void {
    var i: usize = 0;
    var pos: usize = dst_pos;

    assert(dist <= pos); // "cannot reference before beginning of dst"

    while (i < len) : (i += 1) {
        dst[pos] = dst[pos - dist];
        pos += 1;
    }
}

// Output the (dist,len) backref at dst_pos in dst using 64-bit wide writes.
// There must be enough room for len bytes rounded to the next multiple of 8.
pub inline fn lz77_output_backref64(dst: [*]u8, dst_pos: usize, dist: usize, len: usize) void {
    var i: usize = 0;
    var tmp: [8]u8 = undefined;

    assert(len > 0);
    assert(dist <= dst_pos); // "cannot reference before beginning of dst"

    if (len > dist) {
        // Self-overlapping backref; fall back to byte-by-byte copy.
        lz77_output_backref(dst, dst_pos, dist, len);
        return;
    }

    while (i < len) : (i += 8) {
        var ref_pos = dst_pos - dist + i;
        var backref_pos = dst_pos + i;

        mem.copy(u8, tmp[0..8], dst[ref_pos .. ref_pos + 8]);
        mem.copy(u8, dst[backref_pos .. backref_pos + 8], tmp[0..8]);
    }
}

// Compare the substrings starting at src[i] and src[j], and return the length
// of the common prefix if it is strictly longer than prev_match_len
// and shorter or equal to max_match_len, otherwise return zero.
pub fn cmp(
    src: [*]const u8,
    i: usize,
    j: usize,
    prev_match_len: usize,
    max_match_len: usize,
) usize {
    var l: usize = 0;

    assert(prev_match_len < max_match_len);

    // Check whether the first prev_match_len + 1 characters match. Do this
    // backwards for a higher chance of finding a mismatch quickly.
    while (l < prev_match_len + 1) : (l += 1) {
        if (src[i + prev_match_len - l] != src[j + prev_match_len - l]) {
            return 0;
        }
    }

    assert(l == prev_match_len + 1);

    // Now check how long the full match is.
    while (l < max_match_len) : (l += 1) {
        if (src[i + l] != src[j + l]) {
            break;
        }
    }

    assert(l > prev_match_len);
    assert(l <= max_match_len);
    assert(mem.eql(u8, src[i .. i + l], src[j .. j + l]));

    return l;
}

pub fn min(a: usize, b: usize) usize {
    if (a < b) {
        return a;
    } else {
        return b;
    }
}

// Find the longest most recent string which matches the string starting
// at src[pos]. The match must be strictly longer than prev_match_len and
// shorter or equal to max_match_len. Returns the length of the match if found
// and stores the match position in *match_pos, otherwise returns zero.
pub fn find_match(
    src: [*]const u8,
    pos: usize,
    hash: u32,
    max_dist: usize,
    prev_match_len: usize,
    max_match_len: usize,
    allow_overlap: bool,
    head: *[1 << HASH_SIZE]usize,
    prev: *[LZ_WND_SIZE]usize,
    match_pos: *usize,
) usize {
    var max_match_steps: usize = 4096;
    var i: usize = undefined;
    var l: usize = undefined;
    var found: bool = undefined;
    var max_cmp: usize = undefined;
    var prev_match_len_result: usize = prev_match_len;

    if (prev_match_len_result == 0) {
        // We want backrefs of length MIN_LEN or longer.
        prev_match_len_result = MIN_LEN - 1;
    }

    if (prev_match_len_result >= max_match_len) {
        // A longer match would be too long.
        return 0;
    }

    if (prev_match_len_result >= 32) {
        // Do not try too hard if there is already a good match.
        max_match_steps /= 4;
    }

    found = false;
    i = head[hash];
    max_cmp = max_match_len;

    // Walk the linked list of prefix positions.
    while (i != NO_POS) : (i = prev[i % LZ_WND_SIZE]) {
        if (max_match_steps == 0) {
            break;
        }
        max_match_steps -= 1;

        assert(i < pos); // "Matches should precede pos."
        if (pos - i > max_dist) {
            // The match is too far back.
            break;
        }

        if (!allow_overlap) {
            max_cmp = min(max_match_len, pos - i);
            if (max_cmp <= prev_match_len_result) {
                continue;
            }
        }

        l = cmp(src, i, pos, prev_match_len_result, max_cmp);

        if (l != 0) {
            assert(l > prev_match_len_result);
            assert(l <= max_match_len);

            found = true;
            match_pos.* = i;
            prev_match_len_result = l;

            if (l == max_match_len) {
                // A longer match is not possible.
                return l;
            }
        }
    }

    if (!found) {
        return 0;
    }

    return prev_match_len_result;
}

// Compute a hash value based on four bytes pointed to by ptr.
pub fn hash4(ptr: [*]const u8) u32 {
    assert(HASH_SIZE >= 0 and HASH_SIZE <= 32);
    const HASH_MUL: u32 = 2654435761;

    // Knuth's multiplicative hash.
    var mult: u32 = undefined;
    _ = @mulWithOverflow(u32, bits.read32le(ptr), HASH_MUL, &mult);
    return mult >> (32 - HASH_SIZE);
}

pub fn insert_hash(hash: u32, pos: usize, head: *[1 << HASH_SIZE]usize, prev: *[LZ_WND_SIZE]usize) void {
    assert(pos != NO_POS); // "Invalid pos!"
    prev[pos % LZ_WND_SIZE] = head[hash];
    head[hash] = pos;
}

// Perform LZ77 compression on the src_len bytes in src, with back references
// limited to a certain maximum distance and length, and with or without
// self-overlap. Returns false as soon as either of the callback functions
// returns false, otherwise returns true when all bytes have been processed.
//
// A back reference is a tupple consisting of a distance and a length, this tupple refers to a part
// of the previous content.
// The distance is the number of bytes between the start of the referenced content and the start of
// the back reference.
// The length is the size in bytes of the referenced content.
// Self-overlap is the fact that a referenced content overlaps with its back reference space and
// means that in order to retrieve the referenced content the back reference will refer to itself.
//
// Example with no self-overlap:
//
//                                          ┌ back reference position
//        ┌ referenced content              │
//       ┌3┐                                ╵
// CATS: YOU HAVE NO CHANCE TO SURVIVE MAKE YOUR TIME.
//                                          └3┘ (length)
//       <───────────────35─────────────────┘   (distance)
//
//                                             ┌ back reference
//                                          ┌──┴──┐
// CATS: YOU HAVE NO CHANCE TO SURVIVE MAKE (35, 3)R TIME.
//
// Example with self-overlap:
//
//          ┌ back reference position
//          │
//          │ ┌─── referenced content
//       ┌──┼─8──┐
// CATS: HA HA HA HA ....
//          └───8───┘ (length)
//       <─3┘         (distance)
//
//             ┌ back reference
//          ┌──┴─┐
// CATS: HA (3, 8)....
//
pub fn lz77_compress(
    src: [*]const u8,
    src_len: usize,
    max_dist: usize,
    max_len: usize,
    allow_overlap: bool,
    comptime lit_callback: fn (lit: u8, aux: anytype) bool,
    comptime backref_callback: fn (dist: usize, len: usize, aux: anytype) bool,
    aux: anytype,
) bool {
    var head: [1 << HASH_SIZE]usize = undefined; // 1u  // maps the hash value of a four-letter prefix to a position in the input data
    var prev: [LZ_WND_SIZE]usize = undefined; // maps a position to the previous position with the same hash value

    var i: usize = 0;
    var h: u32 = undefined;
    var dist: usize = undefined;
    var match_len: usize = undefined;
    var match_pos: usize = undefined;
    var prev_match_len: usize = undefined;
    var prev_match_pos: usize = undefined;

    // Initialize the hash table.
    for (head) |_, hi| {
        head[hi] = NO_POS;
    }

    prev_match_len = 0;
    prev_match_pos = NO_POS;

    while (i + MIN_LEN - 1 < src_len) : (i += 1) {
        // Search for a match using the hash table.
        h = hash4(src[i .. i + 4].ptr);
        match_len = find_match(src, i, h, max_dist, prev_match_len, min(max_len, src_len - i), allow_overlap, &head, &prev, &match_pos);

        // Insert the current hash for future searches.
        insert_hash(h, i, &head, &prev);

        // If the previous match is at least as good as the current.
        if (prev_match_len != 0 and prev_match_len >= match_len) {
            // Output the previous match.
            dist = (i - 1) - prev_match_pos;
            if (!backref_callback(dist, prev_match_len, aux)) {
                return false;
            }
            // Move past the match.
            {
                var j: usize = i + 1;

                //for (j = i + 1; j < min((i - 1) + prev_match_len, src_len - (MIN_LEN - 1)); j++) {
                while (j < min((i - 1) + prev_match_len, src_len - (MIN_LEN - 1))) : (j += 1) {
                    h = hash4(src[j .. j + 4].ptr);
                    insert_hash(h, j, &head, &prev);
                }
            }
            i = (i - 1) + prev_match_len - 1;
            prev_match_len = 0;
            continue;
        }

        // If no match (and no previous match), output literal.
        if (match_len == 0) {
            assert(prev_match_len == 0);
            if (!lit_callback(src[i], aux)) {
                return false;
            }
            continue;
        }

        // Otherwise the current match is better than the previous.

        if (prev_match_len != 0) {
            // Output a literal instead of the previous match.
            if (!lit_callback(src[i - 1], aux)) {
                return false;
            }
        }

        // Defer this match and see if the next is even better.
        prev_match_len = match_len;
        prev_match_pos = match_pos;
    }

    // Output any previous match.
    if (prev_match_len != 0) {
        dist = (i - 1) - prev_match_pos;
        if (!backref_callback(dist, prev_match_len, aux)) {
            return false;
        }
        i = (i - 1) + prev_match_len;
    }

    // Output any remaining literals.
    while (i < src_len) : (i += 1) {
        if (!lit_callback(src[i], aux)) {
            return false;
        }
    }

    return true;
}
