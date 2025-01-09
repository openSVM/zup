const std = @import("std");
const spice = @import("spice");
const net = std.net;
const time = std.time;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ws = @import("websocket.zig");
const base64 = std.base64;
const Sha1 = std.crypto.hash.Sha1;

const BenchmarkResult = struct {
    requests_per_second: f64,
    avg_latency_ns: f64,
    p95_latency_ns: f64,
    p99_latency_ns: f64,
};

const BenchmarkConfig = struct {
    duration_ms: u64 = 60_000, // 1 minute
    concurrent_connections: u32 = 100,
    request_type: enum { GET, POST, WS } = .GET,
};

fn runBenchmark(allocator: Allocator, config: BenchmarkConfig) !BenchmarkResult {
    var latencies = std.ArrayList(u64).init(allocator);
    defer latencies.deinit();

    var pool = spice.ThreadPool.init(allocator);
    pool.start(.{ .background_worker_count = config.concurrent_connections });
    defer pool.deinit();

    const start_time = time.nanoTimestamp();
    const duration_ns = @as(i64, @intCast(config.duration_ms)) * @as(i64, time.ns_per_ms);
    const end_time = start_time + duration_ns;

    // Start benchmark workers
    for (0..config.concurrent_connections) |_| {
        if (pool.call(error{}!void, benchmarkWorker, .{
            .allocator = allocator,
            .latencies = &latencies,
            .config = config,
            .end_time = end_time,
        })) |_| {} else |err| {
            _ = err;
        }
    }

    // Calculate statistics
    const total_time_ns = @as(f64, @floatFromInt(time.nanoTimestamp() - start_time));
    const total_requests = @as(f64, @floatFromInt(latencies.items.len));
    const requests_per_second = (total_requests * time.ns_per_s) / total_time_ns;

    // Sort latencies for percentile calculations
    std.sort.heap(u64, latencies.items, {}, std.sort.asc(u64));

    const avg_latency = blk: {
        var sum: u64 = 0;
        for (latencies.items) |lat| {
            sum += lat;
        }
        break :blk @as(f64, @floatFromInt(sum)) / total_requests;
    };

    const p95_idx = @as(usize, @intFromFloat(total_requests * 0.95));
    const p99_idx = @as(usize, @intFromFloat(total_requests * 0.99));

    return BenchmarkResult{
        .requests_per_second = requests_per_second,
        .avg_latency_ns = avg_latency,
        .p95_latency_ns = @floatFromInt(latencies.items[p95_idx]),
        .p99_latency_ns = @floatFromInt(latencies.items[p99_idx]),
    };
}

const BenchmarkContext = struct {
    allocator: Allocator,
    latencies: *std.ArrayList(u64),
    config: BenchmarkConfig,
    end_time: i64,
};

fn benchmarkWorker(t: *spice.Task, ctx: BenchmarkContext) error{}!void {
    _ = t;
    const client = net.tcpConnectToHost(ctx.allocator, "127.0.0.1", 8080) catch |err| {
        _ = err;
        return;
    };
    defer client.close();

    var buf: [1024]u8 = undefined;

    while (time.nanoTimestamp() < ctx.end_time) {
        const start = time.nanoTimestamp();

        switch (ctx.config.request_type) {
            .GET => {
                client.write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n") catch |err| {
                    _ = err;
                    continue;
                };
                client.read(&buf) catch |err| {
                    _ = err;
                    continue;
                };
            },
            .POST => {
                client.write("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\nOK") catch |err| {
                    _ = err;
                    continue;
                };
                client.read(&buf) catch |err| {
                    _ = err;
                    continue;
                };
            },
            .WS => {
                // Send WebSocket upgrade request
                const key = "dGhlIHNhbXBsZSBub25jZQ=="; // Base64 encoded "the sample nonce"
                const upgrade_request = std.fmt.allocPrint(
                    ctx.allocator,
                    "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
                    .{key},
                ) catch |err| {
                    _ = err;
                    continue;
                };
                defer ctx.allocator.free(upgrade_request);

                client.write(upgrade_request) catch |err| {
                    _ = err;
                    continue;
                };

                // Read upgrade response
                var upgrade_buf: [1024]u8 = undefined;
                client.read(&upgrade_buf) catch |err| {
                    _ = err;
                    continue;
                };

                // Send and receive echo messages
                const message = "benchmark test message";
                ws.writeMessage(client, message) catch |err| {
                    _ = err;
                    continue;
                };

                const response = ws.readMessage(client) catch |err| {
                    _ = err;
                    continue;
                };
                defer std.heap.page_allocator.free(response.payload);
            },
        }

        const latency = @as(u64, @intCast(time.nanoTimestamp() - start));
        ctx.latencies.append(latency) catch |err| {
            _ = err;
            continue;
        };
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Run GET benchmark
    {
        const result = try runBenchmark(allocator, .{ .request_type = .GET });
        std.debug.print("GET Benchmark Results:\n", .{});
        std.debug.print("  Requests/sec: {d:.2}\n", .{result.requests_per_second});
        std.debug.print("  Avg latency: {d:.2} ns\n", .{result.avg_latency_ns});
        std.debug.print("  P95 latency: {d:.2} ns\n", .{result.p95_latency_ns});
        std.debug.print("  P99 latency: {d:.2} ns\n", .{result.p99_latency_ns});
    }

    // Run POST benchmark
    {
        const result = try runBenchmark(allocator, .{ .request_type = .POST });
        std.debug.print("\nPOST Benchmark Results:\n", .{});
        std.debug.print("  Requests/sec: {d:.2}\n", .{result.requests_per_second});
        std.debug.print("  Avg latency: {d:.2} ns\n", .{result.avg_latency_ns});
        std.debug.print("  P95 latency: {d:.2} ns\n", .{result.p95_latency_ns});
        std.debug.print("  P99 latency: {d:.2} ns\n", .{result.p99_latency_ns});
    }

    // Run WebSocket benchmark
    {
        const result = try runBenchmark(allocator, .{
            .request_type = .WS,
            .concurrent_connections = 50, // Lower connections for WS benchmark
            .duration_ms = 30_000, // 30 seconds for WS benchmark
        });
        std.debug.print("\nWebSocket Benchmark Results:\n", .{});
        std.debug.print("  Messages/sec: {d:.2}\n", .{result.requests_per_second});
        std.debug.print("  Avg latency: {d:.2} ns\n", .{result.avg_latency_ns});
        std.debug.print("  P95 latency: {d:.2} ns\n", .{result.p95_latency_ns});
        std.debug.print("  P99 latency: {d:.2} ns\n", .{result.p99_latency_ns});
    }
}

test "HTTP benchmark sanity" {
    const result = try runBenchmark(testing.allocator, .{
        .duration_ms = 1000,
        .concurrent_connections = 2,
        .request_type = .GET,
    });

    try testing.expect(result.requests_per_second > 0);
    try testing.expect(result.avg_latency_ns > 0);
    try testing.expect(result.p95_latency_ns >= result.avg_latency_ns);
    try testing.expect(result.p99_latency_ns >= result.p95_latency_ns);
}

test "WebSocket benchmark sanity" {
    const result = try runBenchmark(testing.allocator, .{
        .duration_ms = 1000,
        .concurrent_connections = 2,
        .request_type = .WS,
    });

    try testing.expect(result.requests_per_second > 0);
    try testing.expect(result.avg_latency_ns > 0);
    try testing.expect(result.p95_latency_ns >= result.avg_latency_ns);
    try testing.expect(result.p99_latency_ns >= result.p95_latency_ns);
}
