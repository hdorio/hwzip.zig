// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const bu = @import("./bits.zig"); // bits utilities

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const math = std.math;

const UINT8_MAX = math.maxInt(u8);
const UINT16_MAX = math.maxInt(u16);

pub const MAX_HUFFMAN_SYMBOLS = 288; // Deflate uses max 288 symbols.
pub const MAX_HUFFMAN_BITS = 16; // Implode uses max 16-bit codewords.
pub const HUFFMAN_LOOKUP_TABLE_BITS = 8; // Seems a good trade-off.
pub const Error = error{
    FailedToDecode,
};

const huffman_decoder_t_table: type = struct {
    sym: u9 = 0, // Wide enough to fit the max symbol nbr.
    len: u7 = 0, // 0 means no symbol.
};

pub const huffman_decoder_t: type = struct {
    // Lookup table for fast decoding of short codewords.
    table: [@as(u32, 1) << HUFFMAN_LOOKUP_TABLE_BITS]huffman_decoder_t_table =
        [1]huffman_decoder_t_table{.{}} ** (@as(u32, 1) << HUFFMAN_LOOKUP_TABLE_BITS),

    // "Sentinel bits" value for each codeword length.
    sentinel_bits: [MAX_HUFFMAN_BITS + 1]u32 = [1]u32{0} ** (MAX_HUFFMAN_BITS + 1),

    // First symbol index minus first codeword mod 2**16 for each length.
    offset_first_sym_idx: [MAX_HUFFMAN_BITS + 1]u16 = [1]u16{0} ** (MAX_HUFFMAN_BITS + 1),

    // Map from symbol index to symbol.
    syms: [MAX_HUFFMAN_SYMBOLS]u16 = [1]u16{0} ** MAX_HUFFMAN_SYMBOLS,

    //num_syms: usize, // for debug
};

pub const huffman_encoder_t: type = struct {
    codewords: [MAX_HUFFMAN_SYMBOLS]u16, // LSB-first codewords.
    lengths: [MAX_HUFFMAN_SYMBOLS]u8, // Codeword lengths.
};

// Initialize huffman decoder d for a code defined by the n codeword lengths.
// Returns false if the codeword lengths do not correspond to a valid prefix
// code.
pub fn huffman_decoder_init(d: *huffman_decoder_t, lengths: [*]const u8, n: usize) bool {
    var i: usize = 0;
    var count = [_]u16{0} ** (MAX_HUFFMAN_BITS + 1);
    var code = [_]u16{0} ** (MAX_HUFFMAN_BITS + 1);
    var s: u32 = 0;
    var sym_idx = [_]u16{0} ** (MAX_HUFFMAN_BITS + 1);
    var l: u5 = 0;

    assert(n <= MAX_HUFFMAN_SYMBOLS);

    // d->num_syms = n;                  // see huffman_decoder_t.num_syms

    // Zero-initialize the lookup table.
    for (d.table) |_, di| {
        d.table[di].len = 0;
    }

    // Count the number of codewords of each length.
    i = 0;
    while (i < n) : (i += 1) {
        assert(lengths[i] <= MAX_HUFFMAN_BITS);
        count[lengths[i]] += 1;
    }
    count[0] = 0; // Ignore zero-length codewords.

    // Compute sentinel_bits and offset_first_sym_idx for each length.
    code[0] = 0;
    sym_idx[0] = 0;
    l = 1;
    while (l <= MAX_HUFFMAN_BITS) : (l += 1) {
        // First canonical codeword of this length.
        code[l] = @intCast(u16, (code[l - 1] + count[l - 1]) << 1);

        if (count[l] != 0 and (code[l] + (count[l] - 1)) > (@as(u32, 1) << l) - 1) {
            // The last codeword is longer than l bits.
            return false;
        }

        s = @intCast(u32, @intCast(u32, code[l]) + @intCast(u32, count[l])) << (MAX_HUFFMAN_BITS - l);
        d.sentinel_bits[l] = s;
        assert(d.sentinel_bits[l] >= code[l]); // "No overflow!"

        sym_idx[l] = sym_idx[l - 1] + count[l - 1];
        var sub_tmp: u16 = 0;
        _ = @subWithOverflow(u16, sym_idx[l], code[l], &sub_tmp);
        d.offset_first_sym_idx[l] = sub_tmp;
    }

    // Build mapping from index to symbol and populate the lookup table.
    i = 0;
    while (i < n) : (i += 1) {
        l = @intCast(u5, lengths[i]);
        if (l == 0) {
            continue;
        }

        d.syms[sym_idx[l]] = @intCast(u16, i);
        sym_idx[l] += 1;

        if (l <= HUFFMAN_LOOKUP_TABLE_BITS) {
            table_insert(d, i, l, code[l]);
            code[l] += 1;
        }
    }

    return true;
}

