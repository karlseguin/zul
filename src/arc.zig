const std = @import("std");
const Io = std.Io;

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
    const args_info: std.lang.Type = @typeInfo(FullArgs);
    const info = args_info.@"struct";
    const ARG_COUNT = info.field_types.len;

    if (ARG_COUNT == 0 or info.field_types[0] != std.mem.Allocator) {
        @compileError("The first argument to " ++ @typeName(T) ++ ".init must be an std.mem.Allocator");
    }

    var arg_fields: [info.field_types.len - 1]type = undefined;
    inline for (info.field_types[1..], 0..) |field, index| {
        arg_fields[index] = field;
    }

    const Args = @Tuple(
        &arg_fields,
    );

    return struct {
        arc: *Arc,
        allocator: Allocator,
        mutex: Io.Mutex,
        io: Io,

        const Self = @This();

        pub fn init(io: Io, allocator: Allocator, args: Args) !Self {
            return .{
                .mutex = .init,
                .allocator = allocator,
                .arc = try createArc(allocator, args),
                .io = io,
            };
        }

        pub fn initWithValue(io: Io, allocator: Allocator, value: T) !Self {
            const arena = try allocator.create(ArenaAllocator);
            errdefer allocator.destroy(arena);

            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const arc = try arena.allocator().create(Self.Arc);
            arc.* = .{
                ._rc = 1,
                .arena = arena,
                .value = value,
            };

            return .{
                .arc = arc,
                .mutex = .init,
                .allocator = allocator,
                .io = io,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.arc.release();
            self.mutex.unlock(self.io);
        }

        pub fn acquire(self: *Self) *Arc {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var arc = self.arc;
            arc.acquire();
            return arc;
        }

        pub fn setValue(self: *Self, args: Args) !void {
            const arc = try createArc(self.allocator, args);
            try self.mutex.lock(self.io);
            var existing = self.arc;
            self.arc = arc;
            self.mutex.unlock(self.io);
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
                full_args[i] = args[i - 1];
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

        pub const Arc = struct {
            value: T,
            arena: *ArenaAllocator,
            _rc: usize,

            pub fn acquire(self: *Arc) void {
                _ = @atomicRmw(usize, &self._rc, .Add, 1, .monotonic);
            }

            pub fn release(self: *Arc) void {
                // returns the value before the sub, so if the value before the sub was 1,
                // it means we no longer have anything referencing this
                if (@atomicRmw(usize, &self._rc, .Sub, 1, .monotonic) == 1) {
                    const arena = self.arena;
                    const allocator = self.arena.child_allocator;
                    arena.deinit();
                    allocator.destroy(arena);
                }
            }

            pub fn jsonStringify(self: *const Arc, jws: anytype) !void {
                return jws.write(self.value);
            }
        };
    };
}

pub fn LockRefArc(comptime T: type) type {
    return struct {
        arc: *Arc,
        allocator: Allocator,
        mutex: Io.Mutex,
        io: Io,

        const Self = @This();

        pub fn init(io: Io, allocator: Allocator, value: T) !Self {
            return .{
                .mutex = .init,
                .allocator = allocator,
                .arc = try createArc(allocator, value),
                .io = io,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.arc.release();
            self.mutex.unlock(self.io);
        }

        pub fn acquire(self: *Self) *Arc {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var arc = self.arc;
            arc.acquire();
            return arc;
        }

        pub fn setValue(self: *Self, value: T) !void {
            const arc = try createArc(self.allocator, value);
            try self.mutex.lock(self.io);
            var existing = self.arc;
            self.arc = arc;
            self.mutex.unlock(self.io);
            existing.release();
        }

        fn createArc(allocator: Allocator, value: T) !*Self.Arc {
            const arc = try allocator.create(Self.Arc);
            arc.* = .{
                ._rc = 1,
                .value = value,
                .allocator = allocator,
            };
            return arc;
        }

        pub fn jsonStringify(self: *Self, jws: anytype) !void {
            var arc = self.acquire();
            defer arc.release();
            return jws.write(arc.value);
        }

        pub const Arc = struct {
            value: T,
            allocator: Allocator,
            _rc: usize,

            pub fn acquire(self: *Arc) void {
                _ = @atomicRmw(usize, &self._rc, .Add, 1, .monotonic);
            }

            pub fn release(self: *Arc) void {
                // returns the value before the sub, so if the value before the sub was 1,
                // it means we no longer have anything referencing this
                if (@atomicRmw(usize, &self._rc, .Sub, 1, .monotonic) == 1) {
                    const allocator = self.allocator;
                    allocator.destroy(self);
                }
            }

            pub fn jsonStringify(self: *const Arc, jws: anytype) !void {
                return jws.write(self.value);
            }
        };
    };
}

const t = @import("zul.zig").testing;
test "LockRefArenaArc" {
    {
        var ref = try LockRefArenaArc(TestArenaValue).init(t.io, t.allocator, .{"test"});
        ref.deinit();
    }

    var ref = try LockRefArenaArc(TestArenaValue).init(t.io, t.allocator, .{"hello"});
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

test "LockRefArenaArc: initWithValue" {
    var ref = try LockRefArenaArc(TestArenaValue).initWithValue(t.io, t.allocator, .{ .str = "teg" });
    defer ref.deinit();

    const arc1 = ref.acquire();
    defer arc1.release();
    try t.expectEqual("teg", arc1.value.str);
}

test "LockRefArc" {
    {
        var ref = try LockRefArc(TestValue).init(t.io, t.allocator, .{ .str = "test" });
        ref.deinit();
    }

    var ref = try LockRefArc(TestValue).init(t.io, t.allocator, .{ .str = "hello" });
    defer ref.deinit();

    // keep this one around and re-test it at the end, it should still be valid
    // and still be the same value
    const arc1 = ref.acquire();
    defer arc1.release();
    try t.expectEqual("hello", arc1.value.str);

    try ref.setValue(.{ .str = "world" });

    {
        const arc2 = ref.acquire();
        defer arc2.release();
        try t.expectEqual("world", arc2.value.str);
    }

    // this reference should still be valid
    try t.expectEqual("hello", arc1.value.str);
}

const TestArenaValue = struct {
    str: []const u8,

    fn init(allocator: Allocator, original: []const u8) !TestArenaValue {
        return .{ .str = try allocator.dupe(u8, original) };
    }
};

const TestValue = struct {
    str: []const u8,
};
