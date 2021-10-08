const std = @import("std");
const allocator = std.heap.page_allocator;
const assert = std.debug.assert;
const hash = std.hash;
const math = std.math;
const mem = std.mem;

const time = @import("./time.zig");
const bits = @import("./bits.zig");

const deflate = @import("deflate.zig");
const implode = @import("implode.zig");
const reduce = @import("reduce.zig");
const shrink = @import("shrink.zig");

const SIZE_MAX = math.maxInt(usize);
const UINT16_MAX = math.maxInt(u16);
const UINT32_MAX = math.maxInt(u32);
fn strlen(str: [*:0]const u8) usize {
    return mem.indexOfSentinel(u8, 0x0, str);
}
fn crc32(data: [*]const u8, size: usize) u32 {
    return hash.Crc32.hash(data[0..size]);
}

pub const CallbackError = error{
    WriteCallbackError,
};

pub const zipiter_t: type = usize; // Zip archive member iterator.

pub const zip_t: type = struct {
    num_members: u16, // Number of members.
    comment: [*]const u8, // Zip file comment (not terminated).
    comment_len: u16, // Zip file comment length.
    members_begin: zipiter_t, // Iterator to the first member.
    members_end: zipiter_t, // Iterator to the end of members.

    src: [*]const u8,
    src_len: usize,
};

pub const method_t: type = enum(u4) {
    ZIP_STORE, // 0,
    ZIP_SHRINK, // 1,
    ZIP_REDUCE1, // 2,
    ZIP_REDUCE2, // 3,
    ZIP_REDUCE3, // 4,
    ZIP_REDUCE4, //5,
    ZIP_IMPLODE, // 6,
    NA, // 7, not available
    ZIP_DEFLATE, // 8
};

fn method_to_comp_factor(m: method_t) u3 {
    var method = @intCast(i16, @enumToInt(m));
    var first_reduce_method = @intCast(i16, @enumToInt(method_t.ZIP_REDUCE1));
    var comp_factor = method - first_reduce_method + 1;
    return @intCast(u3, comp_factor);
}

pub const zipmemb_t: type = struct {
    name: [*]const u8, // Member name (not null terminated).
    name_len: u16, // Member name length.
    mtime: time.time_t, // Modification time.
    comp_size: u32, // Compressed size.
    comp_data: [*]const u8, // Compressed data.
    made_by_ver: u16, // Made-by version, e.g. 20 for PKZip 2.0.
    method: method_t, // Compression method.
    imp_large_wnd: bool, // For implode: compressed with 8K window?
    imp_lit_tree: bool, // For implode: Huffman coded literals?
    uncomp_size: u32, // Uncompressed size.
    crc32: u32, // CRC-32 checksum.
    comment: [*]const u8, // Comment (not null terminated).
    comment_len: u16, // Comment length.
    is_dir: bool, // Whether this is a directory.
    next: zipiter_t, // Iterator to the next member.
};

// Read 16/32 bits little-endian and bump p forward afterwards.
inline fn READ16(p: *[*]const u8) u16 {
    p.* += 2;
    return bits.read16le(p.* - 2);
}
inline fn READ32(p: *[*]const u8) u32 {
    p.* += 4;
    return bits.read32le(p.* - 4);
}

// Write 16/32 bits little-endian and bump p forward afterwards.
inline fn WRITE16(p: *[*]u8, x: u16) void {
    bits.write16le(p.*, x);
    p.* += 2;
}
inline fn WRITE32(p: *[*]u8, x: u32) void {
    bits.write32le(p.*, x);
    p.* += 4;
}

// End of Central Directory Record.
const eocdr_t: type = struct {
    disk_nbr: u16, // Number of this disk.
    cd_start_disk: u16, // Nbr. of disk with start of the CD.
    disk_cd_entries: u16, // Nbr. of CD entries on this disk.
    cd_entries: u16, // Nbr. of Central Directory entries.
    cd_size: u32, // Central Directory size in bytes.
    cd_offset: u32, // Central Directory file offset.
    comment_len: u16, // Archive comment length.
    comment: [*]const u8, // Archive comment.
};

