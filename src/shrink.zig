// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;

const bs = @import("./bitstream.zig");
const bits_utils = @import("./bits.zig");

const UINT8_MAX = math.maxInt(u8);
const UINT16_MAX = math.maxInt(u16);
const CHAR_BIT = 8;

const MIN_CODE_SIZE = 9;
const MAX_CODE_SIZE = 13;

const MAX_CODE = ((@as(u16, 1) << MAX_CODE_SIZE) - 1);
const INVALID_CODE = UINT16_MAX;
const CONTROL_CODE = 256;
const INC_CODE_SIZE = 1;
const PARTIAL_CLEAR = 2;

const HASH_BITS = (MAX_CODE_SIZE + 1); // For a load factor of 0.5.
const HASHTAB_SIZE = (@as(u16, 1) << HASH_BITS);
const UNKNOWN_LEN = UINT16_MAX;

pub const unshrnk_stat_t: type = enum {
    HWUNSHRINK_OK, // Unshrink was successful.
    HWUNSHRINK_FULL, // Not enough room in the output buffer.
    HWUNSHRINK_ERR, // Error in the input data.
};

// Hash table where the keys are (prefix_code, ext_byte) pairs, and the values
// are the corresponding code. If prefix_code is INVALID_CODE it means the hash
// table slot is empty.
const hashtab_t: type = struct {
    prefix_code: u16,
    ext_byte: u8,
    code: u16,
};

fn hashtab_init(table: [*]hashtab_t) void {
    var i: usize = 0;

    while (i < HASHTAB_SIZE) : (i += 1) {
        table[i].prefix_code = INVALID_CODE;
    }
}

fn hash(code: u16, byte: u8) u32 {
    const Static = struct {
        const HASH_MUL: u32 = @as(u32, 2654435761); // 2654435761U
    };

    // Knuth's multiplicative hash.
    var mult: u32 = @mulWithOverflow((@intCast(u32, byte) << 16) | code, Static.HASH_MUL)[0];
    return (mult) >> (32 - HASH_BITS);
}

// Return the code corresponding to a prefix code and extension byte if it
// exists in the table, or INVALID_CODE otherwise.
fn hashtab_find(
    table: [*]const hashtab_t,
    prefix_code: u16,
    ext_byte: u8,
) u16 {
    var i: usize = hash(prefix_code, ext_byte);

    assert(prefix_code != INVALID_CODE);

    while (true) {
        // Scan until we find the key or an empty slot.
        assert(i < HASHTAB_SIZE);
        if (table[i].prefix_code == prefix_code and
            table[i].ext_byte == ext_byte)
        {
            return table[i].code;
        }
        if (table[i].prefix_code == INVALID_CODE) {
            return INVALID_CODE;
        }
        i = (i + 1) % HASHTAB_SIZE;
        assert(i != hash(prefix_code, ext_byte));
    }
}

fn hashtab_insert(
    table: [*]hashtab_t,
    prefix_code: u16,
    ext_byte: u8,
    code: u16,
) void {
    var i: usize = hash(prefix_code, ext_byte);

    assert(prefix_code != INVALID_CODE);
    assert(code != INVALID_CODE);
    assert(hashtab_find(table, prefix_code, ext_byte) == INVALID_CODE);

    while (true) {
        // Scan until we find an empty slot.
        assert(i < HASHTAB_SIZE);
        if (table[i].prefix_code == INVALID_CODE) {
            break;
        }
        i = (i + 1) % HASHTAB_SIZE;
        assert(i != hash(prefix_code, ext_byte));
    }

    assert(i < HASHTAB_SIZE);
    table[i].code = code;
    table[i].prefix_code = prefix_code;
    table[i].ext_byte = ext_byte;

    assert(hashtab_find(table, prefix_code, ext_byte) == code);
}

const code_queue_t: type = struct {
    next_idx: u16,
    codes: [MAX_CODE - CONTROL_CODE + 1]u16,
};

fn code_queue_init(q: *code_queue_t) void {
    var code_queue_size: usize = 0;
    var code: u16 = 0;

    code_queue_size = 0;
    code = CONTROL_CODE + 1;
    while (code <= MAX_CODE) : (code += 1) {
        q.codes[code_queue_size] = code;
        code_queue_size += 1;
    }
    assert(code_queue_size < q.codes.len);
    q.codes[code_queue_size] = INVALID_CODE; // End-of-queue marker.
    q.next_idx = 0;
}

// Return the next code in the queue, or INVALID_CODE if the queue is empty.
fn code_queue_next(q: *const code_queue_t) u16 {
    assert(q.next_idx < q.codes.len);
    return q.codes[q.next_idx];
}