// Use the decoder d to decode a symbol from the LSB-first zero-padded bits.
// Returns the decoded symbol number or -1 if no symbol could be decoded.
// *num_used_bits will be set to the number of bits used to decode the symbol,
// or zero if no symbol could be decoded.
pub inline fn huffman_decode(d: *const huffman_decoder_t, bits: u16, num_used_bits: *usize) !u16 {
    var lookup_bits: u64 = 0;
    var l: u5 = 0;
    var sym_idx: usize = 0;

    // First try the lookup table.
    lookup_bits = bu.lsb(bits, HUFFMAN_LOOKUP_TABLE_BITS);
    assert(lookup_bits < d.table.len);
    if (d.table[lookup_bits].len != 0) {
        assert(d.table[lookup_bits].len <= HUFFMAN_LOOKUP_TABLE_BITS);
        // asserts: assert(d.table[lookup_bits].sym < d.num_syms);

        num_used_bits.* = d.table[lookup_bits].len;
        return d.table[lookup_bits].sym;
    }

    // Then do canonical decoding with the bits in MSB-first order.
    var bits_decoded = bu.reverse16(bits, MAX_HUFFMAN_BITS);
    l = HUFFMAN_LOOKUP_TABLE_BITS + 1;
    while (l <= MAX_HUFFMAN_BITS) : (l += 1) {
        if (bits_decoded < d.sentinel_bits[l]) {
            bits_decoded >>= @intCast(u4, MAX_HUFFMAN_BITS - l);

            sym_idx = @truncate(u16, @intCast(u32, d.offset_first_sym_idx[l]) + @intCast(u32, bits_decoded));
            // assert(sym_idx < d.num_syms); // see huffman_decoder_t.num_syms

            num_used_bits.* = l;
            return d.syms[sym_idx];
        }
    }

    num_used_bits.* = 0;
    return Error.FailedToDecode;
}

// Initialize a Huffman encoder based on the n symbol frequencies.
pub fn huffman_encoder_init(e: *huffman_encoder_t, freqs: [*]const u16, n: usize, max_codeword_len: u5) void {
    assert(n <= MAX_HUFFMAN_SYMBOLS);
    assert(max_codeword_len <= MAX_HUFFMAN_BITS);

    compute_huffman_lengths(freqs, n, max_codeword_len, &e.lengths);
    compute_canonical_code(&e.codewords, &e.lengths, n);
}

// Initialize a Huffman encoder based on the n codeword lengths.
pub fn huffman_encoder_init2(e: *huffman_encoder_t, lengths: [*]const u8, n: usize) void {
    var i: usize = 0;

    while (i < n) : (i += 1) {
        e.lengths[i] = lengths[i];
    }
    compute_canonical_code(&e.codewords, &e.lengths, n);
}

fn table_insert(d: *huffman_decoder_t, sym: usize, len: u5, codeword: u16) void {
    var pad_len: u5 = 0;
    var padding: u32 = 0;
    var index: u16 = 0;

    assert(len <= HUFFMAN_LOOKUP_TABLE_BITS);

    const codeword_decoded: u32 = bu.reverse16(codeword, len); // Make it LSB-first.
    pad_len = HUFFMAN_LOOKUP_TABLE_BITS - len;

    // Pad the pad_len upper bits with all bit combinations.
    while (padding < (@as(u32, 1) << pad_len)) : (padding += 1) {
        index = @truncate(u16, codeword_decoded | (padding << len));
        d.table[index].sym = @intCast(u9, sym);
        d.table[index].len = @intCast(u7, len);

        assert(d.table[index].sym == sym); // "Fits in bitfield.
        assert(d.table[index].len == len); // "Fits in bitfield.
    }
}

// Swap the 32-bit values pointed to by a and b.
fn swap32(a: *u32, b: *u32) void {
    var tmp: u32 = undefined;
    tmp = a.*;
    a.* = b.*;
    b.* = tmp;
}

// Move element at index in the n-element heap down to restore the minheap property.
fn minheap_down(heap: [*]u32, n: usize, index: usize) void {
    var left: usize = 0;
    var right: usize = 0;
    var min: usize = 0;
    var i: usize = index;

    assert(i >= 1 and i <= n); // "i must be inside the heap"

    // While the i-th element has at least one child.
    while (i * 2 <= n) {
        left = i * 2;
        right = i * 2 + 1;

        // Find the child with lowest value.
        min = left;
        if (right <= n and heap[right] < heap[left]) {
            min = right;
        }

        // Move i down if it is larger.
        if (heap[min] < heap[i]) {
            swap32(&heap[min], &heap[i]);
            i = min;
        } else {
            break;
        }
    }
}

// Establish minheap property for heap[1..n].
fn minheap_heapify(heap: [*]u32, n: usize) void {
    // Floyd's algorithm.
    var i: usize = n / 2;
    while (i >= 1) : (i -= 1) {
        minheap_down(heap, n, i);
    }
}

