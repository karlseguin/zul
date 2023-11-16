const std = @import("std");

const Timer = std.time.Timer;
const Allocator = std.mem.Allocator;

pub const Opts = struct {
	samples: u32 = 10_000,
	runtime: usize = 3 * std.time.ms_per_s,
};

pub fn Result(comptime SAMPLE_COUNT: usize) type {
	return struct {
		total: u64,
		iterations: u64,
		requested_bytes: usize,
		// sorted, use samples()
		_samples: [SAMPLE_COUNT]u64,

		const Self = @This();

		pub fn print(self: *const Self, name: []const u8) void {
			std.debug.print("{s}\n", .{name});
			std.debug.print("  {d} iterations\t{d:.2}ns per iterations\n", .{self.iterations, self.mean()});
			std.debug.print("  {d:.2} bytes per iteration\n", .{self.requested_bytes / self.iterations});
			std.debug.print("  worst: {d}ns\tmedian: {d:.2}ns\tstddev: {d:.2}ns\n\n", .{self.worst(), self.median(), self.stdDev()});
		}

		pub fn samples(self: *const Self) []const u64 {
			return self._samples[0..@min(self.iterations, SAMPLE_COUNT)];
		}

		pub fn worst(self: *const Self) u64 {
			const s = self.samples();
			return s[s.len - 1];
		}

		pub fn mean(self: *const Self) f64 {
			const s = self.samples();

			var total: u64 = 0;
			for (s) |value| {
				total += value;
			}
			return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(s.len));
		}

		pub fn median(self: *const Self) u64 {
			const s = self.samples();
			return s[s.len / 2];
		}

		pub fn stdDev(self: *const Self) f64 {
			const m = self.mean();
			const s = self.samples();

			var total: f64 = 0.0;
			for (s) |value| {
				const t = @as(f64, @floatFromInt(value)) - m;
				total += t * t;
			}
			const variance = total / @as(f64, @floatFromInt(s.len - 1));
			return std.math.sqrt(variance);
		}
	};
}

pub fn run(func: TypeOfBenchmark(void), comptime opts: Opts) !Result(opts.samples) {
	return runC({}, func, opts);
}

pub fn runC(context: anytype, func: TypeOfBenchmark(@TypeOf(context)), comptime opts: Opts) !Result(opts.samples) {
	var gpa = std.heap.GeneralPurposeAllocator(.{.enable_memory_limit = true}){};
	const allocator = gpa.allocator();

	const sample_count = opts.samples;
	const run_time = opts.runtime * std.time.ns_per_ms;

	var total: u64 = 0;
	var iterations: usize = 0;
	var timer = try Timer.start();
	var samples = std.mem.zeroes([sample_count]u64);

	while (true) {
		iterations += 1;
		timer.reset();

		if (@TypeOf(context) == void) {
			try func(allocator, &timer);
		} else {
			try func(context, allocator, &timer);
		}
		const elapsed = timer.lap();

		total += elapsed;
		samples[@mod(iterations, sample_count)] = elapsed;
		if (total > run_time) break;
	}

	std.sort.heap(u64, samples[0..@min(sample_count, iterations)], {}, resultLessThan);

	return .{
		.total = total,
		._samples = samples,
		.iterations = iterations,
		.requested_bytes = gpa.total_requested_bytes,
	};
}

fn TypeOfBenchmark(comptime C: type) type {
	return switch (C) {
		void => *const fn(Allocator, *Timer) anyerror!void,
		else => *const fn(C, Allocator, *Timer) anyerror!void,
	};
}

fn resultLessThan(context: void, lhs: u64, rhs: u64) bool {
	_ = context;
	return lhs < rhs;
}
