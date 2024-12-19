const std = @import("std");

pub const Direction = enum {
    asc,
    desc,

    pub fn toOrder(self: Direction) std.math.Order {
        return switch (self) {
            .asc => .lt,
            .desc => .gt,
        };
    }
};

pub fn strings(values: [][]const u8, direction: Direction) void {
    std.mem.sortUnstable([]const u8, values, direction.toOrder(), struct {
        fn order(d: std.math.Order, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == d;
        }
    }.order);
}

pub fn asciiIgnoreCase(values: [][]const u8, direction: Direction) void {
    std.mem.sortUnstable([]const u8, values, direction.toOrder(), struct {
        fn order(d: std.math.Order, lhs: []const u8, rhs: []const u8) bool {
            return std.ascii.orderIgnoreCase(lhs, rhs) == d;
        }
    }.order);
}

pub fn numbers(comptime T: type, values: []T, direction: Direction) void {
    switch (direction) {
        .asc => std.mem.sortUnstable(T, values, {}, std.sort.asc(T)),
        .desc => std.mem.sortUnstable(T, values, {}, std.sort.desc(T)),
    }
}

const t = @import("zul.zig").testing;
test "sort: string / ascii" {
    var values = [_][]const u8{"ABC", "abc", "Dog", "Cat", "horse", "chicken"};
    strings(&values, .asc);
    try t.expectEqual("ABC", values[0]);
    try t.expectEqual("Cat", values[1]);
    try t.expectEqual("Dog", values[2]);
    try t.expectEqual("abc", values[3]);
    try t.expectEqual("chicken", values[4]);
    try t.expectEqual("horse", values[5]);

    strings(&values, .desc);
    try t.expectEqual("ABC", values[5]);
    try t.expectEqual("Cat", values[4]);
    try t.expectEqual("Dog", values[3]);
    try t.expectEqual("abc", values[2]);
    try t.expectEqual("chicken", values[1]);
    try t.expectEqual("horse", values[0]);

    asciiIgnoreCase(&values, .asc);
    try t.expectEqual("abc", values[0]);
    try t.expectEqual("ABC", values[1]);
    try t.expectEqual("Cat", values[2]);
    try t.expectEqual("chicken", values[3]);
    try t.expectEqual("Dog", values[4]);
    try t.expectEqual("horse", values[5]);

    asciiIgnoreCase(&values, .desc);
    try t.expectEqual("ABC", values[5]);
    try t.expectEqual("abc", values[4]);
    try t.expectEqual("Cat", values[3]);
    try t.expectEqual("chicken", values[2]);
    try t.expectEqual("Dog", values[1]);
    try t.expectEqual("horse", values[0]);
}

test "sort: numbers" {
    var values = [_]i32{10, -20, 33, 0, 2, 6};
    numbers(i32, &values, .asc);
    try t.expectEqual(-20, values[0]);
    try t.expectEqual(0, values[1]);
    try t.expectEqual(2, values[2]);
    try t.expectEqual(6, values[3]);
    try t.expectEqual(10, values[4]);
    try t.expectEqual(33, values[5]);

    numbers(i32, &values, .desc);
    try t.expectEqual(-20, values[5]);
    try t.expectEqual(0, values[4]);
    try t.expectEqual(2, values[3]);
    try t.expectEqual(6, values[2]);
    try t.expectEqual(10, values[1]);
    try t.expectEqual(33, values[0]);
}
