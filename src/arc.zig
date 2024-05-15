const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

// This API is weird, and I'm still playing with it.
pub fn LockRefArenaArc(comptime T: type) type {
	return struct {
		value: *Value,
		allocator: Allocator,
		mutex: std.Thread.Mutex,

		const Self = @This();
		pub const Value = ArenaArc(T);

		const CreateResult = struct {
			ref: Self,
			arena: Allocator,
			value_ptr: *T,

			// should only be called in failure cases
			pub fn deinit(self: *CreateResult) void {
				self.ref.deinit();
			}
		};

		pub fn create(allocator: Allocator) !CreateResult {
			const value = try Value.create(allocator);

			const ref = .{
				.mutex = .{},
				.value = value,
				.allocator = allocator,
			};

			return .{
				.ref = ref,
				.value_ptr = &value.value,
				.arena = value._arena.allocator(),
			};
		}

		pub fn deinit(self: *Self) void {
			self.mutex.lock();
			self.value.release();
			self.mutex.unlock();
		}

		pub fn acquire(self: *Self) *Value {
			self.mutex.lock();
			var value = self.value;
			value.acquire();
			self.mutex.unlock();
			return value;
		}

		const NewResult = struct {
			_value: *Value,
			value_ptr: *T,
			arena: Allocator,

			// should only be called in if something bad happens
			pub fn deinit(self: *NewResult) void {
				self._value.release();
			}

			pub fn acquire(self: *NewResult) *Value {
				var value = self._value;
				value.acquire();
				return value;
			}
		};

		pub fn new(self: *const Self) !NewResult {
			const value = try Value.create(self.allocator);
			return .{
				._value = value,
				.value_ptr = &value.value,
				.arena = value._arena.allocator(),
			};
		}

		pub fn swap(self: *Self, n: NewResult) void {
			self.mutex.lock();
			var existing = self.value;
			self.value = n._value;
			self.mutex.unlock();

			existing.release();
		}
	};
}

pub fn ArenaArc(comptime T: type) type {
	return struct {
		value: T,
		_rc: usize,
		_arena: ArenaAllocator,

		const Self = @This();

		fn create(allocator: Allocator) !*Self {
			var arena = ArenaAllocator.init(allocator);
			errdefer arena.deinit();

			const self = try arena.allocator().create(Self);
			self.* = .{
				._rc = 1,
				._arena = arena,
				.value = undefined,
			};

			return self;
		}

		pub fn acquire(self: *Self) void {
			_ = @atomicRmw(usize, &self._rc, .Add, 1, .monotonic);
		}

		pub fn release(self: *Self) void {
			// returns the value before the sub, so if the value before the sub was 1,
			// it means we no longer have anything referencing this
			if (@atomicRmw(usize, &self._rc, .Sub, 1, .monotonic) == 1) {
				self._arena.deinit();
			}
		}
	};
}

const t = @import("zul.zig").testing;
test "LockRefArenaArc: basic" {
	{
		var create = try LockRefArenaArc([]const u8).create(t.allocator);
		defer create.ref.deinit();
	}

	{
		var create = try LockRefArenaArc([]const u8).create(t.allocator);
		var ref = create.ref;
		defer ref.deinit();
		create.value_ptr.* = try create.arena.dupe(u8, "hello");

		const arc1 = ref.acquire();
		defer arc1.release();

		{
			const arc2 = ref.acquire();
			defer arc2.release();
			try t.expectEqual("hello", arc2.value);
		}

		const new1 = try ref.new();
		new1.value_ptr.*= try new1.arena.dupe(u8, "world");
		ref.swap(new1);

		const arc3 = ref.acquire();
		defer arc3.release();
		try t.expectEqual("world", arc3.value);

		var new2 = try ref.new();
		new2.value_ptr.*= try new2.arena.dupe(u8, "!!!");
		ref.swap(new2);

		const arc4 = new2.acquire();
		defer arc4.release();
		try t.expectEqual("!!!", arc4.value);

		// this reference should still be valid
		try t.expectEqual("hello", arc1.value);
	}
}