// Size of the End of Central Directory Record, not including comment.
const EOCDR_BASE_SZ = 22;
const EOCDR_SIGNATURE = 0x06054b50; // "PK\5\6" little-endian.

const MAX_BACK_OFFSET = (1024 * 100);

pub fn find_eocdr(r: *eocdr_t, src: [*]const u8, src_len: usize) bool {
    var back_offset: usize = 0;
    var p: [*]const u8 = undefined;
    var signature: u32 = 0;

    back_offset = 0;
    while (back_offset <= MAX_BACK_OFFSET) : (back_offset += 1) {
        if (src_len < EOCDR_BASE_SZ + back_offset) {
            break;
        }

        p = src[src_len - EOCDR_BASE_SZ - back_offset .. src_len].ptr;
        signature = READ32(&p);

        if (signature == EOCDR_SIGNATURE) {
            r.disk_nbr = READ16(&p);
            r.cd_start_disk = READ16(&p);
            r.disk_cd_entries = READ16(&p);
            r.cd_entries = READ16(&p);
            r.cd_size = READ32(&p);
            r.cd_offset = READ32(&p);
            r.comment_len = READ16(&p);
            r.comment = @ptrCast([*:0]const u8, p);
            assert(@ptrToInt(p) == @ptrToInt(&src[src_len - back_offset])); // "All fields read."

            if (r.comment_len > back_offset) {
                return false;
            }

            return true;
        }
    }

    return false;
}

pub fn write_eocdr(dst: [*]u8, r: *const eocdr_t) usize {
    var p: [*]u8 = dst;

    WRITE32(&p, EOCDR_SIGNATURE);
    WRITE16(&p, r.disk_nbr);
    WRITE16(&p, r.cd_start_disk);
    WRITE16(&p, r.disk_cd_entries);
    WRITE16(&p, r.cd_entries);
    WRITE32(&p, r.cd_size);
    WRITE32(&p, r.cd_offset);
    WRITE16(&p, r.comment_len);
    assert(@ptrToInt(p) - @ptrToInt(dst) == EOCDR_BASE_SZ);

    if (r.comment_len != 0) {
        mem.copy(u8, p[0..r.comment_len], r.comment[0..r.comment_len]);
        p += r.comment_len;
    }

    return @intCast(usize, @ptrToInt(p) - @ptrToInt(dst));
}

const EXT_ATTR_DIR = @as(u32, 1) << 4;
const EXT_ATTR_ARC = @as(u32, 1) << 5;

// Central File Header (Central Directory Entry)
const cfh_t: type = struct {
    made_by_ver: u16, // Version made by.
    extract_ver: u16, // Version needed to extract.
    gp_flag: u16, // General-purpose bit flag.
    method: u16, // Compression method.
    mod_time: u16, // Modification time.
    mod_date: u16, // Modification date.
    crc32: u32, // CRC-32 checksum.
    comp_size: u32, // Compressed size.
    uncomp_size: u32, // Uncompressed size.
    name_len: u16, // Filename length.
    extra_len: u16, // Extra data length.
    comment_len: u16, // Comment length.
    disk_nbr_start: u16, // Disk nbr. where file begins.
    int_attrs: u16, // Internal file attributes.
    ext_attrs: u32, // External file attributes.
    lfh_offset: u32, // Local File Header offset.
    name: [*]const u8, // Filename (not null terminated)
    extra: [*]const u8, // Extra data such as Unix file ownership information, higher resolution modification date and time, or Zip64 fields
    comment: [*]const u8, // File comment. (not null terminated)
};

// Size of a Central File Header, not including name, extra, and comment.
const CFH_BASE_SZ = 46;
const CFH_SIGNATURE = 0x02014b50; // "PK\1\2" little-endian.