// Construct a Huffman code for n symbols with the frequencies in freq, and
// codeword length limited to max_len. The sum of the frequencies must be <=
// UINT16_MAX. max_len must be large enough that a code is always possible,
// i.e. 2 ** max_len >= n. Symbols with zero frequency are not part of the code
// and get length zero. Outputs the codeword lengths in lengths[0..n-1].
fn compute_huffman_lengths(freqs: [*]const u16, n: usize, max_len: u5, lengths: [*]u8) void {
    var nodes = [_]u32{0} ** (MAX_HUFFMAN_SYMBOLS * 2 + 1);
    var p: u32 = 0;
    var q: u32 = 0;
    var freq: u16 = 0;
    var i: usize = 0;
    var h: usize = 0;
    var l: usize = 0;

    var freq_cap: u16 = UINT16_MAX;

    if (builtin.mode == .Debug) {
        var freq_sum: u32 = 0;
        i = 0;
        while (i < n) : (i += 1) {
            freq_sum += freqs[i];
        }
        assert(freq_sum <= UINT16_MAX); // "Frequency sum too large!"
    }

    assert(n <= MAX_HUFFMAN_SYMBOLS);
    assert((@as(u32, 1) << max_len) >= n); // "max_len must be large enough"

    var try_again = true;

    try_again: while (try_again) {
        try_again = false;

        // Initialize the heap. h is the heap size.
        h = 0;
        i = 0;
        while (i < n) : (i += 1) {
            freq = freqs[i];

            if (freq == 0) {
                continue; // Ignore zero-frequency symbols.
            }
            if (freq > freq_cap) {
                freq = freq_cap; // Enforce the frequency cap.
            }

            // High 16 bits: Symbol frequency.
            // Low 16 bits:  Symbol link element index.
            h += 1;
            nodes[h] = (@intCast(u32, freq) << 16) | @intCast(u32, n + h);
        }
        minheap_heapify(&nodes, h);

        // Special case for fewer than two non-zero symbols.
        if (h < 2) {
            i = 0;
            while (i < n) : (i += 1) {
                lengths[i] = if (freqs[i] == 0) 0 else 1;
            }
            return;
        }

        // Build the Huffman tree.
        while (h > 1) {
            // Remove the lowest frequency node p from the heap.
            p = nodes[1];
            nodes[1] = nodes[h];
            h -= 1;
            minheap_down(&nodes, h, 1);

            // Get q, the next lowest frequency node.
            q = nodes[1];

            // Replace q with a new symbol with the combined frequencies of
            // p and q, and with the no longer used h+1'th node as the
            // link element.
            nodes[1] = ((p & 0xffff0000) + (q & 0xffff0000)) | @intCast(u32, h + 1);

            // Set the links of p and q to point to the link element of
            // the new node.
            nodes[q & 0xffff] = @intCast(u32, h + 1);
            nodes[p & 0xffff] = nodes[q & 0xffff];

            // Move the new symbol down to restore heap property.
            minheap_down(&nodes, h, 1);
        }

        // Compute the codeword length for each symbol.
        h = 0;
        i = 0;
        while (i < n) : (i += 1) {
            if (freqs[i] == 0) {
                lengths[i] = 0;
                continue;
            }
            h += 1;

            // Link element for the i-th symbol.
            p = nodes[n + h];

            // Follow the links until we hit the root (link index 2).
            l = 1;
            while (p != 2) {
                l += 1;
                p = nodes[p];
            }

            if (l > max_len) {
                // Lower freq_cap to flatten the distribution.
                assert(freq_cap != 1); // "Cannot lower freq_cap!"
                freq_cap /= 2;
                try_again = true;
                continue :try_again;
            }

            assert(l <= UINT8_MAX);
            lengths[i] = @intCast(u8, l);
        }
    }
}

fn compute_canonical_code(codewords: [*]u16, lengths: [*]const u8, n: usize) void {
    var i: usize = 0;
    var count = [_]u16{0} ** (MAX_HUFFMAN_BITS + 1);
    var code = [_]u16{0} ** (MAX_HUFFMAN_BITS + 1);
    var l: u5 = 0;

    // Count the number of codewords of each length.
    i = 0;
    while (i < n) : (i += 1) {
        count[lengths[i]] += 1;
    }
    count[0] = 0; // Ignore zero-length codes.

    // Compute the first codeword for each length.
    code[0] = 0;
    l = 1;
    while (l <= MAX_HUFFMAN_BITS) : (l += 1) {
        code[l] = @truncate(u16, (@intCast(u32, code[l - 1]) + @intCast(u32, count[l - 1])) << 1);
    }

    // Assign a codeword for each symbol.
    i = 0;
    while (i < n) : (i += 1) {
        l = @intCast(u5, lengths[i]);
        if (l == 0) {
            continue;
        }

        codewords[i] = bu.reverse16(code[l], l); // Make it LSB-first.
        code[l] = @truncate(u16, @intCast(u32, code[l]) + 1);
    }
}
