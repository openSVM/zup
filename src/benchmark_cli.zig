const std = @import("std");
const benchmark = @import("benchmark.zig");
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const address = try net.Address.parseIp("127.0.0.1", 8080);
    const duration_ms: u64 = 60 * 1000; // 1 minute

    // Benchmark GET requests
    std.debug.print("\nBenchmarking GET requests for {} ms...\n", .{duration_ms});
    const get_result = try benchmark.benchmarkHttp(allocator, address, "GET", duration_ms);
    std.debug.print("GET Results:\n", .{});
    std.debug.print("  Requests/second: {d:.2}\n", .{get_result.requests_per_second});
    std.debug.print("  Total requests: {}\n", .{get_result.total_requests});
    std.debug.print("  Total errors: {}\n", .{get_result.errors});
    std.debug.print("  Actual duration: {} ms\n", .{get_result.duration_ms});

    // Benchmark POST requests
    std.debug.print("\nBenchmarking POST requests for {} ms...\n", .{duration_ms});
    const post_result = try benchmark.benchmarkHttp(allocator, address, "POST", duration_ms);
    std.debug.print("POST Results:\n", .{});
    std.debug.print("  Requests/second: {d:.2}\n", .{post_result.requests_per_second});
    std.debug.print("  Total requests: {}\n", .{post_result.total_requests});
    std.debug.print("  Total errors: {}\n", .{post_result.errors});
    std.debug.print("  Actual duration: {} ms\n", .{post_result.duration_ms});
}