pub fn read_cfh(cfh: *cfh_t, src: [*]const u8, src_len: usize, offset: usize) bool {
    var p: [*]const u8 = undefined;
    var signature: u32 = 0;

    if (offset > src_len or src_len - offset < CFH_BASE_SZ) {
        return false;
    }

    p = src[offset..src_len].ptr;
    signature = READ32(&p);
    if (signature != CFH_SIGNATURE) {
        return false;
    }

    cfh.made_by_ver = READ16(&p);
    cfh.extract_ver = READ16(&p);
    cfh.gp_flag = READ16(&p);
    cfh.method = READ16(&p);
    cfh.mod_time = READ16(&p);
    cfh.mod_date = READ16(&p);
    cfh.crc32 = READ32(&p);
    cfh.comp_size = READ32(&p);
    cfh.uncomp_size = READ32(&p);
    cfh.name_len = READ16(&p);
    cfh.extra_len = READ16(&p);
    cfh.comment_len = READ16(&p);
    cfh.disk_nbr_start = READ16(&p);
    cfh.int_attrs = READ16(&p);
    cfh.ext_attrs = READ32(&p);
    cfh.lfh_offset = READ32(&p);
    cfh.name = p;
    cfh.extra = cfh.name + cfh.name_len;
    cfh.comment = cfh.extra + cfh.extra_len;
    assert(@ptrToInt(p) == @ptrToInt(&src[offset + CFH_BASE_SZ])); // "All fields read."

    if (src_len - offset - CFH_BASE_SZ < @intCast(usize, cfh.name_len) + cfh.extra_len + cfh.comment_len) {
        return false;
    }

    return true;
}

pub fn write_cfh(dst: [*]u8, cfh: *const cfh_t) usize {
    var p: [*]u8 = dst;

    WRITE32(&p, CFH_SIGNATURE);
    WRITE16(&p, cfh.made_by_ver);
    WRITE16(&p, cfh.extract_ver);
    WRITE16(&p, cfh.gp_flag);
    WRITE16(&p, cfh.method);
    WRITE16(&p, cfh.mod_time);
    WRITE16(&p, cfh.mod_date);
    WRITE32(&p, cfh.crc32);
    WRITE32(&p, cfh.comp_size);
    WRITE32(&p, cfh.uncomp_size);
    WRITE16(&p, cfh.name_len);
    WRITE16(&p, cfh.extra_len);
    WRITE16(&p, cfh.comment_len);
    WRITE16(&p, cfh.disk_nbr_start);
    WRITE16(&p, cfh.int_attrs);
    WRITE32(&p, cfh.ext_attrs);
    WRITE32(&p, cfh.lfh_offset);
    assert(@ptrToInt(p) - @ptrToInt(dst) == CFH_BASE_SZ);

    if (cfh.name_len != 0) {
        mem.copy(u8, p[0..cfh.name_len], cfh.name[0..cfh.name_len]);
        p += cfh.name_len;
    }

    if (cfh.extra_len != 0) {
        mem.copy(u8, p[0..cfh.extra_len], cfh.extra[0..cfh.extra_len]);
        p += cfh.extra_len;
    }

    if (cfh.comment_len != 0) {
        mem.copy(u8, p[0..cfh.comment_len], cfh.comment[0..cfh.comment_len]);
        p += cfh.comment_len;
    }

    return @intCast(usize, @ptrToInt(p) - @ptrToInt(dst));
}

// Local File Header.
const lfh_t: type = struct {
    extract_ver: u16,
    gp_flag: u16,
    method: u16,
    mod_time: u16,
    mod_date: u16,
    crc32: u32,
    comp_size: u32,
    uncomp_size: u32,
    name_len: u16,
    extra_len: u16,
    name: [*]const u8,
    extra: [*]const u8,
};

// Size of a Local File Header, not including name and extra.
const LFH_BASE_SZ = 30;
const LFH_SIGNATURE = 0x04034b50; // "PK\3\4" little-endian.

pub fn read_lfh(lfh: *lfh_t, src: [*]const u8, src_len: usize, offset: usize) bool {
    var p: [*]const u8 = undefined;
    var signature: u32 = 0;

    if (offset > src_len or src_len - offset < LFH_BASE_SZ) {
        return false;
    }

    p = src[offset..src_len].ptr;
    signature = READ32(&p);
    if (signature != LFH_SIGNATURE) {
        return false;
    }

    lfh.extract_ver = READ16(&p);
    lfh.gp_flag = READ16(&p);
    lfh.method = READ16(&p);
    lfh.mod_time = READ16(&p);
    lfh.mod_date = READ16(&p);
    lfh.crc32 = READ32(&p);
    lfh.comp_size = READ32(&p);
    lfh.uncomp_size = READ32(&p);
    lfh.name_len = READ16(&p);
    lfh.extra_len = READ16(&p);
    lfh.name = p;
    lfh.extra = lfh.name + lfh.name_len;
    assert(@ptrToInt(p) == @ptrToInt(&src[offset + LFH_BASE_SZ])); // "All fields read."

    if (src_len - offset - LFH_BASE_SZ < lfh.name_len + lfh.extra_len) {
        return false;
    }

    return true;
}

