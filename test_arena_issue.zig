const std = @import("std");
const zul = @import("src/zul.zig");

// THIS IS THE PROBLEM - demonstrating incorrect ArenaAllocator usage
pub fn problematic() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var client = zul.http.Client.init(allocator);
    defer client.deinit();

    std.debug.print("=== PROBLEMATIC: Using ArenaAllocator ===\n", .{});

    for (0..10) |i| {
        var req = try client.allocRequest(allocator, "https://www.googleapis.com/oauth2/v1/certs");
        defer req.deinit();  // This doesn't actually free with ArenaAllocator!

        var res = try req.getResponse(.{});
        const body = try res.allocBody(allocator, .{});
        defer body.deinit();  // This doesn't actually free with ArenaAllocator!

        std.debug.print("Request {}: {} bytes (arena never frees!)\n", .{ i, body.len() });
    }
    // Arena only frees everything here at the end!
}

// SOLUTION 1: Use GPA instead of ArenaAllocator
pub fn solution1() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = zul.http.Client.init(allocator);
    defer client.deinit();

    std.debug.print("\n=== SOLUTION 1: Using GPA ===\n", .{});

    for (0..10) |i| {
        var req = try client.request("https://www.googleapis.com/oauth2/v1/certs");
        defer req.deinit();  // Actually frees memory!

        var res = try req.getResponse(.{});
        const body = try res.allocBody(allocator, .{});
        defer body.deinit();  // Actually frees memory!

        std.debug.print("Request {}: {} bytes (memory freed after each request)\n", .{ i, body.len() });
    }
}

// SOLUTION 2: Create fresh arena per request
pub fn solution2() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    var client = zul.http.Client.init(gpa_allocator);
    defer client.deinit();

    std.debug.print("\n=== SOLUTION 2: Fresh Arena Per Request ===\n", .{});

    for (0..10) |i| {
        var arena = std.heap.ArenaAllocator.init(gpa_allocator);
        defer arena.deinit();  // Frees all request allocations
        const allocator = arena.allocator();

        var req = try client.allocRequest(allocator, "https://www.googleapis.com/oauth2/v1/certs");
        defer req.deinit();

        var res = try req.getResponse(.{});
        const body = try res.allocBody(allocator, .{});
        defer body.deinit();

        std.debug.print("Request {}: {} bytes (arena freed after each request)\n", .{ i, body.len() });
    }
}

pub fn main() !void {
    try problematic();
    try solution1();
    try solution2();
    std.debug.print("\nThe issue is ArenaAllocator usage, not zul.http!\n", .{});
}
