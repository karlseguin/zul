const std = @import("std");
const crypto = std.crypto;
const time = std.time;
const testing = std.testing;

// ULID Specification Implementation for Zig
// Based on https://github.com/ulid/spec

// Constants from ULID specification
const ENCODING_LENGTH = 26;
const TIME_LENGTH = 10;
const RANDOM_LENGTH = 16;
const TIMESTAMP_BYTES = 6;
const RANDOMNESS_BYTES = 10;
const TOTAL_BYTES = TIMESTAMP_BYTES + RANDOMNESS_BYTES;

// Maximum timestamp value (2^48 - 1)
const MAX_TIMESTAMP: u64 = 281474976710655;

// Crockford's Base32 alphabet (excludes I, L, O, U to avoid confusion)
const ENCODING_CHARS = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

// Decoding lookup table for Crockford's Base32
const DECODING_TABLE = blk: {
    var table: [256]u8 = [_]u8{0xFF} ** 256;

    // Numbers 0-9
    for (0..10) |i| {
        table['0' + i] = @intCast(i);
    }

    // Letters A-Z (excluding I, L, O, U)
    const letters = "ABCDEFGHJKMNPQRSTVWXYZ";
    for (letters, 0..) |c, i| {
        table[c] = @intCast(i + 10);
        // Also support lowercase
        table[c + 32] = @intCast(i + 10);
    }

    // Handle special cases for excluded letters
    table['I'] = 1;
    table['i'] = 1; // I -> 1
    table['L'] = 1;
    table['l'] = 1; // L -> 1
    table['O'] = 0;
    table['o'] = 0; // O -> 0
    table['U'] = table['V'];
    table['u'] = table['v']; // U -> V

    break :blk table;
};

pub const ULIDError = error{
    InvalidLength,
    InvalidCharacter,
    TimestampTooLarge,
    ClockGoingBackwards,
    OutOfMemory,
};

/// ULID structure representing a 128-bit identifier
pub const ULID = struct {
    bytes: [TOTAL_BYTES]u8,

    const Self = @This();

    /// Create a new ULID with the current timestamp and random data
    pub fn new() Self {
        return newWithTime(time.milliTimestamp());
    }

    /// Create a new ULID with a specific timestamp
    pub fn newWithTime(ts: i64) Self {
        var prng = std.rand.DefaultPrng.init(@intCast(time.nanoTimestamp()));
        return newWithTimeAndRandom(ts, prng.random());
    }

    /// Create a new ULID with specific timestamp and random source
    pub fn newWithTimeAndRandom(ts: i64, random: std.rand.Random) Self {
        const ts_byte: u64 = @intCast(@max(0, ts));

        var ulid = Self{ .bytes = undefined };

        // Encode timestamp (48 bits / 6 bytes) in big-endian
        ulid.bytes[0] = @intCast((ts_byte >> 40) & 0xFF);
        ulid.bytes[1] = @intCast((ts_byte >> 32) & 0xFF);
        ulid.bytes[2] = @intCast((ts_byte >> 24) & 0xFF);
        ulid.bytes[3] = @intCast((ts_byte >> 16) & 0xFF);
        ulid.bytes[4] = @intCast((ts_byte >> 8) & 0xFF);
        ulid.bytes[5] = @intCast(ts_byte & 0xFF);

        // Fill randomness (80 bits / 10 bytes)
        random.bytes(ulid.bytes[TIMESTAMP_BYTES..]);

        return ulid;
    }

    /// Create ULID from raw bytes
    pub fn fromBytes(bytes: [TOTAL_BYTES]u8) Self {
        return Self{ .bytes = bytes };
    }

    /// Parse ULID from string representation
    pub fn fromString(str: []const u8) ULIDError!Self {
        if (str.len != ENCODING_LENGTH) {
            return ULIDError.InvalidLength;
        }

        var ulid = Self{ .bytes = undefined };

        // Decode the string using Crockford's Base32
        var acc: u128 = 0;
        for (str) |c| {
            const val = DECODING_TABLE[c];
            if (val == 0xFF) {
                return ULIDError.InvalidCharacter;
            }
            acc = (acc << 5) | val;
        }

        // Extract bytes in big-endian order
        for (0..TOTAL_BYTES) |i| {
            ulid.bytes[TOTAL_BYTES - 1 - i] = @intCast(acc & 0xFF);
            acc >>= 8;
        }

        // Validate timestamp
        if (ulid.timestamp() > MAX_TIMESTAMP) {
            return ULIDError.TimestampTooLarge;
        }

        return ulid;
    }

    /// Convert ULID to string representation
    pub fn toString(self: Self, buffer: []u8) []u8 {
        std.debug.assert(buffer.len >= ENCODING_LENGTH);

        // Convert bytes to 128-bit integer
        var acc: u128 = 0;
        for (self.bytes) |byte| {
            acc = (acc << 8) | byte;
        }

        // Encode using Crockford's Base32
        for (0..ENCODING_LENGTH) |i| {
            buffer[ENCODING_LENGTH - 1 - i] = ENCODING_CHARS[@intCast(acc & 0x1F)];
            acc >>= 5;
        }

        return buffer[0..ENCODING_LENGTH];
    }

    /// Get timestamp component as milliseconds since Unix epoch
    pub fn timestamp(self: Self) u64 {
        return (@as(u64, self.bytes[0]) << 40) |
            (@as(u64, self.bytes[1]) << 32) |
            (@as(u64, self.bytes[2]) << 24) |
            (@as(u64, self.bytes[3]) << 16) |
            (@as(u64, self.bytes[4]) << 8) |
            (@as(u64, self.bytes[5]));
    }

    /// Get randomness component as bytes
    pub fn randomness(self: Self) [RANDOMNESS_BYTES]u8 {
        return self.bytes[TIMESTAMP_BYTES..][0..RANDOMNESS_BYTES].*;
    }

    /// Compare two ULIDs for ordering (lexicographic)
    pub fn compare(self: Self, other: Self) std.math.Order {
        return std.mem.order(u8, &self.bytes, &other.bytes);
    }

    /// Check if two ULIDs are equal
    pub fn eql(self: Self, other: Self) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Format ULID for printing
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        var buffer: [ENCODING_LENGTH]u8 = undefined;
        const str = self.toString(&buffer);
        try writer.writeAll(str);
    }
};

