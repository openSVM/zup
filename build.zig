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
        .imports = &.{
            .{ .name = "core", .module = core_module },
        },
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
            .{ .name = "spice", .module = spice_dep.module("spice") },
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
            .{ .name = "spice", .module = spice_dep.module("spice") },
        },
    });

    // Server executable
    const server = b.addExecutable(.{
        .name = "server",
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Add module dependencies to server
    server.root_module.addImport("framework", framework_module);
    server.root_module.addImport("core", core_module);
    server.root_module.addImport("schema", schema_module);
    server.root_module.addImport("runtime_router", runtime_router_module);
    server.root_module.addImport("grpc_router", grpc_router_module);
    server.root_module.addImport("spice", spice_dep.module("spice"));

    b.installArtifact(server);

    // Client executable
    const client = b.addExecutable(.{
        .name = "client",
        .root_source_file = .{ .cwd_relative = "src/client.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(client);

    // Run steps
    const run_server_cmd = b.addRunArtifact(server);
    const run_server_step = b.step("run-server", "Run the gRPC server");
    run_server_step.dependOn(&run_server_cmd.step);

    const run_client_cmd = b.addRunArtifact(client);
    const run_client_step = b.step("run-client", "Run the gRPC client");
    run_client_step.dependOn(&run_client_cmd.step);

    // gRPC Example executable
    const grpc_example = b.addExecutable(.{
        .name = "grpc-example",
        .root_source_file = .{ .cwd_relative = "src/framework/trpc/grpc_example.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Add module dependencies to gRPC example
    grpc_example.root_module.addImport("framework", framework_module);
    grpc_example.root_module.addImport("core", core_module);
    grpc_example.root_module.addImport("schema", schema_module);
    grpc_example.root_module.addImport("runtime_router", runtime_router_module);
    grpc_example.root_module.addImport("grpc_router", grpc_router_module);
    grpc_example.root_module.addImport("spice", spice_dep.module("spice"));

    b.installArtifact(grpc_example);

    const run_example_cmd = b.addRunArtifact(grpc_example);
    const run_example_step = b.step("run-example", "Run the gRPC example server");
    run_example_step.dependOn(&run_example_cmd.step);

    // Add test client
    const test_client = b.addExecutable(.{
        .name = "grpc-test-client",
        .root_source_file = .{ .cwd_relative = "src/framework/trpc/grpc_test_client.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_test_client = b.addRunArtifact(test_client);
    const run_test_client_step = b.step("run-test-client", "Run the test client");
    run_test_client_step.dependOn(&run_test_client.step);

    // Test step
    const test_step = b.step("test", "Run all tests");

    // Server tests
    const server_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/framework/server_test.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Add module dependencies to server tests
    server_tests.root_module.addImport("framework", framework_module);
    server_tests.root_module.addImport("core", core_module);
    server_tests.root_module.addImport("schema", schema_module);
    server_tests.root_module.addImport("runtime_router", runtime_router_module);
    server_tests.root_module.addImport("grpc_router", grpc_router_module);
    server_tests.root_module.addImport("spice", spice_dep.module("spice"));

    const run_server_tests = b.addRunArtifact(server_tests);
    test_step.dependOn(&run_server_tests.step);

    // TRPC tests
    const trpc_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/framework/trpc_test.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Add module dependencies to TRPC tests
    trpc_tests.root_module.addImport("framework", framework_module);
    trpc_tests.root_module.addImport("core", core_module);
    trpc_tests.root_module.addImport("schema", schema_module);
    trpc_tests.root_module.addImport("runtime_router", runtime_router_module);
    trpc_tests.root_module.addImport("grpc_router", grpc_router_module);
    trpc_tests.root_module.addImport("spice", spice_dep.module("spice"));

    const run_trpc_tests = b.addRunArtifact(trpc_tests);
    test_step.dependOn(&run_trpc_tests.step);

    // Run step
    const run_step = b.step("run", "Run the server executable");
    run_step.dependOn(&run_server_cmd.step);
}
