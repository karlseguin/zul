const std = @import("std");
const testing = std.testing;
const time = std.time;
const Allocator = std.mem.Allocator;

/// Error types for context operations
pub const ContextError = error{
    DeadlineExceeded,
    Cancelled,
    InvalidDeadline,
};

/// Context provides deadline-based cancellation and timeout functionality
pub const Context = struct {
    const Self = @This();

    allocator: Allocator,
    deadline_ns: ?i128, // Nanoseconds since epoch, null means no deadline
    cancelled: bool,
    cancel_reason: ?[]const u8,
    parent: ?*const Context,
    children: std.ArrayList(*Context),
    mutex: std.Thread.Mutex,

    /// Create a new root context with optional deadline
    pub fn init(allocator: Allocator, deadline_ns: ?i128) Self {
        return Self{
            .allocator = allocator,
            .deadline_ns = deadline_ns,
            .cancelled = false,
            .cancel_reason = null,
            .parent = null,
            .children = std.ArrayList(*Context).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    /// Create a background context (no deadline, never cancelled)
    pub fn background(allocator: Allocator) Self {
        return init(allocator, null);
    }

    /// Create a context with deadline from duration in milliseconds
    pub fn withTimeout(allocator: Allocator, timeout_ms: u64) !Self {
        const now_ns = time.nanoTimestamp();
        const deadline_ns = now_ns + (@as(i128, timeout_ms) * time.ns_per_ms);
        return init(allocator, deadline_ns);
    }

    /// Create a context with absolute deadline
    pub fn withDeadline(allocator: Allocator, deadline_ns: i128) !Self {
        const now_ns = time.nanoTimestamp();
        if (deadline_ns <= now_ns) {
            return ContextError.InvalidDeadline;
        }
        return init(allocator, deadline_ns);
    }

    /// Create a child context from parent with optional new deadline
    pub fn withParent(parent: *const Context, deadline_ns: ?i128) !*Self {
        const child = try parent.allocator.create(Context);
        child.* = Self{
            .allocator = parent.allocator,
            .deadline_ns = if (deadline_ns) |d| blk: {
                if (parent.deadline_ns) |parent_deadline| {
                    break :blk @min(d, parent_deadline);
                } else {
                    break :blk d;
                }
            } else parent.deadline_ns,
            .cancelled = false,
            .cancel_reason = null,
            .parent = parent,
            .children = std.ArrayList(*Context).init(parent.allocator),
            .mutex = std.Thread.Mutex{},
        };

        // Add to parent's children list (this would need proper synchronization in real use)
        return child;
    }

    /// Clean up context resources
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up children
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit();

        if (self.cancel_reason) |reason| {
            self.allocator.free(reason);
        }
    }

    /// Internal const check for cancellation (no mutex, for parent checking)
    fn isCancelledInternal(self: *const Self) bool {
        // Check if explicitly cancelled
        if (self.cancelled) return true;

        // Check if parent is cancelled
        if (self.parent) |parent| {
            if (parent.isCancelledInternal()) return true;
        }

        return false;
    }

    /// Check if context is cancelled
    pub fn isCancelled(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.isCancelledInternal();
    }

    /// Check if deadline has been exceeded
    pub fn isExpired(self: *Self) bool {
        if (self.deadline_ns) |deadline| {
            return time.nanoTimestamp() >= deadline;
        }
        return false;
    }

    /// Check if context is done (cancelled or expired)
    pub fn isDone(self: *Self) bool {
        return self.isCancelled() or self.isExpired();
    }

    /// Get the error reason for why context is done
    pub fn err(self: *Self) ?ContextError {
        if (self.isCancelled()) return ContextError.Cancelled;
        if (self.isExpired()) return ContextError.DeadlineExceeded;
        return null;
    }

    /// Cancel the context with optional reason
    pub fn cancel(self: *Self, reason: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cancelled) return; // Already cancelled

        self.cancelled = true;
        if (reason) |r| {
            self.cancel_reason = try self.allocator.dupe(u8, r);
        }

        // Cancel all children
        for (self.children.items) |child| {
            try child.cancel("parent cancelled");
        }
    }

    /// Get remaining time until deadline in nanoseconds
    pub fn remainingTime(self: *Self) ?i128 {
        if (self.deadline_ns) |deadline| {
            const now = time.nanoTimestamp();
            const remaining = deadline - now;
            return if (remaining > 0) remaining else 0;
        }
        return null;
    }

    /// Sleep with context cancellation check
    pub fn sleep(self: *Self, duration_ns: u64) ContextError!void {
        const start = time.nanoTimestamp();
        const end_time = start + @as(i128, duration_ns);

        while (time.nanoTimestamp() < end_time) {
            if (self.isDone()) {
                return self.err() orelse ContextError.Cancelled;
            }
            time.sleep(time.ns_per_ms); // Sleep 1ms between checks
        }
    }

    /// Wait for context to be done with optional timeout
    pub fn wait(self: *Self, timeout_ns: ?u64) ContextError!void {
        const start = time.nanoTimestamp();
        const timeout_deadline = if (timeout_ns) |t| start + @as(i128, t) else null;

        while (!self.isDone()) {
            if (timeout_deadline) |deadline| {
                if (time.nanoTimestamp() >= deadline) {
                    return ContextError.DeadlineExceeded;
                }
            }
            time.sleep(time.ns_per_ms); // Sleep 1ms between checks
        }

        return self.err() orelse ContextError.Cancelled;
    }
};

