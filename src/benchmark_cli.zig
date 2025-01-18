const std = @import("std");
const benchmark = @import("benchmark.zig");
const net = std.net;

const usage =
    \\Usage: benchmark [options]
    \\
    \\Options:
    \\  --method <GET|POST>    HTTP method to benchmark (default: GET)
    \\  --duration <seconds>   Duration of benchmark in seconds (default: 30)
    \\  --connections <num>    Number of concurrent connections (default: 100)
    \\  --host <host>         Host to benchmark (default: 127.0.0.1)
    \\  --port <port>         Port to benchmark (default: 8080)
    \\  --help                Show this help message
    \\
;

const Config = struct {
    method: []const u8 = "GET",
    duration_s: u64 = 30,
    connections: u32 = 100,
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (!std.mem.eql(u8, self.method, "GET")) {
            allocator.free(self.method);
        }
        if (!std.mem.eql(u8, self.host, "127.0.0.1")) {
            allocator.free(self.host);
        }
    }
};

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var config = Config{};

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip executable name
    _ = args.skip();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}\n", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--method")) {
            const method = args.next() orelse {
                std.debug.print("Error: --method requires a value\n", .{});
                std.process.exit(1);
            };
            if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "POST")) {
                std.debug.print("Error: method must be GET or POST\n", .{});
                std.process.exit(1);
            }
            if (!std.mem.eql(u8, method, "GET")) {
                config.method = try allocator.dupe(u8, method);
            }
        } else if (std.mem.eql(u8, arg, "--duration")) {
            const duration_str = args.next() orelse {
                std.debug.print("Error: --duration requires a value\n", .{});
                std.process.exit(1);
            };
            config.duration_s = std.fmt.parseInt(u64, duration_str, 10) catch {
                std.debug.print("Error: invalid duration value\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--connections")) {
            const conn_str = args.next() orelse {
                std.debug.print("Error: --connections requires a value\n", .{});
                std.process.exit(1);
            };
            config.connections = std.fmt.parseInt(u32, conn_str, 10) catch {
                std.debug.print("Error: invalid connections value\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--host")) {
            const host = args.next() orelse {
                std.debug.print("Error: --host requires a value\n", .{});
                std.process.exit(1);
            };
            if (!std.mem.eql(u8, host, "127.0.0.1")) {
                config.host = try allocator.dupe(u8, host);
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            const port_str = args.next() orelse {
                std.debug.print("Error: --port requires a value\n", .{});
                std.process.exit(1);
            };
            config.port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("Error: invalid port value\n", .{});
                std.process.exit(1);
            };
        }
    }

    return config;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = try parseArgs(allocator);
    defer config.deinit(allocator);
    const duration_ms = config.duration_s * 1000;

    const address = try net.Address.parseIp(config.host, config.port);

    // Print benchmark configuration
    std.debug.print("\nBenchmark Configuration:\n", .{});
    std.debug.print("  Method: {s}\n", .{config.method});
    std.debug.print("  Duration: {}s\n", .{config.duration_s});
    std.debug.print("  Connections: {}\n", .{config.connections});
    std.debug.print("  Host: {s}:{}\n", .{ config.host, config.port });

    // Run benchmark
    std.debug.print("\nRunning benchmark...\n", .{});
    const result = try benchmark.benchmarkHttp(allocator, address, config.method, duration_ms);

    // Print results
    std.debug.print("\nResults:\n", .{});
    std.debug.print("  Requests/second: {d:.2}\n", .{result.requests_per_second});
    std.debug.print("  Total requests: {}\n", .{result.total_requests});
    std.debug.print("  Total errors: {}\n", .{result.errors});
    std.debug.print("  Actual duration: {} ms\n", .{result.duration_ms});
}
