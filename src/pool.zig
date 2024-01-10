const std = @import("std");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

pub const GrowingOpts = struct {
	count: usize,
};

pub fn Growing(comptime T: type, comptime C: type) type {
	return struct {
		_ctx: C,
		_items: []*T,
		_available: usize,
		_mutex: Thread.Mutex,
		_allocator: Allocator,

		const Self = @This();

		pub fn init(allocator: Allocator, ctx: C, opts: GrowingOpts) !Self {
			const count = opts.count;

			const items = try allocator.alloc(*T, count);
			errdefer allocator.free(items);

			var initialized: usize = 0;
			errdefer {
				for (0..initialized) |i| {
					items[i].deinit();
					allocator.destroy(items[i]);
				}
			}

			for (0..count) |i| {
				items[i] = try allocator.create(T);
				errdefer allocator.destroy(items[i]);
				items[i].* = if (C == void) try T.init(allocator) else try T.init(allocator, ctx);
				initialized += 1;
			}

			return .{
				._ctx = ctx,
				._mutex = .{},
				._items = items,
				._available = count,
				._allocator = allocator,
			};
		}

		pub fn deinit(self: *Self) void {
			const allocator = self._allocator;
			for (self._items) |item| {
				item.deinit();
				allocator.destroy(item);
			}
			allocator.free(self._items);
		}

		pub fn acquire(self: *Self) !*T {
			const items = self._items;

			self._mutex.lock();
			const available = self._available;
			if (available == 0) {
				// dont hold the lock over factory
				self._mutex.unlock();

				const allocator = self._allocator;
				const item = try allocator.create(T);
				item.* = if (C == void) try T.init(allocator) else try T.init(allocator, self._ctx);
				return item;
			}

			const index = available - 1;
			const item = items[index];
			self._available = index;
			self._mutex.unlock();
			return item;
		}

		pub fn release(self: *Self, item: *T) void {
			item.reset();

			var items = self._items;
			self._mutex.lock();
			const available = self._available;
			if (available == items.len) {
				self._mutex.unlock();
				item.deinit();
				self._allocator.destroy(item);
				return;
			}
			items[available] = item;
			self._available = available + 1;
			self._mutex.unlock();
		}
	};
}

const t = @import("zul.zig").testing;
test "pool: acquire and release" {
	var p = try Growing(TestPoolItem, void).init(t.allocator, {}, .{.count = 2});
	defer p.deinit();

	const i1a = try p.acquire();
	try t.expectEqual(0, i1a.data[0]);
	i1a.data[0] = 250;

	const i2a = try p.acquire();
	const i3a = try p.acquire(); // this should be dynamically generated

	try t.expectEqual(false, i1a.data.ptr == i2a.data.ptr);
	try t.expectEqual(false, i2a.data.ptr == i3a.data.ptr);

	p.release(i1a);

	const i1b = try p.acquire();
	try t.expectEqual(0, i1b.data[0]); // ensure we called reset
	try t.expectEqual(true, i1a.data.ptr == i1b.data.ptr);

	p.release(i3a);
	p.release(i2a);
	p.release(i1b);
}

const TestPoolItem = struct {
	data: []u8,
	allocator: Allocator,

	fn init(allocator: Allocator) !TestPoolItem {
		const data = try allocator.alloc(u8, 1);
		data[0] = 0;

		return .{
			.data = data,
			.allocator = allocator,
		};
	}

	fn deinit(self: *TestPoolItem) void {
		self.allocator.free(self.data);
	}

	fn reset(self: *TestPoolItem) void {
		self.data[0] = 0;
	}
};
