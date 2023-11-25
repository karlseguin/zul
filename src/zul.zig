const std = @import("std");

pub const fs = @import("fs.zig");
pub const http = @import("http.zig");
pub const uuid = @import("uuid.zig");
pub const testing = @import("testing.zig");
pub const benchmark = @import("benchmark.zig");

pub const StringBuilder = @import("string_builder.zig").StringBuilder;

const datetime = @import("datetime.zig");

pub const Date = datetime.Date;
pub const Time = datetime.Time;

pub fn Managed(comptime T: type) type {
	return struct {
		value: T,
		arena: *std.heap.ArenaAllocator,

		const Self = @This();

		pub fn fromJson(parsed: std.json.Parsed(T)) Self {
			return  .{
				.arena = parsed.arena,
				.value = parsed.value,
			};
		}

		pub fn deinit(self: Self) void {
			const arena = self.arena;
			const allocator = arena.child_allocator;
			arena.deinit();
			allocator.destroy(arena);
		}
	};
}

test {
	@import("std").testing.refAllDecls(@This());
}
