const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    var protocol: ?[]const u8 = null;
    var project_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--protocol")) {
            protocol = args.next() orelse {
                std.debug.print("Error: Missing protocol value\n", .{});
                return error.MissingProtocol;
            };
        } else {
            project_name = arg;
        }
    }

    std.debug.print("Protocol: {s}\n", .{protocol.?});
    std.debug.print("Project Name: {s}\n", .{project_name.?});

    if (protocol == null) {
        std.debug.print("Error: Missing --protocol flag\n", .{});
        return error.MissingProtocol;
    }

    if (project_name == null) {
        std.debug.print("Error: Missing project name\n", .{});
        return error.MissingProjectName;
    }

    if (!std.mem.eql(u8, protocol.?, "http+grpc")) {
        std.debug.print("Error: Unsupported protocol: {s}\n", .{protocol.?});
        return error.UnsupportedProtocol;
    }

    // Check if project directory already exists
    const project_path = try std.fs.path.join(allocator, &.{ project_name.? });
    defer allocator.free(project_path);

    if (try std.fs.exists(project_path)) {
        std.debug.print("Error: Project directory {s} already exists\n", .{project_name.?});
        return error.PathAlreadyExists;
    }

    // Create project directory
    try std.fs.cwd().makeDir(project_name.?);

    // Create src directory
    const src_path = try std.fs.path.join(allocator, &.{ project_name.?, "src" });
    defer allocator.free(src_path);
    try std.fs.cwd().makeDir(src_path);

    // Create main.zig
    const main_path = try std.fs.path.join(allocator, &.{ src_path, "main.zig" });
    defer allocator.free(main_path);
    const main_file = try std.fs.cwd().createFile(main_path, .{});
    defer main_file.close();
    try main_file.writeAll(
        \\const std = @import("std");
        \\const framework = @import("framework");
        \\const zup_api = @import("zup-api");
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\    const allocator = gpa.allocator();
        \\
        \\    const config = framework.ServerConfig{
        \\        .port = 8083,
        \\        .host = "127.0.0.1",
        \\    };
        \\
        \\    var server = try framework.Server.init(allocator, config);
        \\    defer server.deinit();
        \\
        \\    try server.start();
        \\}
        \\
    );

    // Create build.zig
    const build_path = try std.fs.path.join(allocator, &.{ project_name.?, "build.zig" });
    defer allocator.free(build_path);
    const build_file = try std.fs.cwd().createFile(build_path, .{});
    defer build_file.close();
    try build_file.writeAll(
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    const core_mod = b.createModule(.{
        \\        .root_source_file = .{ .cwd_relative = "../src/framework/core.zig" },
        \\    });
        \\
        \\    const framework_mod = b.createModule(.{
        \\        .root_source_file = .{ .cwd_relative = "../src/framework/server.zig" },
        \\        .imports = &.{
        \\            .{ .name = "core", .module = core_mod },
        \\        },
        \\    });
        \\
        \\    const zup_api_mod = b.createModule(.{
        \\        .root_source_file = .{ .cwd_relative = "../zup-api/src/lib.zig" },
        \\    });
        \\
        \\    const exe = b.addExecutable(.{
        \\        .name = "server",
        \\        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
        \\    exe.root_module.addImport("framework", framework_mod);
        \\    exe.root_module.addImport("zup-api", zup_api_mod);
        \\    b.installArtifact(exe);
        \\
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    run_cmd.step.dependOn(b.getInstallStep());
        \\
        \\    const run_step = b.step("run", "Run the app");
        \\    run_step.dependOn(&run_cmd.step);
        \\}
        \\
    );

    // Create build.zig.zon
    const zon_path = try std.fs.path.join(allocator, &.{ project_name.?, "build.zig.zon" });
    defer allocator.free(zon_path);
    const zon_file = try std.fs.cwd().createFile(zon_path, .{});
    defer zon_file.close();
    try zon_file.writeAll(
        \\.{
        \\    .name = "server",
        \\    .version = "0.1.0",
        \\    .paths = .{
        \\        "src",
        \\        "build.zig",
        \\        "build.zig.zon",
        \\    },
        \\}
        \\
    );

    std.debug.print("Created {s} project with http+grpc protocol\n", .{project_name.?});
}
