// in your build.zig, you can specify a custom test runner:
// const tests = b.addTest(.{
//    .root_module = $MODULE_BEING_TESTED,
//    .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
// });

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const BORDER: [80:0]u8 = @splat('=');

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const env = Env.init(allocator, init.minimal.environ);
    defer env.deinit(allocator);

    std.testing.io_instance = .init(allocator, .{});
    defer std.testing.io_instance.deinit();
    const io = std.testing.io_instance.io();

    var slowest = SlowTracker.init(allocator, io, 5);
    defer slowest.deinit();

    var watchdog: Watchdog = .{
        .io = io,
        .start_ts = .now(io, Watchdog.clock),
        .deadline_ns = .init(std.math.maxInt(i64)),
        .shutdown = .init(false),
    };
    const watchdog_thread = std.Thread.spawn(.{}, Watchdog.run, .{&watchdog}) catch |err| blk: {
        std.log.warn("watchdog spawn failed: {}", .{err});
        break :blk null;
    };
    defer if (watchdog_thread) |th| {
        watchdog.shutdown.store(true, .release);
        th.join();
    };

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (builtin.test_functions) |t| {
        if (isSetup(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    for (builtin.test_functions) |t| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming();

        const is_unnamed_test = isUnnamed(t);
        if (env.filter) |f| {
            if (!is_unnamed_test and std.mem.indexOf(u8, t.name, f) == null) {
                continue;
            }
        }

        const friendly_name = blk: {
            const name = t.name;
            var it = std.mem.splitScalar(u8, name, '.');
            while (it.next()) |value| {
                if (std.mem.eql(u8, value, "test")) {
                    const rest = it.rest();
                    break :blk if (rest.len > 0) rest else name;
                }
            }
            break :blk name;
        };

        current_test = friendly_name;
        std.testing.allocator_instance = .init(allocator, .{});
        watchdog.arm(friendly_name);
        const result = t.func();
        watchdog.disarm();
        current_test = null;

        const ns_taken = slowest.endTiming(friendly_name);

        if (std.testing.allocator_instance.deinit() > 0) {
            leak += 1;
            Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        }

        if (result) |_| {
            pass += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
            },
            else => {
                status = .fail;
                fail += 1;
                Printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                if (env.fail_first) {
                    break;
                }
            },
        }

        if (env.verbose) {
            const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
            Printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
        } else {
            Printer.status(status, ".", .{});
        }
    }

    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;
    Printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        Printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        Printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    Printer.fmt("\n", .{});
    try slowest.display();
    Printer.fmt("\n", .{});
    std.process.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
    fn fmt(comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
    }

    fn status(s: Status, comptime format: []const u8, args: anytype) void {
        switch (s) {
            .pass => std.debug.print("\x1b[32m", .{}),
            .fail => std.debug.print("\x1b[31m", .{}),
            .skip => std.debug.print("\x1b[33m", .{}),
            else => {},
        }
        std.debug.print(format ++ "\x1b[0m", args);
    }
};

const Watchdog = struct {
    const timeout_ns: i64 = 20 * std.time.ns_per_s;
    const poll_ms: u32 = 100;
    const clock: std.Io.Clock = .awake;

    io: std.Io,
    start_ts: std.Io.Clock.Timestamp,
    deadline_ns: std.atomic.Value(i64),
    shutdown: std.atomic.Value(bool),
    name: []const u8 = "",

    fn elapsedNs(self: *Watchdog) i64 {
        return @intCast(self.start_ts.untilNow(self.io).raw.toNanoseconds());
    }

    fn arm(self: *Watchdog, test_name: []const u8) void {
        self.name = test_name;
        self.deadline_ns.store(self.elapsedNs() + timeout_ns, .release);
    }

    fn disarm(self: *Watchdog) void {
        self.deadline_ns.store(std.math.maxInt(i64), .release);
    }

    fn run(self: *Watchdog) void {
        while (!self.shutdown.load(.acquire)) {
            std.Io.sleep(self.io, .fromMilliseconds(poll_ms), .real) catch return;
            if (self.elapsedNs() >= self.deadline_ns.load(.acquire)) {
                std.debug.print("\x1b[31m\n{s}\nTIMEOUT (20s): {s}\n{s}\x1b[0m\n", .{ BORDER, self.name, BORDER });
                std.process.exit(124);
            }
        }
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    const clock: std.Io.Clock = .awake;

    max: usize,
    slowest: SlowestQueue,
    allocator: Allocator,
    io: std.Io,
    start_ts: std.Io.Clock.Timestamp,

    fn init(allocator: Allocator, io: std.Io, count: u32) SlowTracker {
        var slowest: SlowestQueue = .empty;
        slowest.ensureTotalCapacity(allocator, count) catch @panic("OOM");
        return .{
            .max = count,
            .allocator = allocator,
            .io = io,
            .start_ts = .now(io, clock),
            .slowest = slowest,
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: *SlowTracker) void {
        self.slowest.deinit(self.allocator);
    }

    fn startTiming(self: *SlowTracker) void {
        self.start_ts = .now(self.io, clock);
    }

    fn endTiming(self: *SlowTracker, test_name: []const u8) u64 {
        const elapsed = self.start_ts.untilNow(self.io);
        const ns: u64 = @intCast(elapsed.raw.toNanoseconds());

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.push(self.allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.popMin().?;
        slowest.push(self.allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        Printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.popMin()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            Printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filter: ?[]const u8,

    fn init(allocator: Allocator, environ: std.process.Environ) Env {
        var map = environ.createMap(std.heap.page_allocator) catch |err| {
            std.log.warn("failed to read environment: {}", .{err});
            return .{ .verbose = true, .fail_first = false, .filter = null };
        };
        defer map.deinit();

        return .{
            .verbose = readBool(map, "TEST_VERBOSE", true),
            .fail_first = readBool(map, "TEST_FAIL_FIRST", false),
            .filter = if (map.get("TEST_FILTER")) |v| allocator.dupe(u8, v) catch null else null,
        };
    }

    fn deinit(self: Env, allocator: Allocator) void {
        if (self.filter) |f| {
            allocator.free(f);
        }
    }

    fn readBool(map: std.process.Environ.Map, key: []const u8, deflt: bool) bool {
        const v = map.get(key) orelse return deflt;
        return std.ascii.eqlIgnoreCase(v, "true");
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}
