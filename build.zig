const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spice_dep = b.dependency("spice", .{
        .target = target,
        .optimize = optimize,
    });

    // Core module
    const core_module = b.addModule("core", .{
        .root_source_file = .{ .cwd_relative = "src/framework/core.zig" },
    });

    // Schema module
    const schema_module = b.addModule("schema", .{
        .root_source_file = .{ .cwd_relative = "src/framework/trpc/schema.zig" },
    });

    // Framework module
    const framework_module = b.addModule("framework", .{
        .root_source_file = .{ .cwd_relative = "src/framework/server.zig" },
        .imports = &.{
            .{ .name = "spice", .module = spice_dep.module("spice") },
            .{ .name = "core", .module = core_module },
            .{ .name = "schema", .module = schema_module },
        },
    });

    // Runtime Router module
    const runtime_router_module = b.addModule("runtime_router", .{
        .root_source_file = .{ .cwd_relative = "src/framework/trpc/runtime_router.zig" },
        .imports = &.{
            .{ .name = "schema", .module = schema_module },
            .{ .name = "framework", .module = framework_module },
            .{ .name = "core", .module = core_module },
        },
    });

    // gRPC Router module
    const grpc_router_module = b.addModule("grpc_router", .{
        .root_source_file = .{ .cwd_relative = "src/framework/trpc/grpc_router.zig" },
        .imports = &.{
            .{ .name = "schema", .module = schema_module },
            .{ .name = "runtime_router", .module = runtime_router_module },
            .{ .name = "framework", .module = framework_module },
            .{ .name = "core", .module = core_module },
        },
    });

    // Example server executable
    const example = b.addExecutable(.{
        .name = "example-server",
        .root_source_file = .{ .cwd_relative = "src/framework/example.zig" },
        .target = target,
        .optimize = optimize,
    });
    example.root_module.addImport("framework", framework_module);
    example.root_module.addImport("core", core_module);
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

    // tRPC tests
    const trpc_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/framework/trpc/grpc_test.zig" },
        .target = target,
        .optimize = optimize,
    });
    const log_level = b.option(
        std.log.Level,
        "log_level",
        "The log level to use",
    ) orelse .debug;
    const build_options = b.addOptions();
    build_options.addOption(std.log.Level, "log_level", log_level);
    trpc_tests.root_module.addImport("build_options", build_options.createModule());
    trpc_tests.root_module.addImport("core", core_module);
    trpc_tests.root_module.addImport("schema", schema_module);
    trpc_tests.root_module.addImport("runtime_router", runtime_router_module);
    trpc_tests.root_module.addImport("grpc_router", grpc_router_module);
    trpc_tests.root_module.addImport("framework", framework_module);

    const run_framework_tests = b.addRunArtifact(framework_tests);
    const run_trpc_tests = b.addRunArtifact(trpc_tests);

    const test_framework_step = b.step("test-framework", "Run framework tests");
    test_framework_step.dependOn(&run_framework_tests.step);

    const test_trpc_step = b.step("test-trpc", "Run tRPC tests");
    test_trpc_step.dependOn(&run_trpc_tests.step);

    // Original tests
    const main_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_tests.root_module.addImport("spice", spice_dep.module("spice"));

    const run_main_tests = b.addRunArtifact(main_tests);
    // Integration tests
    const integration_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/framework/tests.zig" },
        .target = target,
        .optimize = optimize,
    });
    integration_tests.root_module.addImport("framework", framework_module);
    integration_tests.root_module.addImport("spice", spice_dep.module("spice"));
    
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const test_integration_step = b.step("test-integration", "Run integration tests");
    test_integration_step.dependOn(&run_integration_tests.step);

    // Main test step that runs all tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_trpc_tests.step);

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