pub fn write_lfh(dst: [*]u8, lfh: *const lfh_t) usize {
    var p: [*]u8 = dst;

    WRITE32(&p, LFH_SIGNATURE);
    WRITE16(&p, lfh.extract_ver);
    WRITE16(&p, lfh.gp_flag);
    WRITE16(&p, lfh.method);
    WRITE16(&p, lfh.mod_time);
    WRITE16(&p, lfh.mod_date);
    WRITE32(&p, lfh.crc32);
    WRITE32(&p, lfh.comp_size);
    WRITE32(&p, lfh.uncomp_size);
    WRITE16(&p, lfh.name_len);
    WRITE16(&p, lfh.extra_len);
    assert(@ptrToInt(p) - @ptrToInt(dst) == LFH_BASE_SZ);

    if (lfh.name_len != 0) {
        mem.copy(u8, p[0..lfh.name_len], lfh.name[0..lfh.name_len]);
        p += lfh.name_len;
    }

    if (lfh.extra_len != 0) {
        mem.copy(u8, p[0..lfh.extra_len], lfh.name[0..lfh.extra_len]);
        p += lfh.extra_len;
    }

    return @intCast(usize, @ptrToInt(p) - @ptrToInt(dst));
}

// Convert DOS date and time to time_t.
pub fn dos2ctime(dos_date: u16, dos_time: u16) time.time_t {
    var tm: time.tm_t = time.tm_t{};

    tm.tm_sec = @intCast(i16, (dos_time & 0x1f) * 2); // Bits 0--4:  Secs divided by 2.
    tm.tm_min = @intCast(i16, dos_time >> 5) & 0x3f; // Bits 5--10: Minute.
    tm.tm_hour = @intCast(i16, dos_time >> 11); // Bits 11-15: Hour (0--23).

    tm.tm_mday = @intCast(i16, (dos_date & 0x1f)); // Bits 0--4: Day (1--31).
    tm.tm_mon = ((@intCast(i16, dos_date) >> 5) & 0xf) - 1; // Bits 5--8: Month (1--12).
    tm.tm_year = (@intCast(i16, dos_date) >> 9) + 80; // Bits 9--15: Year-1980.

    tm.tm_isdst = -1;

    return time.mktime(&tm);
}

// Convert time_t to DOS date and time.
pub fn ctime2dos(t: time.time_t, dos_date: *u16, dos_time: *u16) !void {
    var tm: *time.tm_t = try time.localtime(&t);

    // cannot store a date prior to the year 1980
    // returns MS/DOS time format epoch
    if (tm.tm_year - 80 < 0) {
        dos_time.* = 0; // Time: 00:00:00
        dos_date.* = 0;
        dos_date.* |= 1; // Bits 0--4:  Day: 01 (1).
        dos_date.* |= 1 << 5; // Bits 5--8:  Month: Jan (1).
        dos_date.* |= 0 << 9; // Bits 9--15: Year: 1980 (0).
        return;
    }

    dos_time.* = 0;
    dos_time.* |= @intCast(u16, @divTrunc(tm.tm_sec, 2)); // Bits 0--4:  Second divided by two.
    dos_time.* |= @intCast(u16, tm.tm_min) << 5; // Bits 5--10: Minute.
    dos_time.* |= @intCast(u16, tm.tm_hour) << 11; // Bits 11-15: Hour.

    dos_date.* = 0;
    dos_date.* |= @intCast(u16, tm.tm_mday); // Bits 0--4:  Day (1--31).
    dos_date.* |= @intCast(u16, tm.tm_mon + 1) << 5; // Bits 5--8:  Month (1--12).
    dos_date.* |= @intCast(u16, tm.tm_year - 80) << 9; // Bits 9--15: Year from 1980.
}