// Return and remove the next code from the queue, or return INVALID_CODE if
// the queue is empty.
fn code_queue_remove_next(q: *code_queue_t) u16 {
    var code: u16 = code_queue_next(q);
    if (code != INVALID_CODE) {
        q.next_idx += 1;
    }
    return code;
}

// Write a code to the output bitstream, increasing the code size if necessary.
// Returns true on success.
fn write_code(os: *bs.ostream_t, code: u16, code_size: *usize) bool {
    assert(code <= MAX_CODE);

    while (code > (@as(u16, 1) << @intCast(u4, code_size.*)) - 1) {
        // Increase the code size.
        assert(code_size.* < MAX_CODE_SIZE);
        if (!bs.ostream_write(os, CONTROL_CODE, code_size.*) or
            !bs.ostream_write(os, INC_CODE_SIZE, code_size.*))
        {
            return false;
        }
        code_size.* += 1;
    }

    return bs.ostream_write(os, code, code_size.*);
}

fn shrink_partial_clear(hashtab: [*]hashtab_t, queue: *code_queue_t) void {
    var is_prefix: [MAX_CODE + 1]bool = [_]bool{false} ** (MAX_CODE + 1);
    var new_hashtab: [HASHTAB_SIZE]hashtab_t = undefined;
    var i: usize = 0;
    var code_queue_size: usize = 0;

    // Scan for codes that have been used as a prefix.
    i = 0;
    while (i < HASHTAB_SIZE) : (i += 1) {
        if (hashtab[i].prefix_code != INVALID_CODE) {
            is_prefix[hashtab[i].prefix_code] = true;
        }
    }

    // Build a new hash table with only the "prefix codes".
    hashtab_init(&new_hashtab);
    i = 0;
    while (i < HASHTAB_SIZE) : (i += 1) {
        if (hashtab[i].prefix_code == INVALID_CODE or
            !is_prefix[hashtab[i].code])
        {
            continue;
        }
        hashtab_insert(
            &new_hashtab,
            hashtab[i].prefix_code,
            hashtab[i].ext_byte,
            hashtab[i].code,
        );
    }
    mem.copy(hashtab_t, hashtab[0..new_hashtab.len], new_hashtab[0..new_hashtab.len]);

    // Populate the queue with the "non-prefix" codes.
    code_queue_size = 0;
    i = CONTROL_CODE + 1;
    while (i <= MAX_CODE) : (i += 1) {
        if (!is_prefix[i]) {
            queue.codes[code_queue_size] = @intCast(u16, i);
            code_queue_size += 1;
        }
    }
    queue.codes[code_queue_size] = INVALID_CODE; // End-of-queue marker.
    queue.next_idx = 0;
}

// Compress (shrink) the data in src into dst. The number of bytes output, at
// most dst_cap, is stored in *dst_used. Returns false if there is not enough
// room in dst.
pub fn hwshrink(
    src: [*]const u8,
    src_len: usize,
    dst: [*]u8,
    dst_cap: usize,
    dst_used: *usize,
) bool {
    var table: [HASHTAB_SIZE]hashtab_t = undefined;
    var queue: code_queue_t = undefined;
    var os: bs.ostream_t = undefined;
    var code_size: usize = 0;
    var i: usize = 0;
    var ext_byte: u8 = 0;
    var curr_code: u16 = 0;
    var next_code: u16 = 0;
    var new_code: u16 = 0;

    hashtab_init(&table);
    code_queue_init(&queue);
    bs.ostream_init(&os, dst, dst_cap);
    code_size = MIN_CODE_SIZE;

    if (src_len == 0) {
        dst_used.* = 0;
        return true;
    }

    curr_code = src[0];

    i = 1;
    while (i < src_len) : (i += 1) {
        ext_byte = src[i];

        // Search for a code with the current prefix + byte.
        next_code = hashtab_find(&table, curr_code, ext_byte);
        if (next_code != INVALID_CODE) {
            curr_code = next_code;
            continue;
        }

        // Write out the current code.
        if (!write_code(&os, curr_code, &code_size)) {
            return false;
        }

        // Assign a new code to the current prefix + byte.
        new_code = code_queue_remove_next(&queue);
        if (new_code == INVALID_CODE) {
            // Try freeing up codes by partial clearing.
            shrink_partial_clear(&table, &queue);
            if (!bs.ostream_write(&os, CONTROL_CODE, code_size) or
                !bs.ostream_write(&os, PARTIAL_CLEAR, code_size))
            {
                return false;
            }
            new_code = code_queue_remove_next(&queue);
        }
        if (new_code != INVALID_CODE) {
            hashtab_insert(&table, curr_code, ext_byte, new_code);
        }

        // Reset the parser starting at the byte.
        curr_code = ext_byte;
    }

    // Write out the last code.
    if (!write_code(&os, curr_code, &code_size)) {
        return false;
    }

    dst_used.* = bs.ostream_bytes_written(&os);
    return true;
}

