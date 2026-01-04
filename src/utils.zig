// That file is incredibly badly named, but I honestly have no other ideas

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const windows = std.os.windows;
const assert = std.debug.assert;

// All of this struct is taken from stdlib, since it got removed by:
// 774df26835069039ba739828a7619393de01a5f2
// Link:
// https://codeberg.org/ziglang/zig/commit/774df26835069039ba739828a7619393de01a5f2#diff-27254822dc5b9d96f66367bd814d4b210d48cb6b
//
// There's technically a whole new std.Io impl, but it seems very convoluted
// If zul starts supporting the whole new Io stuff then it might be good to use
// the new impl.
pub const time = struct {
    /// Get a calendar timestamp, in seconds, relative to UTC 1970-01-01.
    /// Precision of timing depends on the hardware and operating system.
    /// The return value is signed because it is possible to have a date that is
    /// before the epoch.
    /// See `posix.clock_gettime` for a POSIX timestamp.
    pub fn timestamp() i64 {
        return @divFloor(milliTimestamp(), std.time.ms_per_s);
    }

    /// Get a calendar timestamp, in milliseconds, relative to UTC 1970-01-01.
    /// Precision of timing depends on the hardware and operating system.
    /// The return value is signed because it is possible to have a date that is
    /// before the epoch.
    /// See `posix.clock_gettime` for a POSIX timestamp.
    pub fn milliTimestamp() i64 {
        return @as(i64, @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms)));
    }

    /// Get a calendar timestamp, in microseconds, relative to UTC 1970-01-01.
    /// Precision of timing depends on the hardware and operating system.
    /// The return value is signed because it is possible to have a date that is
    /// before the epoch.
    /// See `posix.clock_gettime` for a POSIX timestamp.
    pub fn microTimestamp() i64 {
        return @as(i64, @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_us)));
    }

    /// Get a calendar timestamp, in nanoseconds, relative to UTC 1970-01-01.
    /// Precision of timing depends on the hardware and operating system.
    /// On Windows this has a maximum granularity of 100 nanoseconds.
    /// The return value is signed because it is possible to have a date that is
    /// before the epoch.
    /// See `posix.clock_gettime` for a POSIX timestamp.
    pub fn nanoTimestamp() i128 {
        switch (builtin.os.tag) {
            .windows => {
                // RtlGetSystemTimePrecise() has a granularity of 100 nanoseconds and uses the NTFS/Windows epoch,
                // which is 1601-01-01.
                const epoch_adj = std.time.epoch.windows * (std.time.ns_per_s / 100);
                return @as(i128, windows.ntdll.RtlGetSystemTimePrecise() + epoch_adj) * 100;
            },
            .wasi => {
                var ns: std.os.wasi.timestamp_t = undefined;
                const err = std.os.wasi.clock_time_get(.REALTIME, 1, &ns);
                assert(err == .SUCCESS);
                return ns;
            },
            .uefi => {
                const value, _ = std.os.uefi.system_table.runtime_services.getTime() catch return 0;
                return value.toEpoch();
            },
            else => {
                const ts = posix.clock_gettime(.REALTIME) catch |err| switch (err) {
                    error.UnsupportedClock, error.Unexpected => return 0, // "Precision of timing depends on hardware and OS".
                };
                return (@as(i128, ts.sec) * std.time.ns_per_s) + ts.nsec;
            },
        }
    }
};