// Initialize zip based on the source data. Returns true on success, or false
// if the data could not be parsed as a valid Zip file.
pub fn zip_read(zip: *zip_t, src: [*]const u8, src_len: usize) bool {
    var eocdr: eocdr_t = undefined;
    var cfh: cfh_t = undefined;
    var lfh: lfh_t = undefined;
    var i: usize = 0;
    var offset: usize = 0;
    var comp_data: [*]const u8 = undefined;

    zip.src = src;
    zip.src_len = src_len;

    if (!find_eocdr(&eocdr, src, src_len)) {
        return false;
    }

    if (eocdr.disk_nbr != 0 or eocdr.cd_start_disk != 0 or
        eocdr.disk_cd_entries != eocdr.cd_entries)
    {
        return false; // Cannot handle multi-volume archives.
    }

    zip.num_members = eocdr.cd_entries;
    zip.comment = eocdr.comment;
    zip.comment_len = eocdr.comment_len;

    offset = eocdr.cd_offset;
    zip.members_begin = offset;

    // Read the member info and do a few checks.
    i = 0;
    while (i < eocdr.cd_entries) : (i += 1) {
        if (!read_cfh(&cfh, src, src_len, offset)) {
            return false;
        }

        if ((cfh.gp_flag & 1) == 1) {
            return false; // The member is encrypted.
        }
        if (cfh.method != @enumToInt(method_t.ZIP_STORE) and
            cfh.method != @enumToInt(method_t.ZIP_SHRINK) and
            cfh.method != @enumToInt(method_t.ZIP_REDUCE1) and
            cfh.method != @enumToInt(method_t.ZIP_REDUCE2) and
            cfh.method != @enumToInt(method_t.ZIP_REDUCE3) and
            cfh.method != @enumToInt(method_t.ZIP_REDUCE4) and
            cfh.method != @enumToInt(method_t.ZIP_IMPLODE) and
            cfh.method != @enumToInt(method_t.ZIP_DEFLATE))
        {
            return false; // Unsupported compression method.
        }
        if (cfh.method == @enumToInt(method_t.ZIP_STORE) and
            cfh.uncomp_size != cfh.comp_size)
        {
            return false;
        }
        if (cfh.disk_nbr_start != 0) {
            return false; // Cannot handle multi-volume archives.
        }
        if (mem.indexOfScalar(u8, cfh.name[0..cfh.name_len], 0x00) != null) {
            return false; // Bad filename.
        }

        if (!read_lfh(&lfh, src, src_len, cfh.lfh_offset)) {
            return false;
        }

        comp_data = lfh.extra + lfh.extra_len;
        if (cfh.comp_size > src_len - @intCast(usize, @ptrToInt(comp_data) - @ptrToInt(src))) {
            return false; // Member data does not fit in src.
        }

        offset += CFH_BASE_SZ + cfh.name_len + cfh.extra_len + cfh.comment_len;
    }

    zip.members_end = offset;

    return true;
}

// Get the Zip archive member through iterator it.
pub fn zip_member(zip: *const zip_t, it: zipiter_t) zipmemb_t {
    var cfh: cfh_t = undefined;
    var lfh: lfh_t = undefined;
    var ok: bool = false;
    var m: zipmemb_t = undefined;

    assert(it >= zip.members_begin and it < zip.members_end);

    ok = read_cfh(&cfh, zip.src, zip.src_len, it);
    assert(ok);

    ok = read_lfh(&lfh, zip.src, zip.src_len, cfh.lfh_offset);
    assert(ok);

    m.name = cfh.name;
    m.name_len = cfh.name_len;
    m.mtime = dos2ctime(cfh.mod_date, cfh.mod_time);
    m.comp_size = cfh.comp_size;
    m.comp_data = lfh.extra + lfh.extra_len;
    m.method = @intToEnum(method_t, @intCast(u4, cfh.method));
    m.made_by_ver = cfh.made_by_ver;
    m.imp_large_wnd = if (m.method == method_t.ZIP_IMPLODE) (cfh.gp_flag & 2) == 2 else false;
    m.imp_lit_tree = if (m.method == method_t.ZIP_IMPLODE) (cfh.gp_flag & 4) == 4 else false;
    m.uncomp_size = cfh.uncomp_size;
    m.crc32 = cfh.crc32;
    m.comment = cfh.comment;
    m.comment_len = cfh.comment_len;
    m.is_dir = (cfh.ext_attrs & EXT_ATTR_DIR) != 0;

    m.next = it + CFH_BASE_SZ + cfh.name_len + cfh.extra_len + cfh.comment_len;

    assert(m.next <= zip.members_end);

    return m;
}

