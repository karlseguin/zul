const std = @import("std");
const zul = @import("src/zul.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = zul.http.Client.init(allocator);
    defer client.deinit();

    std.debug.print("Starting HTTPS requests...\n", .{});

    for (0..100) |i| {
        std.time.sleep(1 * std.time.ns_per_s);

        var req = try client.request("https://www.googleapis.com/oauth2/v1/certs");
        defer req.deinit();

        var res = try req.getResponse(.{});
        const body = try res.allocBody(allocator, .{});
        defer body.deinit();

        std.debug.print("Request {}: {} bytes\n", .{i, body.string().len});
    }
}
