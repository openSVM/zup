const std = @import("std");
const testing = std.testing;
const json = std.json;
const core = @import("core");
const Schema = @import("schema").Schema;
const GrpcRouter = @import("grpc_router").GrpcRouter;

const Counter = struct {
    counter: usize = 0,
    mutex: std.Thread.Mutex = .{},

    fn reset(self: *Counter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.counter = 0;
    }
};

var global_counter: Counter = .{};

fn counterHandler(ctx: *core.Context, _: ?json.Value) !json.Value {
    _ = ctx;
    global_counter.mutex.lock();
    defer global_counter.mutex.unlock();
    global_counter.counter += 1;
    return json.Value{ .integer = @intCast(global_counter.counter) };
}

fn echoHandler(ctx: *core.Context, input: ?json.Value) !json.Value {
    _ = ctx;
    return input.?;
}

fn validateHandler(ctx: *core.Context, input: ?json.Value) !json.Value {
    _ = ctx;
    return input.?;
}

fn readExactly(stream: std.net.Stream, buf: []u8, timeout_ns: i128) !void {
    const start_time = std.time.nanoTimestamp();
    var total_read: usize = 0;

    while (total_read < buf.len) {
        const current_time = std.time.nanoTimestamp();
        if (current_time - start_time > timeout_ns) {
            return error.Timeout;
        }

        const n = try stream.read(buf[total_read..]);
        if (n == 0) {
            if (total_read == 0) {
                return error.EndOfStream;
            }
            return error.UnexpectedEof;
        }
        total_read += n;
    }
}

fn waitForServer(allocator: std.mem.Allocator, port: u16) !void {
    std.debug.print("\nWaiting for server to be ready on port {d}...\n", .{port});
    var attempts: usize = 0;
    const max_attempts = 50;
    const timeout_ns = 5 * std.time.ns_per_s;

    while (attempts < max_attempts) : (attempts += 1) {
        std.debug.print("Attempt {d}/{d}\n", .{ attempts + 1, max_attempts });

        const stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch |err| {
            if (err == error.ConnectionRefused) {
                std.time.sleep(100 * std.time.ns_per_ms);
                continue;
            }
            std.debug.print("Connection error: {}\n", .{err});
            return err;
        };
        defer stream.close();

        // Send a test request
        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;
        const request_json = "{\"id\":\"0\",\"method\":\"counter\",\"params\":null}";
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        stream.writeAll(request_buf[0 .. 5 + request_json.len]) catch |err| {
            std.debug.print("Write error: {}\n", .{err});
            continue;
        };

        var response_buf: [1024]u8 = undefined;
        readExactly(stream, response_buf[0..5], timeout_ns) catch |err| {
            std.debug.print("Read error: {}\n", .{err});
            continue;
        };

        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        if (length > response_buf.len - 5) {
            std.debug.print("Response too large: {d}\n", .{length});
            continue;
        }

        readExactly(stream, response_buf[5..][0..length], timeout_ns) catch |err| {
            std.debug.print("Read body error: {}\n", .{err});
            continue;
        };

        std.debug.print("Server ready after {d} attempts\n", .{attempts + 1});
        return;
    }

    std.debug.print("Server failed to become ready after {d} attempts\n", .{max_attempts});
    return error.ServerNotReady;
}

fn shutdownServer(router: *GrpcRouter) void {
    router.shutdown();
    std.time.sleep(50 * std.time.ns_per_ms); // Allow time for cleanup
    router.deinit();
}

