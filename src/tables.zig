// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

// Code lengths for fixed Huffman coding of litlen and dist symbols.
pub const fixed_litlen_lengths: [288]u8 = print_fixed_litlen_lengths();
pub const fixed_dist_lengths: [32]u8 = [_]u8{5} ** 32;

fn print_fixed_litlen_lengths() [288]u8 {
    var ret: [288]u8 = undefined;

    // RFC 1951, 3.2.6
    for (ret) |_, i| {
        if (i <= 143) {
            ret[i] = 8;
            continue;
        }
        if (i <= 255) {
            ret[i] = 9;
            continue;
        }
        if (i <= 279) {
            ret[i] = 7;
            continue;
        }
        if (i <= 287) {
            ret[i] = 8;
            continue;
        }
    }

    return ret;
}

// RFC 1951, 3.2.5
const litlen_t = struct {
    litlen: u16,
    base_len: u16,
    ebits: u16,
};

fn litlen_base_tbl() [29]litlen_t {
    return [_]litlen_t{
        litlen_t{ .litlen = 257, .base_len = 3, .ebits = 0 },
        litlen_t{ .litlen = 258, .base_len = 4, .ebits = 0 },
        litlen_t{ .litlen = 259, .base_len = 5, .ebits = 0 },
        litlen_t{ .litlen = 260, .base_len = 6, .ebits = 0 },
        litlen_t{ .litlen = 261, .base_len = 7, .ebits = 0 },
        litlen_t{ .litlen = 262, .base_len = 8, .ebits = 0 },
        litlen_t{ .litlen = 263, .base_len = 9, .ebits = 0 },
        litlen_t{ .litlen = 264, .base_len = 10, .ebits = 0 },
        litlen_t{ .litlen = 265, .base_len = 11, .ebits = 1 },
        litlen_t{ .litlen = 266, .base_len = 13, .ebits = 1 },
        litlen_t{ .litlen = 267, .base_len = 15, .ebits = 1 },
        litlen_t{ .litlen = 268, .base_len = 17, .ebits = 1 },
        litlen_t{ .litlen = 269, .base_len = 19, .ebits = 2 },
        litlen_t{ .litlen = 270, .base_len = 23, .ebits = 2 },
        litlen_t{ .litlen = 271, .base_len = 27, .ebits = 2 },
        litlen_t{ .litlen = 272, .base_len = 31, .ebits = 2 },
        litlen_t{ .litlen = 273, .base_len = 35, .ebits = 3 },
        litlen_t{ .litlen = 274, .base_len = 43, .ebits = 3 },
        litlen_t{ .litlen = 275, .base_len = 51, .ebits = 3 },
        litlen_t{ .litlen = 276, .base_len = 59, .ebits = 3 },
        litlen_t{ .litlen = 277, .base_len = 67, .ebits = 4 },
        litlen_t{ .litlen = 278, .base_len = 83, .ebits = 4 },
        litlen_t{ .litlen = 279, .base_len = 99, .ebits = 4 },
        litlen_t{ .litlen = 280, .base_len = 115, .ebits = 4 },
        litlen_t{ .litlen = 281, .base_len = 131, .ebits = 5 },
        litlen_t{ .litlen = 282, .base_len = 163, .ebits = 5 },
        litlen_t{ .litlen = 283, .base_len = 195, .ebits = 5 },
        litlen_t{ .litlen = 284, .base_len = 227, .ebits = 5 },
        litlen_t{ .litlen = 285, .base_len = 258, .ebits = 0 },
    };
}

// Table of litlen symbol values minus 257 with corresponding base length
// and number of extra bits.
const litlen_tbl_t = struct {
    base_len: u16 = 9,
    ebits: u16 = 7,
};
pub const litlen_tbl: [29]litlen_tbl_t = print_litlen_tbl();

fn print_litlen_tbl() [29]litlen_tbl_t {
    var table: [29]litlen_tbl_t = undefined;
    const litlen_table: [29]litlen_t = litlen_base_tbl();

    for (litlen_table) |ll, i| {
        table[i].base_len = ll.base_len;
        table[i].ebits = ll.ebits;
    }
    return table;
}

// Mapping from length (3--258) to litlen symbol (257--285).
pub const len2litlen: [259]u16 = print_len2litlen();

