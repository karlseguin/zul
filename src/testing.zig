const std = @import("std");
const builtin = @import("builtin");

// std.testing.expectEqual won't coerce expected to actual, which is a problem
// when expected is frequently a comptime.
// https://github.com/ziglang/zig/issues/4437
pub fn expectEqual(expected: anytype, actual: anytype) !void {
	switch (@typeInfo(@TypeOf(actual))) {
		.Array => |arr| if (arr.child == u8) {
			return std.testing.expectEqualStrings(expected, &actual);
		},
		.Pointer => |ptr| if (ptr.child == u8) {
			return std.testing.expectEqualStrings(expected, actual);
		},
		else => {},
	}
	return std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

// Re-expose these as-is so that more cases can rely on zul.testing exclusively.
// Else, it's a pain to have both std.testing and zul.testing in a test.
pub const expect = std.testing.expect;
pub const expectFmt = std.testing.expectFmt;
pub const expectError = std.testing.expectError;
pub const expectEqualSlices = std.testing.expectEqualSlices;
pub const expectEqualStrings = std.testing.expectEqualStrings;
pub const expectEqualSentinel = std.testing.expectEqualSentinel;
pub const expectApproxEqAbs = std.testing.expectApproxEqAbs;
pub const expectApproxEqRel = std.testing.expectApproxEqRel;

pub const allocator = std.testing.allocator;
pub var arena = std.heap.ArenaAllocator.init(allocator);

pub fn reset() void {
	_ = arena.reset(.free_all);
}

pub const Random = struct {
	var instance: ?std.rand.DefaultPrng = null;

	pub fn bytes(min: usize, max: usize) []u8 {
		var r = random();
		const l = r.intRangeAtMost(usize, min, max);
		const buf = arena.allocator().alloc(u8, l) catch unreachable;
		r.bytes(buf);
		return buf;
	}

	pub fn fill(buf: []u8) void {
		var r = random();
		r.bytes(buf);
	}

	pub fn fillAtLeast(buf: []u8, min: usize) []u8 {
		var r = random();
		const l = r.intRangeAtMost(usize, min, buf.len);
		r.bytes(buf[0..l]);
		return buf;
	}

	pub fn intRange(comptime T: type, min: T, max: T) T {
		var r = random();
		return r.intRangeAtMost(T, min, max);
	}

	pub fn random() std.rand.Random {
		if (instance == null) {
			var seed: u64 = undefined;
			std.os.getrandom(std.mem.asBytes(&seed)) catch unreachable;
			instance = std.rand.DefaultPrng.init(seed);
		}
		return instance.?.random();
	}
};

const t = @This();
test "testing.rand: bytes" {
	defer t.reset();
	for (0..10) |_| {
		const bytes = Random.bytes(4, 8);
		try t.expectEqual(true, bytes.len >= 4 and bytes.len <= 8);
	}
}

test "testing.rand: fillAtLeast" {
	var buf: [10]u8 = undefined;

	for (0..10) |_| {
		const bytes = Random.fillAtLeast(&buf, 7);
		try t.expectEqual(true, bytes.len >= 7 and bytes.len <= 10);
	}
}

test "testing.rand: intRange" {
	for (0..10) |_| {
		const value = Random.intRange(u16, 3, 6);
		try t.expectEqual(true, value >= 3 and value <= 6);
	}
}

test "testing: doc example" {
	// clear's the arena allocator
	defer t.reset();

	// In addition to exposing std.testing.allocator as zul.testing.allocator
	// zul.testing.arena is an ArenaAllocator. An ArenaAllocator can
	// make managing test-specific allocations a lot simpler.
	// Just stick a `defer zul.testing.reset()` atop your test.
	var buf = try t.arena.allocator().alloc(u8, 5);

	// unlike std.testing.expectEqual, zul's expectEqual
	// will coerce expected to actual's type, so this is valid:
	try t.expectEqual(5, buf.len);

	@memcpy(buf[0..5], "hello");

	// zul's expectEqual also works with strings.
	try t.expectEqual("hello", buf);
}
