const std = @import("std");
const testing = std.testing;
const json = std.json;
const core = @import("core");
const Schema = @import("schema").Schema;
const GrpcRouter = @import("grpc_router").GrpcRouter;

const Counter = struct {
    counter: usize = 0,
    mutex: std.Thread.Mutex = .{},
    active: bool = true,

    fn reset(self: *Counter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.counter = 0;
        self.active = true;
    }

    fn increment(self: *Counter) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.active) return error.CounterInactive;
        self.counter += 1;
        return self.counter;
    }

    fn deactivate(self: *Counter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active = false;
    }
};

var global_counter: Counter = .{};

fn counterHandler(ctx: *core.Context, _: ?json.Value) !json.Value {
    _ = ctx;
    const count = try global_counter.increment();
    return json.Value{ .integer = @intCast(count) };
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
    const read_start_time = std.time.nanoTimestamp();
    var total_read: usize = 0;

    while (total_read < buf.len) {
        if (stream.handle == -1) {
            std.debug.print("Connection closed after {d} bytes\n", .{total_read});
            return error.ConnectionClosed;
        }

        const current_time = std.time.nanoTimestamp();
        if (current_time - read_start_time > timeout_ns) {
            std.debug.print("Read timeout after {d} bytes\n", .{total_read});
            return error.Timeout;
        }

        const bytes_read = stream.read(buf[total_read..]) catch |err| {
            if (err == error.EndOfStream or err == error.ConnectionResetByPeer) {
                if (buf.len == 5 and total_read > 0) {
                    return;
                }
                std.debug.print("Stream error after {d} bytes: {}\n", .{ total_read, err });
                return if (total_read == 0) error.ConnectionResetByPeer else error.UnexpectedEof;
            }
            if (err == error.WouldBlock or err == error.WouldBlockNonBlocking) {
                std.time.sleep(1 * std.time.ns_per_ms);
                continue;
            }
            std.debug.print("Read error after {d} bytes: {}\n", .{ total_read, err });
            return err;
        };

        if (bytes_read == 0) {
            if (buf.len == 5 and total_read > 0) {
                return;
            }
            std.debug.print("Got EOF after {d} bytes\n", .{total_read});
            return if (total_read == 0) error.ConnectionResetByPeer else error.UnexpectedEof;
        }

        total_read += bytes_read;
        std.debug.print("Read {d} bytes, total {d}/{d}\n", .{ bytes_read, total_read, buf.len });
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
    std.debug.print("\nShutting down server...\n", .{});
    // First deactivate counter to prevent new increments
    global_counter.deactivate();
    
    // Signal shutdown and close connections
    if (router.server) |server| {
        server.running.store(false, .release);
        server.mutex.lock();
        defer server.mutex.unlock();
        for (server.thread_pool.items) |thread_ctx| {
            thread_ctx.closeConnection();
        }
    }

    // Allow any in-flight requests to complete
    std.time.sleep(100 * std.time.ns_per_ms);

    // Clean up
    router.deinit();
    std.debug.print("Server shutdown complete\n", .{});
}

test "trpc over grpc - basic procedure call" {
    std.debug.print("\n=== Starting basic procedure call test ===\n", .{});
    std.debug.print("Initializing test...\n", .{});
    
    std.debug.print("Creating arena allocator...\n", .{});
    global_counter.reset();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("Creating router...\n", .{});
    var router = GrpcRouter.init(allocator);
    errdefer router.deinit();

    std.debug.print("Adding counter procedure...\n", .{});
    try router.procedure("counter", counterHandler, null, null);

    std.debug.print("Starting server on random port...\n", .{});
    // Use TEST_PORT from environment if set, otherwise use random port
    const port_str = std.os.getenv("TEST_PORT") orelse "0";
    const port = try std.fmt.parseInt(u16, port_str, 10);
    try router.listen(port);
    errdefer shutdownServer(&router);

    // Get server instance and port
    const server = router.server.?;
    const port = server.socket.listen_address.getPort();

    try waitForServer(allocator, port);

    // First call
    {
        std.debug.print("\nMaking first call...\n", .{});
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
        std.debug.print("First call successful\n", .{});
    }

    // Second call
    {
        std.debug.print("\nMaking second call...\n", .{});
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
        std.debug.print("Second call successful\n", .{});
    }

    // Explicitly shutdown server
    shutdownServer(&router);
    std.debug.print("=== Basic procedure call test complete ===\n", .{});
}

test "trpc over grpc - concurrent calls with debug" {
    std.debug.print("\n=== Starting concurrent calls test ===\n", .{});
    global_counter.reset();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var router = GrpcRouter.init(allocator);
    defer shutdownServer(&router);

    try router.procedure("counter", counterHandler, null, null);

    // Use TEST_PORT from environment if set, otherwise use random port
    const port_str = std.os.getenv("TEST_PORT") orelse "0";
    const port = try std.fmt.parseInt(u16, port_str, 10);
    try router.listen(port);

    // Get server instance
    const server = router.server.?;

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
                var thread_arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer thread_arena.deinit();
                const thread_allocator = thread_arena.allocator();

                std.debug.print("\nThread {d}: Starting\n", .{thread_id});
                const stream = std.net.tcpConnectToHost(thread_allocator, "127.0.0.1", server_port) catch |err| {
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
        std.debug.print("\nVerifying final counter value...\n", .{});
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
        std.debug.print("Counter verification successful\n", .{});
    }
    std.debug.print("=== Concurrent calls test complete ===\n", .{});
}

test "trpc over grpc - schema validation" {
    std.debug.print("\n=== Starting schema validation test ===\n", .{});
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
        std.debug.print("\nTesting valid request...\n", .{});
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
        std.debug.print("Valid request test successful\n", .{});
    }

    // Invalid request - missing required field
    {
        std.debug.print("\nTesting missing field request...\n", .{});
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
        std.debug.print("Missing field test successful\n", .{});
    }

    // Invalid request - wrong type
    {
        std.debug.print("\nTesting wrong type request...\n", .{});
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
        std.debug.print("Wrong type test successful\n", .{});
    }
    std.debug.print("=== Schema validation test complete ===\n", .{});
}

test "trpc over grpc - error handling" {
    std.debug.print("\n=== Starting error handling test ===\n", .{});
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
        std.debug.print("\nTesting short frame...\n", .{});
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
        std.debug.print("Short frame test successful\n", .{});
    }

    // Invalid JSON
    {
        std.debug.print("\nTesting invalid JSON...\n", .{});
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
        std.debug.print("Invalid JSON test successful\n", .{});
    }

    // Missing method
    {
        std.debug.print("\nTesting missing method...\n", .{});
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
        std.debug.print("Missing method test successful\n", .{});
    }

    // Invalid method type
    {
        std.debug.print("\nTesting invalid method type...\n", .{});
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
        std.debug.print("Invalid method type test successful\n", .{});
    }
    std.debug.print("=== Error handling test complete ===\n", .{});
}