test "Context: basic creation and background context" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = Context.background(allocator);
    defer ctx.deinit();

    try testing.expect(!ctx.isCancelled());
    try testing.expect(!ctx.isExpired());
    try testing.expect(!ctx.isDone());
    try testing.expect(ctx.err() == null);
    try testing.expect(ctx.deadline_ns == null);
    try testing.expect(ctx.remainingTime() == null);
}

test "Context: with timeout creation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try Context.withTimeout(allocator, 1000); // 1 second
    defer ctx.deinit();

    try testing.expect(!ctx.isCancelled());
    try testing.expect(!ctx.isExpired());
    try testing.expect(!ctx.isDone());
    try testing.expect(ctx.deadline_ns != null);

    const remaining = ctx.remainingTime();
    try testing.expect(remaining != null);
    try testing.expect(remaining.? > 0);
    try testing.expect(remaining.? <= 1000 * time.ns_per_ms);
}

test "Context: with deadline creation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const future_deadline = time.nanoTimestamp() + (5000 * time.ns_per_ms); // 5 seconds from now
    var ctx = try Context.withDeadline(allocator, future_deadline);
    defer ctx.deinit();

    try testing.expect(!ctx.isCancelled());
    try testing.expect(!ctx.isExpired());
    try testing.expect(!ctx.isDone());
    try testing.expect(ctx.deadline_ns.? == future_deadline);
}

test "Context: invalid deadline" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const past_deadline = time.nanoTimestamp() - (1000 * time.ns_per_ms); // 1 second ago
    const result = Context.withDeadline(allocator, past_deadline);
    try testing.expectError(ContextError.InvalidDeadline, result);
}

test "Context: manual cancellation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = Context.background(allocator);
    defer ctx.deinit();

    try testing.expect(!ctx.isDone());

    try ctx.cancel("test cancellation");

    try testing.expect(ctx.isCancelled());
    try testing.expect(ctx.isDone());
    try testing.expectEqual(ContextError.Cancelled, ctx.err().?);
}

test "Context: deadline expiration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create context with very short timeout
    var ctx = try Context.withTimeout(allocator, 1); // 1ms
    defer ctx.deinit();

    // Wait for expiration
    time.sleep(5 * time.ns_per_ms); // Sleep 5ms

    try testing.expect(ctx.isExpired());
    try testing.expect(ctx.isDone());
    try testing.expectEqual(ContextError.DeadlineExceeded, ctx.err().?);
}

test "Context: parent-child relationship" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parent = Context.background(allocator);
    defer parent.deinit();

    const future_deadline = time.nanoTimestamp() + (1000 * time.ns_per_ms);
    var child = try Context.withParent(&parent, future_deadline);
    defer {
        child.deinit();
        allocator.destroy(child);
    }

    try testing.expect(!child.isDone());
    try testing.expect(child.deadline_ns != null);

    // Cancel parent should affect child
    try parent.cancel("parent cancelled");
    try testing.expect(child.isCancelled());
    try testing.expect(child.isDone());
}