// Extract a zip member into dst. Returns true on success. The CRC-32 is not
// checked.
pub fn zip_extract_member(m: *const zipmemb_t, dst: [*]u8) !bool {
    var src_used: usize = 0;
    var dst_used: usize = 0;
    var comp_factor: u3 = 0;

    switch (m.method) {
        method_t.ZIP_STORE => {
            assert(m.comp_size == m.uncomp_size);
            mem.copy(u8, dst[0..m.comp_size], m.comp_data[0..m.comp_size]);
            return true;
        },
        method_t.ZIP_SHRINK => {
            if (shrink.hwunshrink(m.comp_data, m.comp_size, &src_used, dst, m.uncomp_size, &dst_used) != shrink.unshrnk_stat_t.HWUNSHRINK_OK) {
                return false;
            }
            if (src_used != m.comp_size or dst_used != m.uncomp_size) {
                return false;
            }
            return true;
        },
        method_t.ZIP_REDUCE1,
        method_t.ZIP_REDUCE2,
        method_t.ZIP_REDUCE3,
        method_t.ZIP_REDUCE4,
        => {
            comp_factor = method_to_comp_factor(m.method);
            if (reduce.hwexpand(m.comp_data, m.comp_size, m.uncomp_size, comp_factor, &src_used, dst) != reduce.expand_stat_t.HWEXPAND_OK) {
                return false;
            }
            if (src_used != m.comp_size) {
                return false;
            }
            return true;
        },
        method_t.ZIP_IMPLODE => {
            // If the compressed data assumes an incorrect minimum backref
            // length because of the PKZip 1.01/1.02 bug, the length of the
            // decompressed data will likely not match the expectations, in
            // which case we try pk101_bug_compat mode.
            if (((try implode.hwexplode(
                m.comp_data,
                m.comp_size,
                m.uncomp_size,
                m.imp_large_wnd,
                m.imp_lit_tree,
                false, // pk101_bug_compat=false
                &src_used,
                dst,
            )) == implode.explode_stat_t.HWEXPLODE_OK) and
                src_used == m.comp_size)
            {
                return true;
            }

            if ((try implode.hwexplode(
                m.comp_data,
                m.comp_size,
                m.uncomp_size,
                m.imp_large_wnd,
                m.imp_lit_tree,
                true, // pk101_bug_compat=true
                &src_used,
                dst,
            )) == implode.explode_stat_t.HWEXPLODE_OK and
                src_used == m.comp_size)
            {
                return true;
            }

            return false;
        },
        method_t.ZIP_DEFLATE => {
            if (deflate.hwinflate(m.comp_data, m.comp_size, &src_used, dst, m.uncomp_size, &dst_used) != deflate.inf_stat_t.HWINF_OK) {
                return false;
            }
            if (src_used != m.comp_size or dst_used != m.uncomp_size) {
                return false;
            }
            return true;
        },
        else => unreachable,
    }

    assert(false); // "Invalid method."
    return false;
}