const codetab_t: type = struct {
    prefix_code: u16, // INVALID_CODE means the entry is invalid.
    ext_byte: u8,
    len: u16,
    last_dst_pos: usize,
};

fn codetab_init(codetab: [*]codetab_t) void {
    var i: usize = 0;

    // Codes for literal bytes. Set a phony prefix_code so they're valid.
    i = 0;
    while (i <= UINT8_MAX) : (i += 1) {
        codetab[i].prefix_code = @intCast(u16, i);
        codetab[i].ext_byte = @intCast(u8, i);
        codetab[i].len = 1;
    }

    while (i <= MAX_CODE) : (i += 1) {
        codetab[i].prefix_code = INVALID_CODE;
    }
}

fn unshrink_partial_clear(codetab: [*]codetab_t, queue: *code_queue_t) void {
    var is_prefix: [MAX_CODE + 1]bool = [_]bool{false} ** (MAX_CODE + 1);
    var i: usize = 0;
    var code_queue_size: usize = 0;

    // Scan for codes that have been used as a prefix.
    i = CONTROL_CODE + 1;
    while (i <= MAX_CODE) : (i += 1) {
        if (codetab[i].prefix_code != INVALID_CODE) {
            is_prefix[codetab[i].prefix_code] = true;
        }
    }

    // Clear "non-prefix" codes in the table; populate the code queue.
    code_queue_size = 0;
    i = CONTROL_CODE + 1;
    while (i <= MAX_CODE) : (i += 1) {
        if (!is_prefix[i]) {
            codetab[i].prefix_code = INVALID_CODE;
            queue.codes[code_queue_size] = @intCast(u16, i);
            code_queue_size += 1;
        }
    }
    queue.codes[code_queue_size] = INVALID_CODE; // End-of-queue marker.
    queue.next_idx = 0;
}

// Read the next code from the input stream and return it in next_code. Returns
// false if the end of the stream is reached. If the stream contains invalid
// data, next_code is set to INVALID_CODE but the return value is still true.
fn read_code(
    is: *bs.istream_t,
    code_size: *usize,
    codetab: [*]codetab_t,
    queue: *code_queue_t,
    next_code: *u16,
) bool {
    var code: u16 = 0;
    var control_code: u16 = 0;

    assert(@sizeOf(u16) * CHAR_BIT >= code_size.*);

    code = @intCast(u16, bits_utils.lsb(bs.istream_bits(is), @intCast(u6, code_size.*)));
    if (!bs.istream_advance(is, code_size.*)) {
        return false;
    }

    // Handle regular codes (the common case).
    if (code != CONTROL_CODE) {
        next_code.* = code;
        return true;
    }

    // Handle control codes.
    control_code = @intCast(u16, bits_utils.lsb(bs.istream_bits(is), @intCast(u6, code_size.*)));
    if (!bs.istream_advance(is, code_size.*)) {
        next_code.* = INVALID_CODE;
        return true;
    }
    if (control_code == INC_CODE_SIZE and code_size.* < MAX_CODE_SIZE) {
        code_size.* += 1;
        return read_code(is, code_size, codetab, queue, next_code);
    }
    if (control_code == PARTIAL_CLEAR) {
        unshrink_partial_clear(codetab, queue);
        return read_code(is, code_size, codetab, queue, next_code);
    }
    next_code.* = INVALID_CODE;
    return true;
}

// Copy len bytes from dst[prev_pos] to dst[dst_pos].
fn copy_from_prev_pos(
    dst: [*]u8,
    dst_cap: usize,
    prev_pos: usize,
    dst_pos: usize,
    len: usize,
) void {
    var i: usize = 0;
    var tmp: [8]u8 = [1]u8{0} ** 8;

    assert(dst_pos < dst_cap);
    assert(prev_pos < dst_pos);
    assert(len > 0);
    assert(len <= dst_cap - dst_pos);

    if (bits_utils.round_up(len, 8) > dst_cap - dst_pos) {
        // Not enough room in dst for the sloppy copy below.
        mem.copy(u8, dst[dst_pos .. dst_pos + len], dst[prev_pos .. prev_pos + len]);
        return;
    }

    if (prev_pos + len > dst_pos) {
        // Benign one-byte overlap possible in the KwKwK case.
        assert(prev_pos + len == dst_pos + 1);
        assert(dst[prev_pos] == dst[prev_pos + len - 1]);
    }

    i = 0;
    while (i < len) : (i += 8) {
        // Sloppy copy: 64 bits at a time; a few extra don't matter.
        // we need a tmp buffer since (dst_pos + i) can be after (prev_pos + i);
        mem.copy(u8, tmp[0..], dst[prev_pos + i .. prev_pos + i + 8]);
        mem.copy(u8, dst[dst_pos + i .. dst_pos + i + 8], tmp[0..]);
    }
}

