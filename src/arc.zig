const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub fn LockRefArenaArc(comptime T: type) type {
	// FullArgs is a tuple that represents the arguments to T.init(...)
	// The first argument to T.init must always be an Allocator (something we enforce here)
	// But, when the init(...) and setValue(...) methods of this struct are called
	// we don't expect FullArgs. We expect something like FullArgs[1..], that is,
	// the arguments without the allocator. This is because we'll inject an arena
	// allocator into the args within init/setValue.
	// Thus, Args, more or less, FullArgs[1..], but we can't just do FullArgs[1..]
	// we need to build a new Struct.
	const FullArgs = std.meta.ArgsTuple(@TypeOf(T.init));
	const full_fields = std.meta.fields(FullArgs);
	const ARG_COUNT = full_fields.len;

	if (ARG_COUNT == 0 or full_fields[0].type != std.mem.Allocator) {
		@compileError("The first argument to " ++ @typeName(T) ++ ".init must be an std.mem.Allocator");
	}

	var arg_fields: [full_fields.len - 1]std.builtin.Type.StructField = undefined;
	inline for (full_fields[1..], 0..) |field, index| {
		arg_fields[index] = field;
		// shift the name down by 1
		// so if our FullArgs is (allocator: Allocator, id: usize)
		//                        0                      1
		// then our Args will be (id: usize)
		//                        0
		arg_fields[index].name = std.fmt.comptimePrint("{d}", .{index});
	}

	const Args = @Type(.{
		.Struct = .{
			.layout = .auto,
			.is_tuple = true,
			.fields = &arg_fields,
			.decls = &[_]std.builtin.Type.Declaration{},
		},
	});

	return struct {
		arc: *Arc,
		allocator: Allocator,
		mutex: std.Thread.Mutex,

		const Self = @This();
		pub const Arc = ArenaArc(T);

		pub fn init(allocator: Allocator, args: Args) !Self {
			return .{
				.mutex = .{},
				.allocator = allocator,
				.arc = try createArc(allocator, args),
			};
		}

		pub fn deinit(self: *Self) void {
			self.mutex.lock();
			self.arc.release();
			self.mutex.unlock();
		}

		pub fn acquire(self: *Self) *Arc {
			self.mutex.lock();
			defer self.mutex.unlock();
			var arc = self.arc;
			arc.acquire();
			return arc;
		}

		pub fn setValue(self: *Self, args: Args) !void {
			const arc = try createArc(self.allocator, args);
			self.mutex.lock();
			var existing = self.arc;
			self.arc = arc;
			self.mutex.unlock();
			existing.release();
		}

		fn createArc(allocator: Allocator, args: Args) !*Arc {
			const arena = try allocator.create(ArenaAllocator);
			errdefer allocator.destroy(arena);

			arena.* = std.heap.ArenaAllocator.init(allocator);
			errdefer arena.deinit();

			const aa = arena.allocator();
			// args doesn't contain our allocator
			// we're going to push the arc.arena.allocator at the head of args
			// which means creating a new args and copying the values over
			var full_args: FullArgs = undefined;
			full_args[0] = aa;
			inline for (1..ARG_COUNT) |i| {
				full_args[i] = args[i-1];
			}

			const arc = try aa.create(Arc);
			arc.* = .{
				._rc = 1,
				.arena = arena,
				.value = try @call(.auto, T.init, full_args),
			};
			return arc;
		}

		pub fn jsonStringify(self: *Self, jws: anytype) !void {
			var arc = self.acquire();
			defer arc.release();
			return jws.write(arc.value);
		}
	};
}

pub fn ArenaArc(comptime T: type) type {
	return struct {
		value: T,
		arena: *ArenaAllocator,
		_rc: usize,

		const Self = @This();

		pub fn acquire(self: *Self) void {
			_ = @atomicRmw(usize, &self._rc, .Add, 1, .monotonic);
		}

		pub fn release(self: *Self) void {
			// returns the value before the sub, so if the value before the sub was 1,
			// it means we no longer have anything referencing this
			if (@atomicRmw(usize, &self._rc, .Sub, 1, .monotonic) == 1) {
				const arena = self.arena;
				const allocator = self.arena.child_allocator;
				arena.deinit();
				allocator.destroy(arena);
			}
		}

		pub fn jsonStringify(self: *const Self, jws: anytype) !void {
			return jws.write(self.value);
		}
	};
}

const t = @import("zul.zig").testing;
test "LockRefArenaArc" {
	{
		var ref = try LockRefArenaArc(TestValue).init(t.allocator, .{"test"});
		ref.deinit();
	}

	var ref = try LockRefArenaArc(TestValue).init(t.allocator, .{"hello"});
	defer ref.deinit();

	// keep this one around and re-test it at the end, it should still be valid
	// and still be the same value
	const arc1 = ref.acquire();
	defer arc1.release();
	try t.expectEqual("hello", arc1.value.str);

	try ref.setValue(.{"world"});

	{
		const arc2 = ref.acquire();
		defer arc2.release();
		try t.expectEqual("world", arc2.value.str);
	}

	// this reference should still be valid
	try t.expectEqual("hello", arc1.value.str);
}

const TestValue = struct {
	str: []const u8,

	fn init(allocator: Allocator, original: []const u8) !TestValue {
		return .{.str = try allocator.dupe(u8, original)};
	}
};