// Write a Zip file containing num_memb members into dst, which must be large
// enough to hold the resulting data. Returns the number of bytes written, which
// is guaranteed to be less than or equal to the result of zip_max_size() when
// called with the corresponding arguments. comment shall be a null-terminated
// string or null. callback shall be null or point to a function which will
// get called after the compression of each member.
pub fn zip_write(
    dst: [*]u8,
    num_memb: u16,
    filenames: ?[*][*:0]const u8,
    file_data: ?[*][*]const u8,
    file_sizes: ?[*]const u32,
    mtimes: ?[*]const time.time_t,
    comment: ?[*:0]const u8,
    method: method_t,
    callback: ?fn (filename: [*:0]const u8, method: method_t, size: u32, comp_size: u32) CallbackError!void,
) !u32 {
    var i: u16 = 0;
    var p: [*]u8 = undefined;
    var eocdr: eocdr_t = undefined;
    var cfh: cfh_t = undefined;
    var lfh: lfh_t = undefined;
    var ok: bool = false;
    var name_len: u16 = 0;
    var data_dst: [*]u8 = undefined;
    var data_dst_sz: usize = 0;
    var comp_sz: usize = 0;
    var lfh_offset: u32 = 0;
    var cd_offset: u32 = 0;
    var eocdr_offset: u32 = 0;

    p = dst;

    // Write Local File Headers and compressed or stored data.
    i = 0;
    while (i < num_memb) : (i += 1) {
        assert(filenames != null);
        assert(strlen(filenames.?[i]) <= UINT16_MAX);
        name_len = @intCast(u16, strlen(filenames.?[i]));

        data_dst = p + LFH_BASE_SZ + name_len;
        data_dst_sz = if (file_sizes.?[i] > 0) file_sizes.?[i] - 1 else 0;

        if (method == method_t.ZIP_SHRINK and
            file_sizes.?[i] > 0 and
            shrink.hwshrink(
            file_data.?[i],
            file_sizes.?[i],
            data_dst,
            data_dst_sz,
            &comp_sz,
        )) {
            lfh.method = @enumToInt(method_t.ZIP_SHRINK);
            assert(comp_sz <= UINT32_MAX);
            lfh.comp_size = @intCast(u32, comp_sz);
            lfh.gp_flag = 0;
            lfh.extract_ver = (0 << 8) | 10; // DOS | PKZip 1.0
        } else if ((method == method_t.ZIP_REDUCE1 or
            method == method_t.ZIP_REDUCE2 or
            method == method_t.ZIP_REDUCE3 or
            method == method_t.ZIP_REDUCE4) and
            reduce.hwreduce(
            file_data.?[i],
            file_sizes.?[i],
            method_to_comp_factor(method),
            data_dst,
            data_dst_sz,
            &comp_sz,
        )) {
            lfh.method = @enumToInt(method);
            assert(comp_sz <= UINT32_MAX);
            lfh.comp_size = @intCast(u32, comp_sz);
            lfh.gp_flag = 0;
            lfh.extract_ver = (0 << 8) | 10; // DOS | PKZip 1.0
        } else if (method == method_t.ZIP_IMPLODE and
            implode.hwimplode(
            file_data.?[i],
            file_sizes.?[i],
            true, // large_wnd = true
            true, // lit_tree = true
            data_dst,
            data_dst_sz,
            &comp_sz,
        )) {
            lfh.method = @enumToInt(method_t.ZIP_IMPLODE);
            assert(comp_sz <= UINT32_MAX);
            lfh.comp_size = @intCast(u32, comp_sz);
            lfh.gp_flag = (0x1 << 1); // large_wnd
            lfh.gp_flag |= (0x1 << 2); // lit_tree
            lfh.extract_ver = (0 << 8) | 10; // DOS | PKZip 1.0
        } else if (method == method_t.ZIP_DEFLATE and
            deflate.hwdeflate(
            file_data.?[i],
            file_sizes.?[i],
            data_dst,
            data_dst_sz,
            &comp_sz,
        )) {
            lfh.method = @enumToInt(method_t.ZIP_DEFLATE);
            assert(comp_sz <= UINT32_MAX);
            lfh.comp_size = @intCast(u32, comp_sz);
            lfh.gp_flag = (0x1 << 1);
            lfh.extract_ver = (0 << 8) | 20; // DOS | PKZip 2.0
        } else {
            mem.copy(u8, data_dst[0..file_sizes.?[i]], file_data.?[i][0..file_sizes.?[i]]);
            lfh.method = @enumToInt(method_t.ZIP_STORE);
            lfh.comp_size = file_sizes.?[i];
            lfh.gp_flag = 0;
            lfh.extract_ver = (0 << 8) | 10; // DOS | PKZip 1.0
        }

        if (callback != null) {
            try callback.?(filenames.?[i], @intToEnum(method_t, @intCast(u4, lfh.method)), file_sizes.?[i], lfh.comp_size);
        }

        try ctime2dos(mtimes.?[i], &lfh.mod_date, &lfh.mod_time);
        lfh.crc32 = crc32(file_data.?[i], file_sizes.?[i]);
        lfh.uncomp_size = file_sizes.?[i];
        lfh.name_len = name_len;
        lfh.extra_len = 0;
        lfh.name = @ptrCast([*]const u8, filenames.?[i]);
        p += write_lfh(p, &lfh);
        p += lfh.comp_size;
    }

    assert(@intCast(usize, @ptrToInt(p) - @ptrToInt(dst)) <= UINT32_MAX);
    cd_offset = @intCast(u32, @ptrToInt(p) - @ptrToInt(dst));

    // Write the Central Directory based on the Local File Headers.
    lfh_offset = 0;
    i = 0;
    while (i < num_memb) : (i += 1) {
        ok = read_lfh(&lfh, dst, SIZE_MAX, lfh_offset);
        assert(ok);

        cfh.made_by_ver = lfh.extract_ver;
        cfh.extract_ver = lfh.extract_ver;
        cfh.gp_flag = lfh.gp_flag;
        cfh.method = lfh.method;
        cfh.mod_time = lfh.mod_time;
        cfh.mod_date = lfh.mod_date;
        cfh.crc32 = lfh.crc32;
        cfh.comp_size = lfh.comp_size;
        cfh.uncomp_size = lfh.uncomp_size;
        cfh.name_len = lfh.name_len;
        cfh.extra_len = 0;
        cfh.comment_len = 0;
        cfh.disk_nbr_start = 0;
        cfh.int_attrs = 0;
        cfh.ext_attrs = EXT_ATTR_ARC;
        cfh.lfh_offset = lfh_offset;
        cfh.name = lfh.name;
        p += write_cfh(p, &cfh);

        lfh_offset += LFH_BASE_SZ + lfh.name_len + lfh.comp_size;
    }

    assert(@intCast(usize, @ptrToInt(p) - @ptrToInt(dst)) <= UINT32_MAX);
    eocdr_offset = @intCast(u32, @ptrToInt(p) - @ptrToInt(dst));

    // Write the End of Central Directory Record.
    eocdr.disk_nbr = 0;
    eocdr.cd_start_disk = 0;
    eocdr.disk_cd_entries = num_memb;
    eocdr.cd_entries = num_memb;
    eocdr.cd_size = eocdr_offset - cd_offset;
    eocdr.cd_offset = cd_offset;
    eocdr.comment_len = @intCast(u16, if (comment == null) 0 else strlen(comment.?));
    eocdr.comment = if (comment == null) "" else comment.?;
    p += write_eocdr(p, &eocdr);

    assert(@intCast(usize, @ptrToInt(p) - @ptrToInt(dst)) <= zip_max_size(num_memb, filenames, file_sizes, comment));

    return @intCast(u32, @ptrToInt(p) - @ptrToInt(dst));
}