// Output the string represented by a code into dst at dst_pos. Returns
// HWUNSHRINK_OK on success, and also updates *first_byte and *len with the
// first byte and length of the output string, respectively.
fn output_code(
    code: u16,
    dst: [*]u8,
    dst_pos: usize,
    dst_cap: usize,
    prev_code: u16,
    codetab: [*]codetab_t,
    queue: *code_queue_t,
    first_byte: *u8,
    len: *usize,
) unshrnk_stat_t {
    var prefix_code: u16 = 0;

    assert(code <= MAX_CODE and code != CONTROL_CODE);
    assert(dst_pos < dst_cap);

    if (code <= UINT8_MAX) {
        // Output literal byte.
        first_byte.* = @intCast(u8, code);
        len.* = 1;
        dst[dst_pos] = @intCast(u8, code);
        return unshrnk_stat_t.HWUNSHRINK_OK;
    }

    if (codetab[code].prefix_code == INVALID_CODE or
        codetab[code].prefix_code == code)
    {
        // Reject invalid codes. Self-referential codes may exist in
        // the table but cannot be used.
        return unshrnk_stat_t.HWUNSHRINK_ERR;
    }

    if (codetab[code].len != UNKNOWN_LEN) {
        // Output string with known length (the common case).
        if (dst_cap - dst_pos < codetab[code].len) {
            return unshrnk_stat_t.HWUNSHRINK_FULL;
        }
        copy_from_prev_pos(dst, dst_cap, codetab[code].last_dst_pos, dst_pos, codetab[code].len);
        first_byte.* = dst[dst_pos];
        len.* = codetab[code].len;
        return unshrnk_stat_t.HWUNSHRINK_OK;
    }

    // Output a string of unknown length. This happens when the prefix
    // was invalid (due to partial clearing) when the code was inserted into
    // the table. The prefix can then become valid when it's added to the
    // table at a later point.
    assert(codetab[code].len == UNKNOWN_LEN);
    prefix_code = codetab[code].prefix_code;
    assert(prefix_code > CONTROL_CODE);

    if (prefix_code == code_queue_next(queue)) {
        // The prefix code hasn't been added yet, but we were just
        // about to: the KwKwK case. Add the previous string extended
        // with its first byte.
        assert(codetab[prev_code].prefix_code != INVALID_CODE);
        codetab[prefix_code].prefix_code = prev_code;
        codetab[prefix_code].ext_byte = first_byte.*;
        codetab[prefix_code].len = codetab[prev_code].len + 1;
        codetab[prefix_code].last_dst_pos = codetab[prev_code].last_dst_pos;
        dst[dst_pos] = first_byte.*;
    } else if (codetab[prefix_code].prefix_code == INVALID_CODE) {
        // The prefix code is still invalid.
        return unshrnk_stat_t.HWUNSHRINK_ERR;
    }

    // Output the prefix string, then the extension byte.
    len.* = codetab[prefix_code].len + 1;
    if (dst_cap - dst_pos < len.*) {
        return unshrnk_stat_t.HWUNSHRINK_FULL;
    }
    copy_from_prev_pos(dst, dst_cap, codetab[prefix_code].last_dst_pos, dst_pos, codetab[prefix_code].len);
    dst[dst_pos + len.* - 1] = codetab[code].ext_byte;
    first_byte.* = dst[dst_pos];

    // Update the code table now that the string has a length and pos.
    assert(prev_code != code);
    codetab[code].len = @intCast(u16, len.*);
    codetab[code].last_dst_pos = dst_pos;

    return unshrnk_stat_t.HWUNSHRINK_OK;
}

