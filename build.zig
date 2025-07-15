const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Expose this as a module that others can import

    const zul_module = b.addModule("zul", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/zul.zig"),
    });

    {
        // test step
        const lib_test = b.addTest(.{
            .root_module = zul_module,
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });

        const run_test = b.addRunArtifact(lib_test);
        run_test.has_side_effects = true;

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_test.step);
    }
}
