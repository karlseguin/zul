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
		} else if (comptime isStringArray(ptr.child)) {
			return std.testing.expectEqualStrings(expected, actual);
		} else if (ptr.child == []u8 or ptr.child == []const u8) {
			return expectStrings(expected, actual);
		},
		.Struct => |structType| {
			inline for (structType.fields) |field| {
				try expectEqual(@field(expected, field.name), @field(actual, field.name));
			}
			return;
		},
		.Union => |union_info| {
			if (union_info.tag_type == null) {
					@compileError("Unable to compare untagged union values");
			}
			const Tag = std.meta.Tag(@TypeOf(expected));

			const expectedTag = @as(Tag, expected);
			const actualTag = @as(Tag, actual);
			try expectEqual(expectedTag, actualTag);

			inline for (std.meta.fields(@TypeOf(actual))) |fld| {
				if (std.mem.eql(u8, fld.name, @tagName(actualTag))) {
					try expectEqual(@field(expected, fld.name), @field(actual, fld.name));
					return;
				}
			}
			unreachable;
		},
		else => {},
	}
	return std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

fn expectStrings(expected: []const []const u8, actual: anytype) !void {
	try t.expectEqual(expected.len, actual.len);
	for (expected, actual) |e, a| {
		try std.testing.expectEqualStrings(e, a);
	}
}

fn isStringArray(comptime T: type) bool {
	if (!is(.Array)(T) and !isPtrTo(.Array)(T)) {
		return false;
	}
	return std.meta.Elem(T) == u8;
}

pub const TraitFn = fn (type) bool;
pub fn is(comptime id: std.builtin.TypeId) TraitFn {
	const Closure = struct {
		pub fn trait(comptime T: type) bool {
			return id == @typeInfo(T);
		}
	};
	return Closure.trait;
}

pub fn isPtrTo(comptime id: std.builtin.TypeId) TraitFn {
	const Closure = struct {
		pub fn trait(comptime T: type) bool {
			if (!comptime isSingleItemPtr(T)) return false;
			return id == @typeInfo(std.meta.Child(T));
		}
	};
	return Closure.trait;
}

pub fn isSingleItemPtr(comptime T: type) bool {
	if (comptime is(.Pointer)(T)) {
		return @typeInfo(T).Pointer.size == .One;
	}
	return false;
}

pub fn expectDelta(expected: anytype, actual: anytype, delta: anytype) !void {
	var diff = expected - actual;
	if (diff < 0) {
		diff = -diff;
	}
	if (diff <= delta) {
		return;
	}

	print("Expected {} to be within {} of {}. Actual diff: {}", .{expected, delta, actual, diff});
	return error.NotWithinDelta;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
	if (@inComptime()) {
		@compileError(std.fmt.comptimePrint(fmt, args));
	} else {
		std.debug.print(fmt, args);
	}
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