// Decompress (unshrink) the data in src. The number of input bytes used, at
// most src_len, is stored in *src_used on success. Output is written to dst.
// The number of bytes written, at most dst_cap, is stored in *dst_used on
// success.
pub fn hwunshrink(
    src: [*]const u8,
    src_len: usize,
    src_used: *usize,
    dst: [*]u8,
    dst_cap: usize,
    dst_used: *usize,
) unshrnk_stat_t {
    var codetab: [MAX_CODE + 1]codetab_t = undefined;
    var queue: code_queue_t = undefined;
    var is: bs.istream_t = undefined;
    var code_size: usize = 0;
    var dst_pos: usize = 0;
    var i: usize = 0;
    var len: usize = 0;
    var curr_code: u16 = 0;
    var prev_code: u16 = 0;
    var new_code: u16 = 0;
    var c: u16 = 0;
    var first_byte: u8 = 0;
    var s: unshrnk_stat_t = undefined;

    codetab_init(&codetab);
    code_queue_init(&queue);
    bs.istream_init(&is, src, src_len);
    code_size = MIN_CODE_SIZE;
    dst_pos = 0;

    // Handle the first code separately since there is no previous code.
    if (!read_code(&is, &code_size, &codetab, &queue, &curr_code)) {
        src_used.* = bs.istream_bytes_read(&is);
        dst_used.* = 0;
        return unshrnk_stat_t.HWUNSHRINK_OK;
    }
    assert(curr_code != CONTROL_CODE);
    if (curr_code > UINT8_MAX) {
        return unshrnk_stat_t.HWUNSHRINK_ERR; // The first code must be a literal.
    }
    if (dst_pos == dst_cap) {
        return unshrnk_stat_t.HWUNSHRINK_FULL;
    }
    first_byte = @intCast(u8, curr_code);
    dst[dst_pos] = @intCast(u8, curr_code);
    codetab[curr_code].last_dst_pos = dst_pos;
    dst_pos += 1;

    prev_code = curr_code;
    while (read_code(&is, &code_size, &codetab, &queue, &curr_code)) {
        if (curr_code == INVALID_CODE) {
            return unshrnk_stat_t.HWUNSHRINK_ERR;
        }
        if (dst_pos == dst_cap) {
            return unshrnk_stat_t.HWUNSHRINK_FULL;
        }

        // Handle KwKwK: next code used before being added.
        if (curr_code == code_queue_next(&queue)) {
            if (codetab[prev_code].prefix_code == INVALID_CODE) {
                // The previous code is no longer valid.
                return unshrnk_stat_t.HWUNSHRINK_ERR;
            }
            // Extend the previous code with its first byte.
            assert(curr_code != prev_code);
            codetab[curr_code].prefix_code = prev_code;
            codetab[curr_code].ext_byte = first_byte;
            codetab[curr_code].len = codetab[prev_code].len + 1;
            codetab[curr_code].last_dst_pos =
                codetab[prev_code].last_dst_pos;
            assert(dst_pos < dst_cap);
            dst[dst_pos] = first_byte;
        }

        // Output the string represented by the current code.
        s = output_code(curr_code, dst, dst_pos, dst_cap, prev_code, &codetab, &queue, &first_byte, &len);
        if (s != unshrnk_stat_t.HWUNSHRINK_OK) {
            return s;
        }

        // Verify that the output matches walking the prefixes.
        c = curr_code;
        i = 0;
        while (i < len) : (i += 1) {
            assert(codetab[c].len == len - i);
            assert(codetab[c].ext_byte == dst[dst_pos + len - i - 1]);
            c = codetab[c].prefix_code;
        }

        // Add a new code to the string table if there's room.
        // The string is the previous code's string extended with
        // the first byte of the current code's string.
        new_code = code_queue_remove_next(&queue);
        if (new_code != INVALID_CODE) {
            assert(codetab[prev_code].last_dst_pos < dst_pos);
            codetab[new_code].prefix_code = prev_code;
            codetab[new_code].ext_byte = first_byte;
            codetab[new_code].len = codetab[prev_code].len + 1;
            codetab[new_code].last_dst_pos =
                codetab[prev_code].last_dst_pos;

            if (codetab[prev_code].prefix_code == INVALID_CODE) {
                // prev_code was invalidated in a partial
                // clearing. Until that code is re-used, the
                // string represented by new_code is
                // indeterminate.
                codetab[new_code].len = UNKNOWN_LEN;
            }
            // If prev_code was invalidated in a partial clearing,
            // it's possible that new_code==prev_code, in which
            // case it will never be used or cleared.
        }

        codetab[curr_code].last_dst_pos = dst_pos;
        dst_pos += len;

        prev_code = curr_code;
    }

    src_used.* = bs.istream_bytes_read(&is);
    dst_used.* = dst_pos;

    return unshrnk_stat_t.HWUNSHRINK_OK;
}
