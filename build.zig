const std = @import("std");

pub fn build(b: *std.Build) void {
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

    // Runtime Router module
    const runtime_router_module = b.addModule("runtime_router", .{
        .root_source_file = .{ .cwd_relative = "src/framework/trpc/runtime_router.zig" },
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "schema", .module = schema_module },
        },
    });

    // gRPC Router module
    const grpc_router_module = b.addModule("grpc_router", .{
        .root_source_file = .{ .cwd_relative = "src/framework/trpc/grpc_router.zig" },
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "schema", .module = schema_module },
            .{ .name = "runtime_router", .module = runtime_router_module },
        },
    });

    // Framework module
    const framework_module = b.addModule("framework", .{
        .root_source_file = .{ .cwd_relative = "src/framework/server.zig" },
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "schema", .module = schema_module },
            .{ .name = "grpc_router", .module = grpc_router_module },
        },
    });

    // API module
    const zup_api = b.addStaticLibrary(.{
        .name = "zup-api",
        .root_source_file = .{ .cwd_relative = "src/root.zig" },
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });

    zup_api.root_module.addImport("core", core_module);
    zup_api.root_module.addImport("framework", framework_module);
    zup_api.root_module.addImport("schema", schema_module);
    zup_api.root_module.addImport("runtime_router", runtime_router_module);
    zup_api.root_module.addImport("grpc_router", grpc_router_module);

    b.installArtifact(zup_api);
}