test "trpc over grpc - basic procedure call" {
    global_counter.reset();
    const allocator = testing.allocator;

    var router = GrpcRouter.init(allocator);
    defer shutdownServer(&router);

    try router.procedure("counter", counterHandler, null, null);

    // Start server on random port
    try router.listen(0);

    // Get actual port and server
    const server = router.server.?;
    const port = server.socket.listen_address.getPort();

    try waitForServer(allocator, port);

    // First call
    {
        const stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
        defer stream.close();

        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;

        const request_json = "{\"id\":\"1\",\"method\":\"counter\",\"params\":null}";
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        try stream.writeAll(request_buf[0 .. 5 + request_json.len]);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);

        const compressed = response_buf[0] == 1;
        if (compressed) return error.CompressionNotSupported;

        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        if (length > response_buf.len - 5) return error.ResponseTooLarge;

        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"result\":1") != null);
    }

    // Second call
    {
        const stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
        defer stream.close();

        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;

        const request_json = "{\"id\":\"2\",\"method\":\"counter\",\"params\":null}";
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        try stream.writeAll(request_buf[0 .. 5 + request_json.len]);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);

        const compressed = response_buf[0] == 1;
        if (compressed) return error.CompressionNotSupported;

        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        if (length > response_buf.len - 5) return error.ResponseTooLarge;

        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"result\":2") != null);
    }
}

test "trpc over grpc - concurrent calls with debug" {
    global_counter.reset();
    const allocator = testing.allocator;

    var router = GrpcRouter.init(allocator);
    defer shutdownServer(&router);

    try router.procedure("counter", counterHandler, null, null);

    // Start server on random port
    try router.listen(0);

    // Get actual port and server
    const server = router.server.?;
    const port = server.socket.listen_address.getPort();

    try waitForServer(allocator, port);

    std.debug.print("\nStarting concurrent calls test\n", .{});
    
    // Make concurrent calls with proper error handling and debug logging
    const num_threads = 3;
    var threads: [3]std.Thread = undefined;
    var errors = try allocator.alloc(?anyerror, num_threads);
    defer allocator.free(errors);
    for (errors) |*err| err.* = null;

    std.debug.print("Spawning {d} threads\n", .{num_threads});

    for (0..num_threads) |i| {
        std.debug.print("Spawning thread {d}\n", .{i});
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn call(server_port: u16, error_slot: *?anyerror, thread_id: usize) !void {
                std.debug.print("\nThread {d}: Starting\n", .{thread_id});
                const stream = std.net.tcpConnectToHost(testing.allocator, "127.0.0.1", server_port) catch |err| {
                    std.debug.print("\nThread {d}: Connection error: {}\n", .{thread_id, err});
                    error_slot.* = err;
                    return error.ConnectionFailed;
                };
                defer stream.close();

                var request_buf: [1024]u8 = undefined;
                request_buf[0] = 0;

                const request_json =
                    \\{"id":"1","method":"counter","params":null}
                ;
                std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
                @memcpy(request_buf[5..][0..request_json.len], request_json);

                std.debug.print("\nThread {d}: Writing request\n", .{thread_id});
                stream.writeAll(request_buf[0 .. 5 + request_json.len]) catch |err| {
                    std.debug.print("\nThread {d}: Write error: {}\n", .{thread_id, err});
                    error_slot.* = err;
                    return error.WriteFailed;
                };

                var response_buf: [1024]u8 = undefined;
                std.debug.print("\nThread {d}: Reading response header\n", .{thread_id});
                readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s) catch |err| {
                    std.debug.print("\nThread {d}: Read header error: {}\n", .{thread_id, err});
                    error_slot.* = err;
                    return error.ReadHeaderFailed;
                };

                const length = std.mem.readInt(u32, response_buf[1..5], .big);
                std.debug.print("\nThread {d}: Reading response body of length {d}\n", .{thread_id, length});

                readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s) catch |err| {
                    std.debug.print("\nThread {d}: Read body error: {}\n", .{thread_id, err});
                    error_slot.* = err;
                    return error.ReadBodyFailed;
                };

                std.debug.print("\nThread {d}: Complete\n", .{thread_id});
                std.time.sleep(10 * std.time.ns_per_ms); // Small delay before closing connection
            }
        }.call, .{port, &errors[i], i});
    }

    // Wait for all threads and check errors with debug logging
    std.debug.print("\n=== Waiting for threads to complete ===\n", .{});
    for (threads, 0..) |thread, i| {
        std.debug.print("\nJoining thread {d}...\n", .{i});
        thread.join();
        if (errors[i]) |e| {
            std.debug.print("\nThread {d} failed with error: {}\n", .{i, e});
            return e;
        }
        std.debug.print("\nThread {d} completed successfully\n", .{i});
    }
    
    std.debug.print("\n=== All threads completed successfully ===\n", .{});

    // Verify counter
    {
        const stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
        defer stream.close();

        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;

        const request_json =
            \\{"id":"1","method":"counter","params":null}
        ;
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        try stream.writeAll(request_buf[0 .. 5 + request_json.len]);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"result\":4") != null);
    }
}

