const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Opts = struct {
    count: u32 = 1,
    backlog: u32 = 128,
};

pub fn ThreadPool(comptime F: anytype) type {
    const Args = std.meta.ArgsTuple(@TypeOf(F));
    return struct {
        io: Io,
        group: Io.Group,
        backlog_sem: Io.Semaphore,
        concurrency_sem: Io.Semaphore,
        queued: std.atomic.Value(usize),

        const Self = @This();

        pub fn init(allocator: Allocator, io: Io, opts: Opts) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .io = io,
                .group = .init,
                .backlog_sem = .{ .permits = opts.backlog },
                .concurrency_sem = .{ .permits = opts.count },
                .queued = .init(0),
            };
            return self;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.group.await(self.io) catch {};
            allocator.destroy(self);
        }

        pub fn empty(self: *Self) bool {
            return self.queued.load(.acquire) == 0;
        }

        pub fn spawn(self: *Self, args: Args) !void {
            try self.backlog_sem.wait(self.io);
            _ = self.queued.fetchAdd(1, .release);
            self.group.async(self.io, runOnce, .{ self, args });
        }

        fn runOnce(self: *Self, args: Args) Io.Cancelable!void {
            self.backlog_sem.post(self.io);
            _ = self.queued.fetchSub(1, .release);
            try self.concurrency_sem.wait(self.io);
            defer self.concurrency_sem.post(self.io);
            @call(.auto, F, args);
        }
    };
}

const t = @import("zul.zig").testing;
test "ThreadPool: small fuzz" {
    testSum = 0; // global defined near the end of this file
    var tp = try ThreadPool(testIncr).init(t.allocator, t.io, .{ .count = 3, .backlog = 3 });

    for (0..50_000) |_| {
        try tp.spawn(.{1});
    }
    while (tp.empty() == false) {
        try Io.sleep(t.io, .fromMilliseconds(1), .real);
    }
    tp.deinit(t.allocator);
    try t.expectEqual(50_000, testSum);
}

test "ThreadPool: large fuzz" {
    testSum = 0; // global defined near the end of this file
    var tp = try ThreadPool(testIncr).init(t.allocator, t.io, .{ .count = 50, .backlog = 1000 });

    for (0..50_000) |_| {
        try tp.spawn(.{1});
    }
    while (tp.empty() == false) {
        try Io.sleep(t.io, .fromMilliseconds(1), .real);
    }
    tp.deinit(t.allocator);
    try t.expectEqual(50_000, testSum);
}

var testSum: u64 = 0;
fn testIncr(c: u64) void {
    _ = @atomicRmw(u64, &testSum, .Add, c, .monotonic);
}