fn print_len2litlen() [259]u16 {
    var i: usize = 0;
    var len: usize = 0;
    var table: [259]u16 = undefined;
    const litlen_table: [29]litlen_t = litlen_base_tbl();

    // Lengths 0, 1, 2 are not valid.
    table[0] = 0xffff;
    table[1] = 0xffff;
    table[2] = 0xffff;

    i = 0;
    len = 3;
    while (len <= 258) : (len += 1) {
        if (len == litlen_table[i + 1].base_len) {
            i += 1;
        }
        table[len] = litlen_table[i].litlen;
    }
    return table;
}

// Table of dist symbol values with corresponding base distance and number of
// extra bits.
// RFC 1951, 3.2.5

const dist_tbl_t = struct {
    base_dist: u16,
    ebits: u16,
};

pub const dist_tbl: [30]dist_tbl_t = [_]dist_tbl_t{
    dist_tbl_t{ .base_dist = 1, .ebits = 0 },
    dist_tbl_t{ .base_dist = 2, .ebits = 0 },
    dist_tbl_t{ .base_dist = 3, .ebits = 0 },
    dist_tbl_t{ .base_dist = 4, .ebits = 0 },
    dist_tbl_t{ .base_dist = 5, .ebits = 1 },
    dist_tbl_t{ .base_dist = 7, .ebits = 1 },
    dist_tbl_t{ .base_dist = 9, .ebits = 2 },
    dist_tbl_t{ .base_dist = 13, .ebits = 2 },
    dist_tbl_t{ .base_dist = 17, .ebits = 3 },
    dist_tbl_t{ .base_dist = 25, .ebits = 3 },
    dist_tbl_t{ .base_dist = 33, .ebits = 4 },
    dist_tbl_t{ .base_dist = 49, .ebits = 4 },
    dist_tbl_t{ .base_dist = 65, .ebits = 5 },
    dist_tbl_t{ .base_dist = 97, .ebits = 5 },
    dist_tbl_t{ .base_dist = 129, .ebits = 6 },
    dist_tbl_t{ .base_dist = 193, .ebits = 6 },
    dist_tbl_t{ .base_dist = 257, .ebits = 7 },
    dist_tbl_t{ .base_dist = 385, .ebits = 7 },
    dist_tbl_t{ .base_dist = 513, .ebits = 8 },
    dist_tbl_t{ .base_dist = 769, .ebits = 8 },
    dist_tbl_t{ .base_dist = 1025, .ebits = 9 },
    dist_tbl_t{ .base_dist = 1537, .ebits = 9 },
    dist_tbl_t{ .base_dist = 2049, .ebits = 10 },
    dist_tbl_t{ .base_dist = 3073, .ebits = 10 },
    dist_tbl_t{ .base_dist = 4097, .ebits = 11 },
    dist_tbl_t{ .base_dist = 6145, .ebits = 11 },
    dist_tbl_t{ .base_dist = 8193, .ebits = 12 },
    dist_tbl_t{ .base_dist = 12289, .ebits = 12 },
    dist_tbl_t{ .base_dist = 16385, .ebits = 13 },
    dist_tbl_t{ .base_dist = 24577, .ebits = 13 },
};

pub const distance2dist_lo: [256]u8 = print_distance2dist()[0];
pub const distance2dist_hi: [256]u8 = print_distance2dist()[1];

fn print_distance2dist() [2][256]u8 {
    @setEvalBranchQuota(147_700);
    var ret: [2][256]u8 = undefined;
    var low: [256]u8 = undefined;
    var high: [256]u8 = undefined;
    var dist: u8 = 0;
    var distance: usize = 0;

    // For each distance.
    distance = 1;
    while (distance <= 32768) : (distance += 1) {
        // Find the corresponding dist code.
        dist = 29;
        while (dist_tbl[dist].base_dist > distance) {
            dist -= 1;
        }

        if (distance <= 256) {
            low[(distance - 1)] = dist;
        } else {
            high[(distance - 1) >> 7] = dist;
        }
    }

    high[0] = 0xff; // invalid
    high[1] = 0xff; // invalid

    ret[0] = low;
    ret[1] = high;
    return ret;
}