test "trpc over grpc - schema validation" {
    const allocator = testing.allocator;

    var router = GrpcRouter.init(allocator);
    defer shutdownServer(&router);

    var input_props = std.StringHashMap(Schema).init(allocator);
    try input_props.put("message", .{ .object = .String });
    try input_props.put("count", .{ .object = .Number });

    const input_schema = Schema{
        .object = .{
            .Object = .{
                .required = &[_][]const u8{ "message", "count" },
                .properties = input_props,
            },
        },
    };

    var output_props = std.StringHashMap(Schema).init(allocator);
    try output_props.put("message", .{ .object = .String });
    try output_props.put("count", .{ .object = .Number });

    const output_schema = Schema{
        .object = .{
            .Object = .{
                .required = &[_][]const u8{ "message", "count" },
                .properties = output_props,
            },
        },
    };

    try router.procedure("validate", validateHandler, input_schema, output_schema);

    // Start server on random port
    try router.listen(0);

    // Get actual port and server
    const server = router.server.?;
    const port = server.socket.listen_address.getPort();

    try waitForServer(allocator, port);

    // Valid request
    {
        const stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
        defer stream.close();

        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;

        const request_json =
            \\{"id":"1","method":"validate","params":{"message":"hello","count":42}}
        ;
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        try stream.writeAll(request_buf[0 .. 5 + request_json.len]);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"result\":{\"message\":\"hello\",\"count\":42}") != null);
    }

    // Invalid request - missing required field
    {
        const stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
        defer stream.close();

        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;

        const request_json =
            \\{"id":"1","method":"validate","params":{"message":"hello"}}
        ;
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        try stream.writeAll(request_buf[0 .. 5 + request_json.len]);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"error\":{\"code\":9,\"message\":\"Invalid input parameters\"}") != null);
    }

    // Invalid request - wrong type
    {
        const stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
        defer stream.close();

        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;

        const request_json =
            \\{"id":"1","method":"validate","params":{"message":"hello","count":"42"}}
        ;
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        try stream.writeAll(request_buf[0 .. 5 + request_json.len]);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"error\":{\"code\":9,\"message\":\"Invalid input parameters\"}") != null);
    }
}

test "trpc over grpc - error handling" {
    const allocator = testing.allocator;

    var router = GrpcRouter.init(allocator);
    defer shutdownServer(&router);

    try router.procedure("echo", echoHandler, null, null);

    // Start server on random port
    try router.listen(0);

    // Get actual port and server
    const server = router.server.?;
    const port = server.socket.listen_address.getPort();

    try waitForServer(allocator, port);

    // Invalid gRPC frame - too short
    {
        const stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
        defer stream.close();

        var request_buf: [4]u8 = undefined;
        try stream.writeAll(&request_buf);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"error\":{\"code\":3,\"message\":\"Invalid gRPC frame\"}") != null);
    }

    // Invalid JSON
    {
        const stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
        defer stream.close();

        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;

        const request_json = "invalid json";
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        try stream.writeAll(request_buf[0 .. 5 + request_json.len]);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"error\":{\"code\":3,\"message\":\"Invalid JSON request\"}") != null);
    }

    // Missing method
    {
        const stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
        defer stream.close();

        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;

        const request_json =
            \\{"id":"1","params":null}
        ;
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        try stream.writeAll(request_buf[0 .. 5 + request_json.len]);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"error\":{\"code\":3,\"message\":\"Missing method\"}") != null);
    }

    // Invalid method type
    {
        const stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
        defer stream.close();

        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;

        const request_json =
            \\{"id":"1","method":42,"params":null}
        ;
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        try stream.writeAll(request_buf[0 .. 5 + request_json.len]);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"error\":{\"code\":3,\"message\":\"Invalid method type\"}") != null);
    }
}