test "Context: child inherits parent deadline" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parent_deadline = time.nanoTimestamp() + (1000 * time.ns_per_ms);
    var parent = try Context.withDeadline(allocator, parent_deadline);
    defer parent.deinit();

    const child_deadline = time.nanoTimestamp() + (2000 * time.ns_per_ms); // Later than parent
    var child = try Context.withParent(&parent, child_deadline);
    defer {
        child.deinit();
        allocator.destroy(child);
    }

    // Child should inherit parent's earlier deadline
    try testing.expectEqual(parent_deadline, child.deadline_ns.?);
}

test "Context: sleep with cancellation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = Context.background(allocator);
    defer ctx.deinit();

    // Cancel context in separate thread after delay
    const thread = try std.Thread.spawn(.{}, struct {
        fn cancelAfterDelay(context: *Context) void {
            time.sleep(10 * time.ns_per_ms); // 10ms delay
            context.cancel("async cancel") catch {};
        }
    }.cancelAfterDelay, .{&ctx});
    defer thread.join();

    const start = time.nanoTimestamp();
    const result = ctx.sleep(100 * time.ns_per_ms); // Try to sleep 100ms
    const elapsed = time.nanoTimestamp() - start;

    try testing.expectError(ContextError.Cancelled, result);
    // Should have been cancelled before full sleep duration
    try testing.expect(elapsed < 50 * time.ns_per_ms);
}

test "Context: sleep with deadline" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try Context.withTimeout(allocator, 10); // 10ms timeout
    defer ctx.deinit();

    const start = time.nanoTimestamp();
    const result = ctx.sleep(100 * time.ns_per_ms); // Try to sleep 100ms
    const elapsed = time.nanoTimestamp() - start;

    try testing.expectError(ContextError.DeadlineExceeded, result);
    // Should have been cancelled by deadline
    try testing.expect(elapsed >= 10 * time.ns_per_ms);
    try testing.expect(elapsed < 50 * time.ns_per_ms);
}

test "Context: remaining time calculation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try Context.withTimeout(allocator, 100); // 100ms
    defer ctx.deinit();

    const remaining1 = ctx.remainingTime();
    try testing.expect(remaining1 != null);
    try testing.expect(remaining1.? > 0);

    time.sleep(50 * time.ns_per_ms); // Sleep 50ms

    const remaining2 = ctx.remainingTime();
    try testing.expect(remaining2 != null);
    try testing.expect(remaining2.? < remaining1.?);
}

test "Context: wait for cancellation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = Context.background(allocator);
    defer ctx.deinit();

    // Cancel after delay
    const thread = try std.Thread.spawn(.{}, struct {
        fn cancelAfterDelay(context: *Context) void {
            time.sleep(20 * time.ns_per_ms);
            context.cancel("test") catch {};
        }
    }.cancelAfterDelay, .{&ctx});
    defer thread.join();

    const result = ctx.wait(100 * time.ns_per_ms); // Wait up to 100ms
    try testing.expectError(ContextError.Cancelled, result);
}

test "Context: wait timeout" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = Context.background(allocator);
    defer ctx.deinit();

    const start = time.nanoTimestamp();
    const result = ctx.wait(10 * time.ns_per_ms); // Wait 10ms max
    const elapsed = time.nanoTimestamp() - start;

    try testing.expectError(ContextError.DeadlineExceeded, result);
    try testing.expect(elapsed >= 10 * time.ns_per_ms);
}

test "Context: nested cancellation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parent = Context.background(allocator);
    defer parent.deinit();

    var child = try Context.withParent(&parent, null);
    defer {
        child.deinit();
        allocator.destroy(child);
    }

    try testing.expect(!child.isCancelled());
    try testing.expect(!child.isDone());

    // Cancel parent
    try parent.cancel("parent cancelled");

    try testing.expect(child.isCancelled());
    try testing.expect(child.isDone());
}
