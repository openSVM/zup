const std = @import("std");
const fs = std.fs;
const print = std.debug.print;

const usage =
    \\Usage: zup [options] <project-name>
    \\
    \\Options:
    \\  --protocol <http|grpc|ws|http+grpc>    Protocol to use (default: grpc)
    \\  --help                                 Show this help message
    \\
    \\Example:
    \\  zup --protocol http+grpc test-api
    \\
;

const Protocol = struct {
    http: bool = false,
    grpc: bool = false,
    ws: bool = false,
};

const Config = struct {
    project_name: []const u8,
    protocols: Protocol,

    pub fn init() Config {
        return .{
            .project_name = "",
            .protocols = .{
                .grpc = true, // default protocol
            },
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
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
            // Parse combined protocols like "http+grpc"
            var protocols = std.mem.split(u8, arg, "+");
            config.protocols = .{};
            while (protocols.next()) |protocol| {
                if (std.mem.eql(u8, protocol, "http")) {
                    config.protocols.http = true;
                } else if (std.mem.eql(u8, protocol, "grpc")) {
                    config.protocols.grpc = true;
                } else if (std.mem.eql(u8, protocol, "ws")) {
                    config.protocols.ws = true;
                } else {
                    print("Error: invalid protocol '{s}'\n", .{protocol});
                    std.process.exit(1);
                }
            }
            // Validate at least one protocol was specified
            if (!config.protocols.http and !config.protocols.grpc and !config.protocols.ws) {
                print("Error: at least one valid protocol must be specified\n", .{});
                std.process.exit(1);
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

fn copyDirectory(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) !void {
    var src_dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src_dir.close();

    try createDirectory(dst_path);

    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        const src_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_path, entry.name });
        defer allocator.free(src_file_path);
        const dst_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst_path, entry.name });
        defer allocator.free(dst_file_path);

        switch (entry.kind) {
            .file => {
                const contents = try std.fs.cwd().readFileAlloc(allocator, src_file_path, std.math.maxInt(usize));
                defer allocator.free(contents);
                try writeFile(dst_file_path, contents);
            },
            .directory => try copyDirectory(allocator, src_file_path, dst_file_path),
            else => {},
        }
    }
}

const build_template =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    // Core module
    \\    const core_module = b.addModule("core", .{
    \\        .root_source_file = .{ .cwd_relative = "src/framework/core.zig" },
    \\    });
    \\
    \\    // Schema module
    \\    const schema_module = b.addModule("schema", .{
    \\        .root_source_file = .{ .cwd_relative = "src/framework/trpc/schema.zig" },
    \\        .imports = &.{
    \\            .{ .name = "core", .module = core_module },
    \\        },
    \\    });
    \\
    \\    // Runtime Router module
    \\    const runtime_router_module = b.addModule("runtime_router", .{
    \\        .root_source_file = .{ .cwd_relative = "src/framework/trpc/runtime_router.zig" },
    \\        .imports = &.{
    \\            .{ .name = "core", .module = core_module },
    \\            .{ .name = "schema", .module = schema_module },
    \\        },
    \\    });
    \\
    \\    // Framework module
    \\    const framework_module = b.addModule("framework", .{
    \\        .root_source_file = .{ .cwd_relative = "src/framework/server.zig" },
    \\        .imports = &.{
    \\            .{ .name = "core", .module = core_module },
    \\            .{ .name = "schema", .module = schema_module },
    \\        },
    \\    });
    \\
    \\    // Router module
    \\    const router_module = b.addModule("router", .{
    \\        .root_source_file = .{ .cwd_relative = "src/framework/trpc/router.zig" },
    \\        .imports = &.{
    \\            .{ .name = "core", .module = core_module },
    \\            .{ .name = "schema", .module = schema_module },
    \\            .{ .name = "runtime_router", .module = runtime_router_module },
    \\            .{ .name = "framework", .module = framework_module },
    \\        },
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
    \\    exe.root_module.addImport("core", core_module);
    \\    exe.root_module.addImport("framework", framework_module);
    \\    exe.root_module.addImport("router", router_module);
    \\
    \\    b.installArtifact(exe);
    \\
    \\    // Run step
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    const run_step = b.step("run", "Run the server");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
;

const grpc_main_template =
    \\const std = @import("std");
    \\const framework = @import("framework");
    \\const router = @import("router");
    \\const core = @import("core");
    \\
    \\pub fn main() !void {
    \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    \\    const allocator = gpa.allocator();
    \\    defer _ = gpa.deinit();
    \\
    \\    // Initialize server
    \\    const config = framework.ServerConfig{
    \\        .port = 8080,
    \\        .host = "127.0.0.1",
    \\    };
    \\    var server = try framework.Server.init(allocator, config);
    \\    defer server.deinit();
    \\
    \\    // Initialize gRPC router
    \\    var grpc_router = router.Router.init(allocator);
    \\    defer grpc_router.deinit();
    \\
    \\    // Register procedures
    \\    try grpc_router.procedure("hello", handleHello, null, null);
    \\
    \\    // Mount router with server
    \\    try grpc_router.mount(&server);
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
    \\fn handleHello(ctx: *core.Context, input: ?std.json.Value) !std.json.Value {
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

fn generateGrpcBoilerplate(allocator: std.mem.Allocator, project_name: []const u8) !void {
    print("Generating gRPC boilerplate for project '{s}'...\n", .{project_name});

    // Create project directory
    try createDirectory(project_name);

    // Create src directory
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_name});
    defer allocator.free(src_path);
    try createDirectory(src_path);

    // Create framework directory
    const framework_path = try std.fmt.allocPrint(allocator, "{s}/src/framework", .{project_name});
    defer allocator.free(framework_path);
    try copyDirectory(allocator, "zup-main/src/framework", framework_path);

    // Create main.zig
    const main_path = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{project_name});
    defer allocator.free(main_path);
    try writeFile(main_path, grpc_main_template);

    // Create build.zig
    const build_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{project_name});
    defer allocator.free(build_path);
    try writeFile(build_path, build_template);

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

    if (config.protocols.grpc) {
        try generateGrpcBoilerplate(allocator, config.project_name);
    }
    if (config.protocols.http) {
        print("HTTP protocol support coming soon!\n", .{});
    }
    if (config.protocols.ws) {
        print("WebSocket protocol support coming soon!\n", .{});
    }
}
