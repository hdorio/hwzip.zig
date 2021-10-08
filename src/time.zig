// port of time.c from MIT-licensed musl libc v1.2.2 http://www.musl-libc.org/
// see LICENSE-time-dot-zig

const std = @import("std");
const math = std.math;

const INT_MIN = math.minInt(i32);
const INT_MAX = math.maxInt(i32);
const LEAPOCH = @as(i64, 946684800) + 86400 * (31 + 29);
const DAYS_PER_400Y = (365 * 400 + 97);
const DAYS_PER_100Y = (365 * 100 + 24);
const DAYS_PER_4Y = (365 * 4 + 1);
const ConversionError = error{
    EOVERFLOW,
};

pub const time_t: type = i64;

pub const tm_t: type = struct {
    tm_sec: i16 = 0, //                  Seconds. [0-60] (1 leap second) // c_int
    tm_min: i16 = 0, //                  Minutes. [0-59]                 // c_int
    tm_hour: i16 = 0, //                   Hours. [0-23]                 // c_int
    tm_mday: i16 = 1, //                     Day. [1-31]                 // c_int
    tm_mon: i16 = 0, //                    Month. [0-11]                 // c_int
    tm_year: i16 = 70, //                   Year - 1900.                 // c_int
    tm_wday: i16 = 0, //              Day of week. [0-6]                 // c_int
    tm_yday: i16 = 0, //           Days in year. [0-365]                 // c_int
    tm_isdst: i16 = 0, //                  DST. [-1/0/1]                 // c_int
    tm_gmtoff: i32 = 0, //         Seconds east of UTC.                  // c_long_int
    tm_zone: [*:0]const u8 = "UTC", // Timezone abbreviation.            // c_char
};

fn year_to_secs(year: i64, is_leap: *bool) i64 {
    if (year - @as(u64, 2) <= 136) {
        var y: i16 = @intCast(i16, year);
        var leaps: i16 = (y - 68) >> 2;
        if (((y - 68) & 3) == 0) {
            leaps -= 1;
            is_leap.* = true;
        } else {
            is_leap.* = false;
        }
        return 31536000 * (@intCast(i64, y) - 70) + 86400 * @intCast(i64, leaps);
    }

    var cycles: i16 = 0;
    var centuries: i16 = 0;
    var leaps: i16 = 0;
    var rem: i16 = 0;

    cycles = @intCast(i16, @divTrunc(year - 100, 400));
    rem = @intCast(i16, @rem(year - 100, 400));
    if (rem < 0) {
        cycles -= 1;
        rem += 400;
    }
    if (rem == 0) {
        is_leap.* = true;
        centuries = 0;
        leaps = 0;
    } else {
        if (rem >= 200) {
            if (rem >= 300) {
                centuries = 3;
                rem -= 300;
            } else {
                centuries = 2;
                rem -= 200;
            }
        } else {
            if (rem >= 100) {
                centuries = 1;
                rem -= 100;
            } else {
                centuries = 0;
            }
        }
        if (rem == 0) {
            is_leap.* = false;
            leaps = 0;
        } else {
            leaps = @divTrunc(rem, @as(u16, 4));
            rem = @rem(rem, @as(u16, 4));
            is_leap.* = rem == 0;
        }
    }

    var remove_leap: i16 = if (is_leap.*) 1 else 0;
    leaps += 97 * cycles + 24 * centuries - remove_leap;

    return (year - 100) * @as(i64, 31536000) + leaps * @as(i64, 86400) + 946684800 + 86400;
}

fn month_to_secs(month: usize, is_leap: bool) i64 {
    const secs_through_month = [_]i64{
        0,           31 * 86400,  59 * 86400,  90 * 86400,
        120 * 86400, 151 * 86400, 181 * 86400, 212 * 86400,
        243 * 86400, 273 * 86400, 304 * 86400, 334 * 86400,
    };
    var t: i64 = secs_through_month[month];
    if (is_leap and month >= 2) {
        t += 86400;
    }
    return t;
}

