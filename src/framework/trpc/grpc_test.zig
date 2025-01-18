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

    const start_time = std.time.nanoTimestamp();
    const timeout_ns = 5 * std.time.ns_per_s;
    var attempts: usize = 0;

    while (std.time.nanoTimestamp() - start_time < timeout_ns) : (attempts += 1) {
        std.debug.print("\nAttempt {d} to connect to server\n", .{attempts + 1});

        // Try to establish connection
        const stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch |err| {
            if (err == error.ConnectionRefused) {
                std.time.sleep(50 * std.time.ns_per_ms); // Reduced sleep time for faster retries
                continue;
            }
            // For other connection errors, return immediately
            std.debug.print("Connection failed with error: {}\n", .{err});
            return err;
        };
        defer stream.close();

        // Send a test request
        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;
        const request_json = "{\"id\":\"0\",\"method\":\"counter\",\"params\":null}";
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        // Try to send request
        stream.writeAll(request_buf[0 .. 5 + request_json.len]) catch |err| {
            std.debug.print("Failed to send request: {}\n", .{err});
            // If we can't write, server isn't ready
            continue;
        };

        // Read response header
        var response_buf: [1024]u8 = undefined;
        readExactly(stream, response_buf[0..5], timeout_ns - (std.time.nanoTimestamp() - start_time)) catch |err| {
            std.debug.print("Failed to read response header: {}\n", .{err});
            continue;
        };

        // Validate response length
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        if (length > response_buf.len - 5) {
            std.debug.print("Response too large: {d}\n", .{length});
            continue;
        }

        // Read response body
        readExactly(stream, response_buf[5..][0..length], timeout_ns - (std.time.nanoTimestamp() - start_time)) catch |err| {
            std.debug.print("Failed to read response body: {}\n", .{err});
            continue;
        };

        // If we got here, server is ready
        std.debug.print("Server ready after {d} attempts\n", .{attempts + 1});
        return;
    }

    std.debug.print("Server failed to become ready within timeout of {d}ns\n", .{timeout_ns});
    return error.ServerNotReady;
}

fn shutdownServer(router: *GrpcRouter) void {
    std.debug.print("\n=== Starting server shutdown ===\n", .{});

    // First deactivate counter to prevent new increments
    std.debug.print("Deactivating counter...\n", .{});
    global_counter.deactivate();

    // Signal shutdown to prevent new connections
    if (router.server) |server| {
        std.debug.print("Setting server running to false...\n", .{});
        server.running.store(false, .release);

        // Wait for server thread to stop accepting new connections
        std.debug.print("Waiting for server thread to stop accepting connections...\n", .{});
        std.time.sleep(50 * std.time.ns_per_ms);

        // Lock server mutex before modifying thread pool
        std.debug.print("Locking server mutex...\n", .{});
        server.mutex.lock();
        defer {
            std.debug.print("Unlocking server mutex...\n", .{});
            server.mutex.unlock();
        }

        // Signal all threads to stop accepting new requests
        std.debug.print("Signaling {d} threads to stop...\n", .{server.thread_pool.items.len});
        for (server.thread_pool.items, 0..) |thread_ctx, i| {
            std.debug.print("Setting thread {d} done flag...\n", .{i});
            thread_ctx.done.store(true, .release);
        }

        // Wait for in-flight requests to complete with timeout
        const shutdown_timeout = 5 * std.time.ns_per_s;
        const shutdown_start = std.time.nanoTimestamp();
        var shutdown_complete = false;

        while (!shutdown_complete and std.time.nanoTimestamp() - shutdown_start < shutdown_timeout) {
            // Check each thread's status under mutex protection
            shutdown_complete = true;
            for (server.thread_pool.items, 0..) |thread_ctx, i| {
                const thread_done = thread_ctx.done.load(.acquire);
                const is_processing = thread_ctx.is_processing.load(.acquire);

                if (!thread_done or is_processing) {
                    std.debug.print("Thread {d} still active (done={}, processing={})\n", .{ i, thread_done, is_processing });
                    shutdown_complete = false;
                    break;
                }
            }

            if (!shutdown_complete) {
                // Release mutex while waiting to allow threads to make progress
                server.mutex.unlock();
                std.time.sleep(10 * std.time.ns_per_ms);
                server.mutex.lock();
            }
        }

        if (!shutdown_complete) {
            std.debug.print("WARNING: Some threads did not complete within timeout\n", .{});
        }

        // Now safe to close connections
        std.debug.print("Closing connections for {d} threads...\n", .{server.thread_pool.items.len});
        for (server.thread_pool.items, 0..) |thread_ctx, i| {
            std.debug.print("Closing connection for thread {d}...\n", .{i});
            thread_ctx.closeConnection();
        }

        // Wait a bit more for threads to clean up after connection close
        std.time.sleep(50 * std.time.ns_per_ms);
    } else {
        std.debug.print("No server instance found\n", .{});
    }

    // Clean up router
    std.debug.print("Deinitializing router...\n", .{});
    router.deinit();
    std.debug.print("=== Server shutdown complete ===\n", .{});
}

