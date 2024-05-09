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

pub fn Scheduler(comptime T: type, comptime C: type) type {
	return struct {
		ctx: C,
		queue: Q,
		running: bool,
		mutex: Thread.Mutex,
		cond: Thread.Condition,
		thread: ?Thread,

		const Q = std.PriorityQueue(Job(T), void, compare);

		fn compare(_: void, a: Job(T), b: Job(T)) std.math.Order {
			return std.math.order(a.at, b.at);
		}

		const Self = @This();

		pub fn init(allocator: Allocator, ctx: C) Self {
			return .{
				.ctx = ctx,
				.cond = .{},
				.mutex = .{},
				.thread = null,
				.running = false,
				.queue = Q.init(allocator, {}),
			};
		}

		pub fn deinit(self: *Self) void {
			self.stop();
			self.queue.deinit();
		}

		pub fn start(self: *Self) !void {
			{
				self.mutex.lock();
				defer self.mutex.unlock();
				if (self.running == true) {
					return error.AlreadyRunning;
				}
				self.running = true;
			}
			self.thread = try Thread.spawn(.{}, Self.run, .{self});
		}

		pub fn stop(self: *Self) void {
			{
				self.mutex.lock();
				defer self.mutex.unlock();
				if (self.running == false) {
					return;
				}
				self.running = false;
			}

			self.cond.signal();
			self.thread.?.join();
		}

		pub fn scheduleAt(self: *Self, task: T, date: DateTime) !void {
			return self.schedule(task, date.unix(.milliseconds));
		}

		pub fn scheduleIn(self: *Self, task: T, ms: i64) !void {
			return self.schedule(task, std.time.milliTimestamp() + ms);
		}

		pub fn schedule(self: *Self, task: T, at: i64) !void {
			const job: Job(T) = .{
				.at = at,
				.task = task,
			};

			var reschedule = false;
			{
				self.mutex.lock();
				defer self.mutex.unlock();

				if (self.queue.peek()) |*next| {
					if (at < next.at) {
						reschedule = true;
					}
				} else {
					reschedule = true;
				}
				try self.queue.add(job);
			}

			if (reschedule) {
				// Our new job is scheduled before our previous earlier job
				// (or we had no previous jobs)
				// We need to reset our schedule
				self.cond.signal();
			}
		}

		// this is running in a separate thread, started by start()
		fn run(self: *Self) void {
			self.mutex.lock();

			while (true) {
				const ms_until_next = self.processPending();

				// mutex is locked when returning for processPending

				if (self.running == false) {
					self.mutex.unlock();
					return;
				}

				if (ms_until_next) |timeout| {
					const ns = @as(u64, @intCast(timeout * std.time.ns_per_ms));
					self.cond.timedWait(&self.mutex, ns) catch |err| {
						std.debug.assert(err == error.Timeout);
						// on success or error, cond locks mutex, which is what we want
					};
				} else {
					self.cond.wait(&self.mutex);
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
		fn processPending(self: *Self) ?i64 {
			const ctx = self.ctx;

			while (true) {
				const next = self.queue.peek() orelse {
					// yes, we must return this function with a locked mutex
					return null;
				};
				const seconds_until_next = next.at - std.time.milliTimestamp();
				if (seconds_until_next > 0) {
					// this job isn't ready, yes, the mutex should remain locked!
					return seconds_until_next;
				}

				// delete the peeked job from the queue, because we're going to process it
				const job = self.queue.remove();
				self.mutex.unlock();
				defer self.mutex.lock();
				job.task.run(ctx, next.at);
			}
		}
	};
}

const t = @import("zul.zig").testing;
test "Scheduler: null context" {
	var s = Scheduler(TestTask, void).init(t.allocator, {});
	defer s.deinit();

	try s.start();

	try t.expectError(error.AlreadyRunning, s.start());

	// test that past jobs are run
	var counter: usize = 0;
	try s.scheduleIn(.{.counter = &counter}, -200);
	try s.scheduleAt(.{.counter = &counter}, try DateTime.now().add(-20, .milliseconds));
	try s.schedule(.{.counter = &counter}, 4);

	var history = TestTask.History{
		.pos = 0,
		.records = undefined,
	};

	try s.scheduleIn(.{.recorder = .{.value = 1, .history = &history}}, 10);
	try s.scheduleAt(.{.recorder = .{.value = 2, .history = &history}}, try DateTime.now().add(4, .milliseconds));
	try s.schedule(.{.recorder = .{.value = 3, .history = &history}}, std.time.milliTimestamp() + 8);

	// never gets run
	try s.scheduleAt(.{.recorder = .{.value = 0, .history = &history}}, try DateTime.now().add(2, .seconds));

	std.time.sleep(std.time.ns_per_ms * 20);
	s.stop();

	try t.expectEqual(3, counter);
	try t.expectEqual(3, history.pos);
	try t.expectEqual(2, history.records[0]);
	try t.expectEqual(3, history.records[1]);
	try t.expectEqual(1, history.records[2]);
}

test "Scheduler: with context" {
	var ctx: usize = 3;
	var s = Scheduler(TestCtxTask, *usize).init(t.allocator, &ctx);
	defer s.deinit();

	try s.start();
	// test that past jobs are run
	try s.scheduleIn(.{.add = 2}, 4);
	try s.scheduleIn(.{.add = 4}, 8);

	std.time.sleep(std.time.ns_per_ms * 20);
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
