const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spice_dep = b.dependency("spice", .{
        .target = target,
        .optimize = optimize,
    });

    // Framework module
    const framework_module = b.addModule("framework", .{
        .root_source_file = .{ .cwd_relative = "src/framework/server.zig" },
    });
    framework_module.addImport("spice", spice_dep.module("spice"));

    // Example server executable
    const example = b.addExecutable(.{
        .name = "example-server",
        .root_source_file = .{ .cwd_relative = "src/framework/example.zig" },
        .target = target,
        .optimize = optimize,
    });
    example.root_module.addImport("framework", framework_module);
    b.installArtifact(example);

    // Example server run step
    const example_step = b.step("example", "Run the example server");
    const run_example = b.addRunArtifact(example);
    example_step.dependOn(&run_example.step);

    // Original server executable
    const server = b.addExecutable(.{
        .name = "server",
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    server.root_module.addImport("spice", spice_dep.module("spice"));
    b.installArtifact(server);

    // Server step
    const server_step = b.step("server", "Build and run the server");
    const run_server = b.addRunArtifact(server);
    server_step.dependOn(&run_server.step);

    // Run step (alias for example)
    const run_step = b.step("run", "Run the example server");
    run_step.dependOn(example_step);

    // Framework tests
    const framework_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/framework/example.zig" },
        .target = target,
        .optimize = optimize,
    });
    framework_tests.root_module.addImport("framework", framework_module);

    const run_framework_tests = b.addRunArtifact(framework_tests);
    const test_framework_step = b.step("test-framework", "Run framework tests");
    test_framework_step.dependOn(&run_framework_tests.step);

    // Original tests
    const main_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_tests.root_module.addImport("spice", spice_dep.module("spice"));

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_framework_tests.step);
    test_step.dependOn(&run_main_tests.step);

    // Benchmark CLI executable
    const benchmark_cli = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = .{ .cwd_relative = "src/benchmark_cli.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(benchmark_cli);

    // Benchmark step
    const bench_step = b.step("bench", "Run HTTP benchmarks");
    const run_bench = b.addRunArtifact(benchmark_cli);
    bench_step.dependOn(&run_bench.step);
}
