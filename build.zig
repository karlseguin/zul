const std = @import("std");

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});
		// Expose this as a module that others can import
	_ = b.addModule("zul", .{
		.source_file = .{ .path = "src/zul.zig" },
	});

	{
		// test step
		const lib_test = b.addTest(.{
			.root_source_file = .{ .path = "src/zul.zig" },
			.target = target,
			.optimize = optimize,
			.test_runner = "test_runner.zig",
		});

		const run_test = b.addRunArtifact(lib_test);
		run_test.has_side_effects = true;

		const test_step = b.step("test", "Run unit tests");
		test_step.dependOn(&run_test.step);
	}
}
