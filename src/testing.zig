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

pub fn expectNull(actual: anytype) !void {
	try expectEqual(null, actual);
}

pub fn expectTrue(actual: bool) !void {
	try expectEqual(true, actual);
}

pub fn expectFalse(actual: bool) !void {
	try expectEqual(false, actual);
}

pub const expectError = std.testing.expectError;
pub const expectSlice = std.testing.expectEqualSlices;
pub const expectString = std.testing.expectEqualStrings;


pub const allocator = std.testing.allocator;
pub var arena = std.heap.ArenaAllocator.init(allocator);

pub fn reset() void {
	_ = arena.reset(.free_all);
}

pub const Random = struct {
	var instance: ?std.rand.DefaultPrng = null;

	pub fn bytes(min: u32, max: u32) []u8 {
		var r = random();
		const l = r.intRangeAtMost(u32, min, max);
		const buf = arena.allocator().alloc(u8, l) catch unreachable;
		r.bytes(buf);
		return buf;
	}

	pub fn fillAtLeast(buf: []u8, min: usize) []u8 {
		var r = random();
		const l = r.intRangeAtMost(usize, min, buf.len);
		r.bytes(buf[0..l]);
		return buf;
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