/// Monotonic ULID generator that ensures lexicographic ordering
pub const MonotonicGenerator = struct {
    last_timestamp: u64,
    last_random: [RANDOMNESS_BYTES]u8,
    prng: std.rand.DefaultPrng,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .last_timestamp = 0,
            .last_random = [_]u8{0} ** RANDOMNESS_BYTES,
            .prng = std.rand.DefaultPrng.init(@intCast(time.nanoTimestamp())),
        };
    }

    pub fn next(self: *Self) ULIDError!ULID {
        return self.nextWithTime(time.milliTimestamp());
    }

    pub fn nextWithTime(self: *Self, timestamp: i64) ULIDError!ULID {
        const ts: u64 = @intCast(@max(0, timestamp));

        if (ts > MAX_TIMESTAMP) {
            return ULIDError.TimestampTooLarge;
        }

        var ulid = ULID{ .bytes = undefined };

        // Encode timestamp
        ulid.bytes[0] = @intCast((ts >> 40) & 0xFF);
        ulid.bytes[1] = @intCast((ts >> 32) & 0xFF);
        ulid.bytes[2] = @intCast((ts >> 24) & 0xFF);
        ulid.bytes[3] = @intCast((ts >> 16) & 0xFF);
        ulid.bytes[4] = @intCast((ts >> 8) & 0xFF);
        ulid.bytes[5] = @intCast(ts & 0xFF);

        if (ts == self.last_timestamp) {
            // Same timestamp: increment the random part
            var carry: u16 = 1;
            var i: usize = RANDOMNESS_BYTES;
            while (i > 0 and carry > 0) {
                i -= 1;
                const sum = @as(u16, self.last_random[i]) + carry;
                self.last_random[i] = @intCast(sum & 0xFF);
                carry = sum >> 8;
            }

            // If we overflow, we need to generate new random data
            if (carry > 0) {
                self.prng.random().bytes(&self.last_random);
            }
        } else if (ts < self.last_timestamp) {
            return ULIDError.ClockGoingBackwards;
        } else {
            // New timestamp: generate new random data
            self.prng.random().bytes(&self.last_random);
            self.last_timestamp = ts;
        }

        // Copy randomness
        @memcpy(ulid.bytes[TIMESTAMP_BYTES..], &self.last_random);

        return ulid;
    }
};

