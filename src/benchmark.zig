const std = @import("std");
const net = std.net;
const time = std.time;

pub const BenchmarkResult = struct {
    requests_per_second: f64,
    total_requests: usize,
    duration_ms: u64,
    errors: usize,
};

pub fn benchmarkHttp(allocator: std.mem.Allocator, address: net.Address, method: []const u8, duration_ms: u64) !BenchmarkResult {
    const start_time = time.milliTimestamp();
    const end_time = start_time + @as(i64, @intCast(duration_ms));

    var total_requests: usize = 0;
    var errors: usize = 0;

    // Create thread pool for parallel requests
    const thread_count = try std.Thread.getCpuCount();
    const threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    const ThreadContext = struct {
        address: net.Address,
        method: []const u8,
        end_time: i64,
        requests: usize = 0,
        errors: usize = 0,
    };

    var contexts = try allocator.alloc(ThreadContext, thread_count);
    defer allocator.free(contexts);

    // Initialize contexts
    for (contexts) |*ctx| {
        ctx.* = .{
            .address = address,
            .method = method,
            .end_time = end_time,
        };
    }

    // Start benchmark threads
    for (threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, struct {
            fn run(ctx: *ThreadContext) void {
                // Create persistent connection with retries
                const max_retries = 3;
                var retry_count: u32 = 0;
                var stream = while (retry_count < max_retries) : (retry_count += 1) {
                    if (net.tcpConnectToAddress(ctx.address)) |conn| {
                        break conn;
                    } else |err| switch (err) {
                        error.ConnectionRefused => {
                            std.time.sleep(10 * std.time.ns_per_ms);
                            continue;
                        },
                        else => {
                            ctx.errors += 1;
                            return;
                        },
                    }
                } else {
                    ctx.errors += 1;
                    return;
                };
                defer stream.close();

                // Pre-allocate request and response buffers
                var request_buf: [256]u8 = undefined;
                const request = if (std.mem.eql(u8, ctx.method, "GET"))
                    std.fmt.bufPrint(&request_buf, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n", .{}) catch return
                else
                    std.fmt.bufPrint(&request_buf, "POST / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\nOK", .{}) catch return;

                var response_buf: [8192]u8 = undefined;

                while (time.milliTimestamp() < ctx.end_time) {
                    // Send request with error handling
                    if (stream.write(request)) |_| {
                        // Read response with error handling
                        if (stream.read(&response_buf)) |_| {
                            ctx.requests += 1;
                        } else |_| {
                            ctx.errors += 1;
                            continue;
                        }
                    } else |_| {
                        ctx.errors += 1;
                        continue;
                    }
                }
            }
        }.run, .{&contexts[i]});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Sum up results
    for (contexts) |ctx| {
        total_requests += ctx.requests;
        errors += ctx.errors;
    }

    const actual_duration = @as(u64, @intCast(time.milliTimestamp() - start_time));
    const requests_per_second = @as(f64, @floatFromInt(total_requests)) / (@as(f64, @floatFromInt(actual_duration)) / 1000.0);

    return BenchmarkResult{
        .requests_per_second = requests_per_second,
        .total_requests = total_requests,
        .duration_ms = actual_duration,
        .errors = errors,
    };
}