const TestContext = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    router: GrpcRouter,
    port: u16,

    pub fn init(base_allocator: std.mem.Allocator) !TestContext {
        std.debug.print("\n=== Initializing test context ===\n", .{});
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        const allocator = arena.allocator();

        var router = GrpcRouter.init(allocator);
        errdefer {
            router.deinit();
            arena.deinit();
        }

        // Get port from environment or use random
        const port_str = std.process.getEnvVarOwned(allocator, "TEST_PORT") catch |err| blk: {
            std.debug.print("Failed to get TEST_PORT: {}, using default port 0\n", .{err});
            break :blk "0";
        };
        const port = std.fmt.parseInt(u16, port_str, 10) catch |err| {
            std.debug.print("Failed to parse TEST_PORT: {}, using default port 0\n", .{err});
            return err;
        };

        return TestContext{
            .arena = arena,
            .allocator = allocator,
            .router = router,
            .port = port,
        };
    }

    pub fn deinit(self: *TestContext) void {
        std.debug.print("\n=== Cleaning up test context ===\n", .{});
        shutdownServer(&self.router);
        self.arena.deinit();
    }
};

test "trpc over grpc - basic procedure call" {
    std.debug.print("\n=== Starting basic procedure call test ===\n", .{});

    // Initialize test context
    var test_ctx = try TestContext.init(testing.allocator);
    defer test_ctx.deinit();

    global_counter.reset();

    // Configure and start server
    std.debug.print("Configuring server...\n", .{});
    try test_ctx.router.procedure("counter", counterHandler, null, null);

    std.debug.print("Starting server on port {}...\n", .{test_ctx.port});
    try test_ctx.router.listen(test_ctx.port);

    const server = test_ctx.router.server orelse {
        std.debug.print("Server not initialized\n", .{});
        return error.ServerNotInitialized;
    };

    const actual_port = server.socket.listen_address.getPort();
    std.debug.print("Server listening on port {}\n", .{actual_port});

    // Wait for server with timeout
    const server_timeout = 5 * std.time.ns_per_s;
    const server_start = std.time.nanoTimestamp();
    while (true) {
        waitForServer(test_ctx.allocator, actual_port) catch |err| {
            if (std.time.nanoTimestamp() - server_start > server_timeout) {
                std.debug.print("Server failed to start within timeout: {}\n", .{err});
                return err;
            }
            std.time.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        break;
    }
    std.debug.print("Server is ready\n", .{});

    // Make first call
    std.debug.print("\nMaking first call to counter procedure...\n", .{});
    {
        const stream = std.net.tcpConnectToHost(test_ctx.allocator, "127.0.0.1", actual_port) catch |err| {
            std.debug.print("Failed to connect to server: {}\n", .{err});
            return err;
        };
        defer {
            std.debug.print("Closing first call connection...\n", .{});
            stream.close();
        }

        // Prepare request
        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0; // No compression
        const request_json = "{\"id\":\"1\",\"method\":\"counter\",\"params\":null}";
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        // Send request
        std.debug.print("Sending request: {s}\n", .{request_json});
        stream.writeAll(request_buf[0 .. 5 + request_json.len]) catch |err| {
            std.debug.print("Failed to send request: {}\n", .{err});
            return err;
        };

        // Read response
        var response_buf: [1024]u8 = undefined;
        std.debug.print("Reading response header...\n", .{});
        readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s) catch |err| {
            std.debug.print("Failed to read response header: {}\n", .{err});
            return err;
        };

        // Check compression
        const compressed = response_buf[0] == 1;
        if (compressed) {
            std.debug.print("Received compressed response, compression not supported\n", .{});
            return error.CompressionNotSupported;
        }

        // Read response body
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        if (length > response_buf.len - 5) {
            std.debug.print("Response too large: {}\n", .{length});
            return error.ResponseTooLarge;
        }

        std.debug.print("Reading response body of length {}...\n", .{length});
        readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s) catch |err| {
            std.debug.print("Failed to read response body: {}\n", .{err});
            return err;
        };

        const response = response_buf[5..][0..length];
        std.debug.print("Received response: {s}\n", .{response});

        testing.expect(std.mem.indexOf(u8, response, "\"result\":1") != null) catch |err| {
            std.debug.print("Response validation failed: {}\n", .{err});
            return err;
        };
        std.debug.print("First call successful\n", .{});
    }

    // Second call
    std.debug.print("\nMaking second call...\n", .{});
    {
        const stream = try std.net.tcpConnectToHost(test_ctx.allocator, "127.0.0.1", actual_port);
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
}