// Tests
test "ULID creation and parsing" {
    const ulid1 = ULID.new();

    var buffer: [ENCODING_LENGTH]u8 = undefined;
    const str = ulid1.toString(&buffer);

    try testing.expect(str.len == ENCODING_LENGTH);

    const ulid2 = try ULID.fromString(str);
    try testing.expect(ulid1.eql(ulid2));
}

test "ULID ordering" {
    const ulid1 = ULID.newWithTime(1000);
    const ulid2 = ULID.newWithTime(2000);

    try testing.expect(ulid1.compare(ulid2) == .lt);
    try testing.expect(ulid2.compare(ulid1) == .gt);
    try testing.expect(ulid1.compare(ulid1) == .eq);
}

test "ULID timestamp extraction" {
    const timestamp: i64 = 1609459200000; // 2021-01-01T00:00:00Z
    const ulid = ULID.newWithTime(timestamp);

    try testing.expect(ulid.timestamp() == timestamp);
}

test "ULID string format validation" {
    // Test invalid length
    try testing.expectError(ULIDError.InvalidLength, ULID.fromString("01ARZ3NDEKTSV4RRFFQ69G5FA"));
    try testing.expectError(ULIDError.InvalidLength, ULID.fromString("01ARZ3NDEKTSV4RRFFQ69G5FAVV"));

    // Test invalid characters
    try testing.expectError(ULIDError.InvalidCharacter, ULID.fromString("01ARZ3NDEKTSV4RRFFQ69G5F@V"));
}

test "ULID maximum timestamp" {
    // Test maximum valid timestamp
    const ulid = ULID.newWithTime(@intCast(MAX_TIMESTAMP));
    try testing.expect(ulid.timestamp() == MAX_TIMESTAMP);

    // Test that parsing maximum encoded ULID works
    const max_ulid_str = "7ZZZZZZZZZZZZZZZZZZZZZZZZZ";
    const max_ulid = try ULID.fromString(max_ulid_str);
    try testing.expect(max_ulid.timestamp() == MAX_TIMESTAMP);
}

test "MonotonicGenerator" {
    var generator = MonotonicGenerator.init();

    const ulid1 = try generator.nextWithTime(1000);
    const ulid2 = try generator.nextWithTime(1000);
    const ulid3 = try generator.nextWithTime(2000);

    // ULIDs with same timestamp should be ordered
    try testing.expect(ulid1.compare(ulid2) == .lt);
    try testing.expect(ulid2.compare(ulid3) == .lt);

    // Test clock going backwards
    try testing.expectError(ULIDError.ClockGoingBackwards, generator.nextWithTime(1500));
}

test "ULID case insensitive parsing" {
    const ulid = ULID.new();
    var buffer: [ENCODING_LENGTH]u8 = undefined;
    const str = ulid.toString(&buffer);

    // Convert to lowercase
    var lower_str: [ENCODING_LENGTH]u8 = undefined;
    for (str, 0..) |c, i| {
        lower_str[i] = std.ascii.toLower(c);
    }

    const parsed_ulid = try ULID.fromString(&lower_str);
    try testing.expect(ulid.eql(parsed_ulid));
}

test "ULID excluded characters mapping" {
    // Test that excluded characters are properly mapped
    const test_cases = [_]struct { input: u8, expected: u8 }{
        .{ .input = 'I', .expected = '1' },
        .{ .input = 'i', .expected = '1' },
        .{ .input = 'L', .expected = '1' },
        .{ .input = 'l', .expected = '1' },
        .{ .input = 'O', .expected = '0' },
        .{ .input = 'o', .expected = '0' },
    };

    for (test_cases) |case| {
        const input_val = DECODING_TABLE[case.input];
        const expected_val = DECODING_TABLE[case.expected];
        try testing.expect(input_val == expected_val);
    }
}