// Compute an upper bound on the dst size required by zip_write() for an
// archive with num_memb members with certain filenames, sizes, and archive
// comment. Returns zero on error, e.g. if a filename is longer than 2^16-1, or
// if the total file size is larger than 2^32-1.
pub fn zip_max_size(
    num_memb: u16,
    filenames: ?[*][*:0]const u8,
    file_sizes: ?[*]const u32,
    comment: ?[*:0]const u8,
) u32 {
    var comment_len: usize = 0;
    var name_len: usize = 0;
    var total: u64 = 0;
    var i: u16 = 0;

    comment_len = if (comment == null) 0 else strlen(comment.?);
    if (comment_len > UINT16_MAX) {
        return 0;
    }

    total = EOCDR_BASE_SZ + comment_len; // EOCDR

    i = 0;
    while (i < num_memb) : (i += 1) {
        assert(filenames != null);
        assert(file_sizes != null);
        name_len = strlen(filenames.?[i]);
        if (name_len > UINT16_MAX) {
            return 0;
        }

        total += CFH_BASE_SZ + name_len; // Central File Header
        total += LFH_BASE_SZ + name_len; // Local File Header
        total += file_sizes.?[i]; // Uncompressed data size.
    }

    if (total > UINT32_MAX) {
        return 0;
    }

    return @intCast(u32, total);
}
