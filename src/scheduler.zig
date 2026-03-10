const std = @import("std");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const DateTime = @import("zul.zig").DateTime;

fn Job(comptime T: type) type {
    return struct {
        at: i64,
        task: T,
    };
}

pub fn Scheduler(comptime T: type, comptime C: type, io: std.Io) type {
    return struct {
        queue: Q,
        running: bool,
        mutex: std.Io.Mutex,
        cond: std.Io.Condition,
        thread: ?Thread,
        io: std.Io,
        allocator: std.mem.Allocator,

        const Q = std.PriorityQueue(Job(T), void, compare);
        const include_scheduler = @typeInfo(@TypeOf(T.run)).@"fn".params.len == 4;

        fn compare(_: void, a: Job(T), b: Job(T)) std.math.Order {
            return std.math.order(a.at, b.at);
        }

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .cond = .init,
                .mutex = .init,
                .thread = null,
                .running = false,
                .queue = Q.initContext({}),
            };
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.queue.deinit(self.allocator);
        }

        pub fn start(self: *Self, ctx: C) !void {
            {
                try self.mutex.lock(self.io);
                defer self.mutex.unlock(self.io);
                if (self.running == true) {
                    return error.AlreadyRunning;
                }
                self.running = true;
            }
            self.thread = try Thread.spawn(.{}, Self.run, .{ self, ctx });
        }

        pub fn stop(self: *Self) void {
            {
                self.mutex.lock(self.io) catch {};
                defer self.mutex.unlock(self.io);
                if (self.running == false) {
                    return;
                }
                self.running = false;
            }

            self.cond.signal(self.io);
            self.thread.?.join();
        }

        pub fn scheduleAt(self: *Self, task: T, date: DateTime) !void {
            return self.schedule(task, date.unix(.milliseconds));
        }

        pub fn scheduleIn(self: *Self, task: T, ms: i64) !void {
            return self.schedule(task, std.Io.Timestamp.now(self.io, .cpu_process).toMilliseconds() + ms);
        }

        pub fn schedule(self: *Self, task: T, at: i64) !void {
            const job: Job(T) = .{
                .at = at,
                .task = task,
            };

            var reschedule = false;
            {
                try self.mutex.lock(self.io);
                defer self.mutex.unlock(self.io);

                if (self.queue.peek()) |*next| {
                    if (at < next.at) {
                        reschedule = true;
                    }
                } else {
                    reschedule = true;
                }
                try self.queue.push(self.allocator, job);
            }

            if (reschedule) {
                // Our new job is scheduled before our previous earlier job
                // (or we had no previous jobs)
                // We need to reset our schedule
                self.cond.signal(self.io);
            }
        }

        // this is running in a separate thread, started by start()
        fn run(self: *Self, ctx: C) void {
            self.mutex.lock(self.io) catch {};

            while (true) {
                const ms_until_next = self.processPending(ctx);

                // mutex is locked when returning for processPending

                if (self.running == false) {
                    self.mutex.unlock(self.io);
                    return;
                }

                if (ms_until_next) |_| {
                    //const ns = @as(u64, @intCast(timeout * std.time.ns_per_ms));
                    self.cond.wait(self.io, &self.mutex) catch |err| {
                        std.debug.assert(err == error.Timeout);
                        // on success or error, cond locks mutex, which is what we want
                    };
                } else {
                    self.cond.wait(self.io, &self.mutex) catch {};
                }
                // if we woke up, it's because a new job was added with a more recent
                // scheduled time. This new job MAY not be ready to run yet, and
                // it's even possible for our cond variable to wake up randomly (as per
                // the docs), but processPending is defensive and will check this for us.
            }
        }

        // we enter this function with mutex locked
        // and we exit this function with the mutex locked
        // importantly, we don't lock the mutex will process the task
        fn processPending(self: *Self, ctx: C) ?i64 {
            while (true) {
                const next = self.queue.peek() orelse {
                    // yes, we must return this function with a locked mutex
                    return null;
                };
                const seconds_until_next = next.at - std.Io.Timestamp.now(self.io, .cpu_process).toMilliseconds();
                if (seconds_until_next > 0) {
                    // this job isn't ready, yes, the mutex should remain locked!
                    return seconds_until_next;
                }

                // delete the peeked job from the queue, because we're going to process it
                const job = self.queue.remove();
                self.mutex.unlock(self.io);
                defer self.mutex.lock(self.io) catch {};
                if (comptime include_scheduler) {
                    job.task.run(ctx, self, next.at);
                } else {
                    job.task.run(ctx, next.at);
                }
            }
        }
    };
}

const t = @import("zul.zig").testing;
test "Scheduler: null context" {
    var s = Scheduler(TestTask, void, t.testIo).init(t.allocator);
    defer s.deinit();

    try s.start({});

    try t.expectError(error.AlreadyRunning, s.start({}));

    // test that past jobs are run
    var counter: usize = 0;
    try s.scheduleIn(.{ .counter = &counter }, -200);
    try s.scheduleAt(.{ .counter = &counter }, try DateTime.now(t.testIo).add(-20, .milliseconds));
    try s.schedule(.{ .counter = &counter }, 4);

    var history = TestTask.History{
        .pos = 0,
        .records = undefined,
    };

    try s.scheduleIn(.{ .recorder = .{ .value = 1, .history = &history } }, 10);
    try s.scheduleAt(.{ .recorder = .{ .value = 2, .history = &history } }, try DateTime.now(t.testIo).add(4, .milliseconds));
    try s.schedule(.{ .recorder = .{ .value = 3, .history = &history } }, std.Io.Timestamp.now(t.testIo,.cpu_process).toMilliseconds());

    // never gets run
    try s.scheduleAt(.{ .recorder = .{ .value = 0, .history = &history } }, try DateTime.now(t.testIo).add(2, .seconds));

    //std.Thread.sleep(std.time.ns_per_ms * 20);
    try std.Io.sleep(t.testIo, std.Io.Duration.fromSeconds(2));
    s.stop();

    try t.expectEqual(3, counter);
    try t.expectEqual(3, history.pos);
    try t.expectEqual(2, history.records[0]);
    try t.expectEqual(3, history.records[1]);
    try t.expectEqual(1, history.records[2]);
}

test "Scheduler: with context" {
    var s = Scheduler(TestCtxTask, *usize, t.testIo).init(t.allocator);
    defer s.deinit();

    var ctx: usize = 3;
    try s.start(&ctx);
    // test that past jobs are run
    try s.scheduleIn(.{ .add = 2 }, 4);
    try s.scheduleIn(.{ .add = 4 }, 8);

    //std.Thread.sleep(std.time.ns_per_ms * 20);
    try std.Io.sleep(t.testIo, std.Io.Duration.fromSeconds(2), .cpu_process);
    s.stop();

    try t.expectEqual(9, ctx);
}

const TestTask = union(enum) {
    counter: *usize,
    recorder: Recorder,

    fn run(self: TestTask, _: void, _: i64) void {
        switch (self) {
            .counter => |c| c.* += 1,
            .recorder => |r| {
                const pos = r.history.pos;
                r.history.records[pos] = r.value;
                r.history.pos = pos + 1;
            },
        }
    }

    const Recorder = struct {
        value: usize,
        history: *History,
    };

    const History = struct {
        pos: usize,
        records: [3]usize,
    };
};

const TestCtxTask = union(enum) {
    add: usize,

    fn run(self: TestCtxTask, sum: *usize, _: i64) void {
        switch (self) {
            .add => |c| sum.* += c,
        }
    }
};
