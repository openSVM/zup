const std = @import("std");
const fs = std.fs;
const print = std.debug.print;

const usage =
    \\Usage: zup [options] <project-name>
    \\
    \\Options:
    \\  --protocol <http|grpc|ws>    Protocol to use (default: grpc)
    \\  --help                       Show this help message
    \\
    \\Example:
    \\  zup --protocol grpc my-api
    \\
;

const Config = struct {
    project_name: []const u8,
    protocol: []const u8,

    pub fn init() Config {
        return .{
            .project_name = "",
            .protocol = "grpc",
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (!std.mem.eql(u8, self.protocol, "grpc")) {
            allocator.free(self.protocol);
        }
        if (self.project_name.len > 0) {
            allocator.free(self.project_name);
        }
    }
};

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip executable name
    _ = args.skip();

    var config = Config.init();
    errdefer config.deinit(allocator);

    var next_is_protocol = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            print("{s}\n", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--protocol")) {
            next_is_protocol = true;
        } else if (next_is_protocol) {
            if (!std.mem.eql(u8, arg, "http") and
                !std.mem.eql(u8, arg, "grpc") and
                !std.mem.eql(u8, arg, "ws"))
            {
                print("Error: protocol must be http, grpc, or ws\n", .{});
                std.process.exit(1);
            }
            if (!std.mem.eql(u8, arg, "grpc")) {
                config.protocol = try allocator.dupe(u8, arg);
            }
            next_is_protocol = false;
        } else {
            config.project_name = try allocator.dupe(u8, arg);
        }
    }

    if (config.project_name.len == 0) {
        print("Error: project name is required\n\n{s}", .{usage});
        std.process.exit(1);
    }

    return config;
}

fn createDirectory(path: []const u8) !void {
    const cwd = std.fs.cwd();
    cwd.makeDir(path) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    const cwd = std.fs.cwd();
    const file = try cwd.createFile(path, .{});
    defer file.close();
    try file.writeAll(contents);
}

fn copyFile(allocator: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const cwd = std.fs.cwd();
    const source_file = try cwd.openFile(from, .{});
    defer source_file.close();

    const content = try source_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    try writeFile(to, content);
}

const root_template =
    \\const zup = @import("zup");
    \\
    \\pub const core = zup.core;
    \\pub const framework = zup.framework;
    \\pub const schema = zup.schema;
    \\pub const runtime_router = zup.runtime_router;
    \\pub const grpc_router = zup.grpc_router;
;

const grpc_main_template =
    \\const std = @import("std");
    \\const zup = @import("zup");
    \\
    \\pub fn main() !void {
    \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    \\    const allocator = gpa.allocator();
    \\    defer _ = gpa.deinit();
    \\
    \\    // Initialize server
    \\    const config = zup.framework.ServerConfig{
    \\        .port = 8080,
    \\        .host = "127.0.0.1",
    \\    };
    \\    var server = try zup.framework.Server.init(allocator, config);
    \\    defer server.deinit();
    \\
    \\    // Initialize gRPC router
    \\    var router = try zup.grpc_router.GrpcRouter.init(allocator);
    \\    defer router.deinit();
    \\
    \\    // Register procedures
    \\    try router.procedure("hello", handleHello, null, null);
    \\
    \\    // Start gRPC server
    \\    try server.start();
    \\    std.debug.print("gRPC server running on http://localhost:8080\n", .{});
    \\
    \\    // Wait for Ctrl+C
    \\    while (true) {
    \\        std.time.sleep(1 * std.time.ns_per_s);
    \\    }
    \\}
    \\
    \\fn handleHello(ctx: *zup.framework.Context, input: ?std.json.Value) !std.json.Value {
    \\    const name = if (input) |value| blk: {
    \\        if (value.object.get("name")) |name_value| {
    \\            break :blk name_value.string;
    \\        }
    \\        break :blk "World";
    \\    } else "World";
    \\
    \\    var map = std.json.ObjectMap.init(ctx.allocator);
    \\    try map.put("message", std.json.Value{ .string = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{name}) });
    \\    return std.json.Value{ .object = map };
    \\}
;

const build_template =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const zup_dep = b.dependency("zup", .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    // Main executable
    \\    const exe = b.addExecutable(.{
    \\        .name = "server",
    \\        .root_source_file = .{ .cwd_relative = "src/main.zig" },
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    // Add module dependencies
    \\    exe.root_module.addImport("zup", zup_dep.module("zup"));
    \\
    \\    b.installArtifact(exe);
    \\
    \\    // Run step
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    const run_step = b.step("run", "Run the server");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
;

const build_zon_template =
    \\.{{
    \\    .name = "{s}",
    \\    .version = "0.1.0",
    \\    .paths = .{{
    \\        "src",
    \\        "build.zig",
    \\        "build.zig.zon",
    \\    }},
    \\    .dependencies = .{{
    \\        .zup = .{{
    \\            .url = "https://github.com/openSVM/zup/archive/main.tar.gz",
    \\            .hash = "1220bc3ba76ebbba7f90b363409144a85b24ee584cde5139646a5c2038c09f4a3bfb",
    \\        }},
    \\    }},
    \\}}
;

fn generateGrpcBoilerplate(allocator: std.mem.Allocator, project_name: []const u8) !void {
    print("Generating gRPC boilerplate for project '{s}'...\n", .{project_name});

    // Create project directory
    try createDirectory(project_name);


    // Create project directory
    try createDirectory(project_name);

    // Create src directory
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_name});
    defer allocator.free(src_path);
    try createDirectory(src_path);

    // Create root.zig
    const root_path = try std.fmt.allocPrint(allocator, "{s}/src/root.zig", .{project_name});
    defer allocator.free(root_path);
    try writeFile(root_path, root_template);

    // Create main.zig
    const main_path = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{project_name});
    defer allocator.free(main_path);
    try writeFile(main_path, grpc_main_template);

    // Create build.zig
    const build_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{project_name});
    defer allocator.free(build_path);
    try writeFile(build_path, build_template);

    // Create build.zig.zon
    const build_zon_path = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{project_name});
    defer allocator.free(build_zon_path);
    const build_zon_content = try std.fmt.allocPrint(allocator, build_zon_template, .{project_name});
    defer allocator.free(build_zon_content);
    try writeFile(build_zon_path, build_zon_content);

    print("\nProject created successfully!\n", .{});
    print("\nTo get started:\n", .{});
    print("  cd {s}\n", .{project_name});
    print("  zig build run\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var config = try parseArgs(allocator);
    defer config.deinit(allocator);

    if (std.mem.eql(u8, config.protocol, "grpc")) {
        try generateGrpcBoilerplate(allocator, config.project_name);
    } else {
        print("Protocol '{s}' not yet implemented\n", .{config.protocol});
        std.process.exit(1);
    }
}