pub fn mktime(tm: *tm_t) time_t {
    var t: time_t = 0;

    //__tm_to_secs
    {
        var is_leap: bool = false;
        var year: i64 = tm.tm_year;
        var month: i16 = tm.tm_mon;

        if (month >= 12 or month < 0) {
            var adj: i16 = @divTrunc(month, 12);
            month = @rem(month, 12);
            if (month < 0) {
                adj -= 1;
                month += 12;
            }
            year += adj;
        }

        t = year_to_secs(year, &is_leap);
        t += month_to_secs(@intCast(usize, month), is_leap);
        t += @as(i64, 86400) * (tm.tm_mday - 1);
        t += @as(i64, 3600) * tm.tm_hour;
        t += @as(i64, 60) * tm.tm_min;
        t += tm.tm_sec;
    }

    return t;
}

pub fn localtime(tp: *const time_t) !*tm_t {
    var t: time_t = tp.*;
    var tm: tm_t = undefined;

    var days: i64 = 0;
    var secs: i64 = 0;
    var years: i64 = 0;
    var remdays: i64 = 0;
    var remsecs: i64 = 0;
    var remyears: i64 = 0;

    var qc_cycles: i64 = 0;
    var c_cycles: i64 = 0;
    var q_cycles: i64 = 0;
    var months: i64 = 0;
    var wday: i64 = 0;
    var yday: i64 = 0;
    var leap: i64 = 0;
    const days_in_month = [_]u8{ 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, 31, 29 };
    // Reject time_t values whose year would overflow int
    if (t < INT_MIN * @as(i64, 31622400) or t > INT_MAX * @as(i64, 31622400)) {
        return ConversionError.EOVERFLOW;
    }

    secs = t - LEAPOCH;
    days = @divTrunc(secs, 86400);
    remsecs = @rem(secs, 86400);
    if (remsecs < 0) {
        remsecs += 86400;
        days -= 1;
    }

    wday = @rem(3 + days, 7);
    if (wday < 0) wday += 7;

    qc_cycles = @divTrunc(days, DAYS_PER_400Y);
    remdays = @rem(days, DAYS_PER_400Y);
    if (remdays < 0) {
        remdays += DAYS_PER_400Y;
        qc_cycles -= 1;
    }

    c_cycles = @divTrunc(remdays, DAYS_PER_100Y);
    if (c_cycles == 4) c_cycles -= 1;
    remdays -= c_cycles * DAYS_PER_100Y;

    q_cycles = @divTrunc(remdays, DAYS_PER_4Y);
    if (q_cycles == 25) q_cycles -= 1;
    remdays -= q_cycles * DAYS_PER_4Y;

    remyears = @divTrunc(remdays, 365);
    if (remyears == 4) remyears -= 1;
    remdays -= remyears * 365;

    leap = if (remyears == 0 and (q_cycles > 1 or c_cycles == 0)) 1 else 0;
    yday = remdays + 31 + 28 + leap;
    if (yday >= 365 + leap) yday -= 365 + leap;

    years = remyears + 4 * q_cycles + 100 * c_cycles + @as(i64, 400) * qc_cycles;

    months = 0;
    while (days_in_month[@intCast(usize, months)] <= remdays) : (months += 1) {
        remdays -= days_in_month[@intCast(usize, months)];
    }

    if (months >= 10) {
        months -= 12;
        years += 1;
    }

    if (years + 100 > INT_MAX or years + 100 < INT_MIN) {
        return ConversionError.EOVERFLOW;
    }

    tm.tm_year = @intCast(i16, years + 100);
    tm.tm_mon = @intCast(i16, months + 2);
    tm.tm_mday = @intCast(i16, remdays + 1);
    tm.tm_wday = @intCast(i16, wday);
    tm.tm_yday = @intCast(i16, yday);

    tm.tm_hour = @intCast(i16, @divTrunc(remsecs, 3600));
    tm.tm_min = @intCast(i16, @rem(@divTrunc(remsecs, 60), 60));
    tm.tm_sec = @intCast(i16, @rem(remsecs, 60));

    return &tm;
}