test "trpc over grpc - concurrent calls with debug" {
    std.debug.print("\n=== Starting concurrent calls test ===\n", .{});

    // Initialize test context
    var test_ctx = try TestContext.init(testing.allocator);
    defer test_ctx.deinit();

    global_counter.reset();

    // Configure and start server
    std.debug.print("Configuring server...\n", .{});
    try test_ctx.router.procedure("counter", counterHandler, null, null);

    std.debug.print("Starting server on port {}...\n", .{test_ctx.port});
    try test_ctx.router.listen(test_ctx.port);

    const server = test_ctx.router.server orelse {
        std.debug.print("Server not initialized\n", .{});
        return error.ServerNotInitialized;
    };

    const actual_port = server.socket.listen_address.getPort();
    std.debug.print("Server listening on port {}\n", .{actual_port});

    // Wait for server with timeout
    const server_timeout = 5 * std.time.ns_per_s;
    const server_start = std.time.nanoTimestamp();
    while (true) {
        waitForServer(test_ctx.allocator, actual_port) catch |err| {
            if (std.time.nanoTimestamp() - server_start > server_timeout) {
                std.debug.print("Server failed to start within timeout: {}\n", .{err});
                return err;
            }
            std.time.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        break;
    }
    std.debug.print("Server is ready\n", .{});

    // Prepare thread pool
    const num_threads = 3;
    var threads: [3]std.Thread = undefined;
    var errors = try test_ctx.allocator.alloc(?anyerror, num_threads);
    defer test_ctx.allocator.free(errors);
    for (errors) |*err| err.* = null;

    std.debug.print("\nSpawning {d} concurrent test threads\n", .{num_threads});

    // Spawn test threads
    for (0..num_threads) |i| {
        std.debug.print("Spawning thread {d}\n", .{i});
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn call(server_port: u16, error_slot: *?anyerror, thread_id: usize) !void {
                var thread_arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer thread_arena.deinit();
                const thread_allocator = thread_arena.allocator();

                std.debug.print("\nThread {d}: Starting\n", .{thread_id});

                // Connect with timeout
                const connect_timeout = 5 * std.time.ns_per_s;
                const connect_start = std.time.nanoTimestamp();
                var stream: std.net.Stream = while (true) {
                    if (std.time.nanoTimestamp() - connect_start > connect_timeout) {
                        std.debug.print("\nThread {d}: Connection timeout\n", .{thread_id});
                        error_slot.* = error.ConnectionTimeout;
                        return error.ConnectionTimeout;
                    }

                    break std.net.tcpConnectToHost(thread_allocator, "127.0.0.1", server_port) catch |err| {
                        std.debug.print("\nThread {d}: Connection attempt failed: {}\n", .{ thread_id, err });
                        std.time.sleep(100 * std.time.ns_per_ms);
                        continue;
                    };
                };
                defer {
                    std.debug.print("\nThread {d}: Closing connection\n", .{thread_id});
                    stream.close();
                }

                var request_buf: [1024]u8 = undefined;
                request_buf[0] = 0;

                const request_json =
                    \\{"id":"1","method":"counter","params":null}
                ;
                std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
                @memcpy(request_buf[5..][0..request_json.len], request_json);

                std.debug.print("\nThread {d}: Writing request\n", .{thread_id});
                stream.writeAll(request_buf[0 .. 5 + request_json.len]) catch |err| {
                    std.debug.print("\nThread {d}: Write error: {}\n", .{ thread_id, err });
                    error_slot.* = err;
                    return error.WriteFailed;
                };

                var response_buf: [1024]u8 = undefined;
                std.debug.print("\nThread {d}: Reading response header\n", .{thread_id});
                readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s) catch |err| {
                    std.debug.print("\nThread {d}: Read header error: {}\n", .{ thread_id, err });
                    error_slot.* = err;
                    return error.ReadHeaderFailed;
                };

                const length = std.mem.readInt(u32, response_buf[1..5], .big);
                std.debug.print("\nThread {d}: Reading response body of length {d}\n", .{ thread_id, length });

                readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s) catch |err| {
                    std.debug.print("\nThread {d}: Read body error: {}\n", .{ thread_id, err });
                    error_slot.* = err;
                    return error.ReadBodyFailed;
                };

                std.debug.print("\nThread {d}: Complete\n", .{thread_id});
                std.time.sleep(10 * std.time.ns_per_ms); // Small delay before closing connection
            }
        }.call, .{ actual_port, &errors[i], i });
    }

    // Wait for all threads and check errors with debug logging
    std.debug.print("\n=== Waiting for threads to complete ===\n", .{});
    for (threads, 0..) |thread, i| {
        std.debug.print("\nJoining thread {d}...\n", .{i});
        thread.join();
        if (errors[i]) |e| {
            std.debug.print("\nThread {d} failed with error: {}\n", .{ i, e });
            return e;
        }
        std.debug.print("\nThread {d} completed successfully\n", .{i});
    }

    std.debug.print("\n=== All threads completed successfully ===\n", .{});

    // Verify counter
    {
        std.debug.print("\nVerifying final counter value...\n", .{});
        const stream = try std.net.tcpConnectToHost(test_ctx.allocator, "127.0.0.1", actual_port);
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

    // Initialize test context
    var test_ctx = try TestContext.init(testing.allocator);
    defer test_ctx.deinit();

    var input_props = std.StringHashMap(Schema).init(test_ctx.allocator);
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

    var output_props = std.StringHashMap(Schema).init(test_ctx.allocator);
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

    try test_ctx.router.procedure("validate", validateHandler, input_schema, output_schema);

    // Start server
    std.debug.print("Starting server...\n", .{});
    try test_ctx.router.listen(test_ctx.port);

    const server = test_ctx.router.server orelse {
        std.debug.print("Server not initialized\n", .{});
        return error.ServerNotInitialized;
    };

    const actual_port = server.socket.listen_address.getPort();
    std.debug.print("Server listening on port {}\n", .{actual_port});

    // Wait for server with timeout
    const server_timeout = 5 * std.time.ns_per_s;
    const server_start = std.time.nanoTimestamp();
    while (true) {
        waitForServer(test_ctx.allocator, actual_port) catch |err| {
            if (std.time.nanoTimestamp() - server_start > server_timeout) {
                std.debug.print("Server failed to start within timeout: {}\n", .{err});
                return err;
            }
            std.time.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        break;
    }
    std.debug.print("Server is ready\n", .{});

    // Valid request
    {
        std.debug.print("\nTesting valid request...\n", .{});
        const stream = try std.net.tcpConnectToHost(test_ctx.allocator, "127.0.0.1", actual_port);
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
        const stream = try std.net.tcpConnectToHost(test_ctx.allocator, "127.0.0.1", actual_port);
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
        const stream = try std.net.tcpConnectToHost(test_ctx.allocator, "127.0.0.1", actual_port);
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

    // Initialize test context
    var test_ctx = try TestContext.init(testing.allocator);
    defer test_ctx.deinit();

    try test_ctx.router.procedure("echo", echoHandler, null, null);

    // Start server
    std.debug.print("Starting server...\n", .{});
    try test_ctx.router.listen(test_ctx.port);

    const server = test_ctx.router.server orelse {
        std.debug.print("Server not initialized\n", .{});
        return error.ServerNotInitialized;
    };

    const actual_port = server.socket.listen_address.getPort();
    std.debug.print("Server listening on port {}\n", .{actual_port});

    // Wait for server with timeout
    const server_timeout = 5 * std.time.ns_per_s;
    const server_start = std.time.nanoTimestamp();
    while (true) {
        waitForServer(test_ctx.allocator, actual_port) catch |err| {
            if (std.time.nanoTimestamp() - server_start > server_timeout) {
                std.debug.print("Server failed to start within timeout: {}\n", .{err});
                return err;
            }
            std.time.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        break;
    }
    std.debug.print("Server is ready\n", .{});

    // Invalid gRPC frame - too short
    {
        std.debug.print("\nTesting short frame...\n", .{});
        const stream = try std.net.tcpConnectToHost(test_ctx.allocator, "127.0.0.1", actual_port);
        defer stream.close();

        var request_buf: [4]u8 = undefined;
        try stream.writeAll(&request_buf);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"error\":{\"code\":3,\"message\":\"Invalid gRPC frame: incomplete header\"}") != null);
        std.debug.print("Short frame test successful\n", .{});
    }

    // Invalid JSON
    {
        std.debug.print("\nTesting invalid JSON...\n", .{});
        const stream = try std.net.tcpConnectToHost(test_ctx.allocator, "127.0.0.1", actual_port);
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

        try testing.expect(std.mem.indexOf(u8, response, "\"error\":{\"code\":3,\"message\":\"Invalid JSON request: malformed JSON data\"}") != null);
        std.debug.print("Invalid JSON test successful\n", .{});
    }

    // Missing method
    {
        std.debug.print("\nTesting missing method...\n", .{});
        const stream = try std.net.tcpConnectToHost(test_ctx.allocator, "127.0.0.1", actual_port);
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

        try testing.expect(std.mem.indexOf(u8, response, "\"error\":{\"code\":3,\"message\":\"Missing method field in request\"}") != null);
        std.debug.print("Missing method test successful\n", .{});
    }

    // Invalid method type
    {
        std.debug.print("\nTesting invalid method type...\n", .{});
        const stream = try std.net.tcpConnectToHost(test_ctx.allocator, "127.0.0.1", actual_port);
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

        try testing.expect(std.mem.indexOf(u8, response, "\"error\":{\"code\":3,\"message\":\"Invalid method type: expected string\"}") != null);
        std.debug.print("Invalid method type test successful\n", .{});
    }

    // Unknown method
    {
        std.debug.print("\nTesting unknown method...\n", .{});
        const stream = try std.net.tcpConnectToHost(test_ctx.allocator, "127.0.0.1", actual_port);
        defer stream.close();

        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0;

        const request_json =
            \\{"id":"1","method":"unknown","params":null}
        ;
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_json.len), .big);
        @memcpy(request_buf[5..][0..request_json.len], request_json);

        try stream.writeAll(request_buf[0 .. 5 + request_json.len]);

        var response_buf: [1024]u8 = undefined;
        try readExactly(stream, response_buf[0..5], 5 * std.time.ns_per_s);
        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        try readExactly(stream, response_buf[5..][0..length], 5 * std.time.ns_per_s);
        const response = response_buf[5..][0..length];

        try testing.expect(std.mem.indexOf(u8, response, "\"error\":{\"code\":3,\"message\":\"Method not found: unknown\"}") != null);
        std.debug.print("Unknown method test successful\n", .{});
    }

    std.debug.print("=== Error handling test complete ===\n", .{});
}
