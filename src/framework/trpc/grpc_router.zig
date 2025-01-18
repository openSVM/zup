const std = @import("std");
const json = std.json;
const core = @import("core");
const schema = @import("schema");
const Schema = schema.Schema;
const validateSchema = schema.validateSchema;
const RuntimeRouter = @import("runtime_router").RuntimeRouter;

pub const GrpcRouter = struct {
    allocator: std.mem.Allocator,
    runtime_router: RuntimeRouter,
    server: ?*GrpcServer = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .runtime_router = RuntimeRouter.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.server) |server| {
            // Signal shutdown
            server.running.store(false, .release);

            // Close all active connections
            {
                server.mutex.lock();
                defer server.mutex.unlock();
                for (server.thread_pool.items) |thread_ctx| {
                    thread_ctx.closeConnection();
                }
            }

            // Wait for server thread to complete
            if (server.server_thread) |thread| {
                thread.join();
            }

            // Close socket after server thread is done
            server.socket.deinit();

            // Clean up thread pool
            {
                server.mutex.lock();
                defer server.mutex.unlock();

                // First signal all threads to stop
                for (server.thread_pool.items) |thread_ctx| {
                    thread_ctx.done.store(true, .release);
                }

                // Then close all connections to unblock any reads/writes
                for (server.thread_pool.items) |thread_ctx| {
                    thread_ctx.closeConnection();
                }

                // Finally join all threads with timeout
                const shutdown_start = std.time.nanoTimestamp();
                for (server.thread_pool.items) |thread_ctx| {
                    while (!thread_ctx.done.load(.acquire)) {
                        if (std.time.nanoTimestamp() - shutdown_start > 5 * std.time.ns_per_s) {
                            std.log.err("Thread join timeout", .{});
                            break;
                        }
                        std.time.sleep(1 * std.time.ns_per_ms);
                    }
                    thread_ctx.thread.join();
                    self.allocator.destroy(thread_ctx);
                }
                server.thread_pool.deinit();
            }

            self.allocator.destroy(server.socket);
            self.allocator.destroy(server);
            self.server = null;
        }
        self.runtime_router.deinit();
    }

    pub fn shutdown(self: *Self) void {
        if (self.server) |server| {
            // First signal shutdown to prevent new connections
            server.running.store(false, .release);

            // Close all active connections to unblock any reads/writes
            {
                server.mutex.lock();
                defer server.mutex.unlock();
                for (server.thread_pool.items) |thread_ctx| {
                    thread_ctx.closeConnection();
                }
            }

            // Now close the socket to interrupt accept()
            server.socket.deinit();

            // Wait for server thread to complete
            if (server.server_thread) |thread| {
                thread.join();
            }

            // Finally clean up thread pool
            {
                server.mutex.lock();
                defer server.mutex.unlock();

                // Join all worker threads with timeout
                const shutdown_start = std.time.nanoTimestamp();
                for (server.thread_pool.items) |thread_ctx| {
                    while (!thread_ctx.done.load(.acquire)) {
                        if (std.time.nanoTimestamp() - shutdown_start > 5 * std.time.ns_per_s) {
                            std.log.err("Thread join timeout", .{});
                            break;
                        }
                        std.time.sleep(1 * std.time.ns_per_ms);
                    }
                    thread_ctx.thread.join();
                }
            }
        }
    }

    pub fn procedure(
        self: *Self,
        name: []const u8,
        handler: *const fn (*core.Context, ?json.Value) anyerror!json.Value,
        input_schema: ?Schema,
        output_schema: ?Schema,
    ) !void {
        try self.runtime_router.procedure(name, handler, input_schema, output_schema);
    }

    const GrpcServer = struct {
        allocator: std.mem.Allocator,
        router: *GrpcRouter,
        socket: *std.net.Server,
        running: std.atomic.Value(bool),
        thread_pool: std.ArrayList(*ThreadContext),
        mutex: std.Thread.Mutex,
        server_thread: ?std.Thread = null,

        const ThreadContext = struct {
            thread: std.Thread,
            done: std.atomic.Value(bool),
            connection: ?std.net.Server.Connection,

            fn init(thread: std.Thread) ThreadContext {
                return .{
                    .thread = thread,
                    .done = std.atomic.Value(bool).init(false),
                    .connection = null,
                };
            }

            fn closeConnection(self: *ThreadContext) void {
                if (self.connection) |*conn| {
                    conn.stream.close();
                    self.connection = null;
                }
            }
        };

        const READ_TIMEOUT_NS = 5 * std.time.ns_per_s; // 5 second timeout

        pub fn init(allocator: std.mem.Allocator, router: *GrpcRouter, port: u16) !*GrpcServer {
            const server = try allocator.create(GrpcServer);
            errdefer allocator.destroy(server);

            const address = try std.net.Address.parseIp("127.0.0.1", port);
            var socket = try allocator.create(std.net.Server);
            errdefer allocator.destroy(socket);

            socket.* = try address.listen(.{
                .reuse_address = true,
                .kernel_backlog = 10,
            });
            errdefer socket.deinit();

            server.* = .{
                .allocator = allocator,
                .router = router,
                .socket = socket,
                .running = std.atomic.Value(bool).init(true),
                .thread_pool = std.ArrayList(*ThreadContext).init(allocator),
                .mutex = .{},
            };

            return server;
        }

        pub fn deinit(self: *GrpcServer) void {
            // Signal shutdown
            self.running.store(false, .release);

            // Close all active connections
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                for (self.thread_pool.items) |thread_ctx| {
                    thread_ctx.closeConnection();
                }
            }

            // Wait for server thread to complete
            if (self.server_thread) |thread| {
                thread.join();
            }

            // Close socket after server thread is done
            self.socket.deinit();

            // Clean up thread pool with improved shutdown
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                // First signal all threads to stop
                for (self.thread_pool.items) |thread_ctx| {
                    thread_ctx.done.store(true, .release);
                }

                // Then close all connections to unblock any reads/writes
                for (self.thread_pool.items) |thread_ctx| {
                    thread_ctx.closeConnection();
                }

                // Finally join all threads with a timeout
                const shutdown_start = std.time.nanoTimestamp();
                for (self.thread_pool.items) |thread_ctx| {
                    while (!thread_ctx.done.load(.acquire)) {
                        if (std.time.nanoTimestamp() - shutdown_start > READ_TIMEOUT_NS) {
                            std.log.err("Thread join timeout", .{});
                            break;
                        }
                        std.time.sleep(1 * std.time.ns_per_ms);
                    }
                    thread_ctx.thread.join();
                    self.allocator.destroy(thread_ctx);
                }
                self.thread_pool.deinit();
            }

            self.allocator.destroy(self.socket);
        }

        const GrpcStatus = struct {
            const Ok = 0;
            const InvalidArgument = 3;
            const Internal = 13;
            const Unimplemented = 12;
            const InvalidContent = 9;
            const DeadlineExceeded = 4;
        };

        fn writeErrorResponse(self: *GrpcServer, conn: std.net.Server.Connection, status: i32, message: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const temp_allocator = arena.allocator();

            var response_json = std.ArrayList(u8).init(temp_allocator);
            defer response_json.deinit();

            var writer = response_json.writer();
            try writer.writeAll("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":");
            try std.fmt.format(writer, "{d},\"message\":", .{status});
            try json.stringify(message, .{}, writer);
            try writer.writeAll("}}");

            var buf = std.ArrayList(u8).init(temp_allocator);
            defer buf.deinit();

            try buf.resize(5);
            buf.items[0] = 0;
            const response_data = response_json.items;
            std.mem.writeInt(u32, buf.items[1..5], @intCast(response_data.len), .big);
            try buf.appendSlice(response_data);

            try conn.stream.writeAll(buf.items);
        }

        fn readFromStream(stream: std.net.Stream, buf: []u8) !usize {
            const read_start_time = std.time.nanoTimestamp();
            var total_read: usize = 0;

            while (total_read < buf.len) {
                // Check if shutdown was requested
                if (stream.handle == -1) {
                    return error.ConnectionClosed;
                }

                const current_time = std.time.nanoTimestamp();
                if (current_time - read_start_time > READ_TIMEOUT_NS) {
                    return error.Timeout;
                }

                const bytes_read = stream.read(buf[total_read..]) catch |err| {
                    if (err == error.EndOfStream or err == error.ConnectionResetByPeer) {
                        if (total_read == 0) {
                            return error.ConnectionResetByPeer;
                        }
                        return total_read;
                    }
                    if (err == error.WouldBlock or err == error.WouldBlockNonBlocking) {
                        std.time.sleep(1 * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };
                if (bytes_read == 0) {
                    if (total_read == 0) {
                        return error.ConnectionResetByPeer;
                    }
                    return total_read;
                }
                total_read += bytes_read;
            }
            return total_read;
        }

        fn validateInput(self: *GrpcServer, procedure_name: []const u8, input: ?json.Value) !void {
            if (self.router.runtime_router.input_schemas.get(procedure_name)) |input_schema| {
                if (input == null) {
                    return error.InvalidInput;
                }
                try validateSchema(input.?, &input_schema);
            }
        }

        fn validateOutput(self: *GrpcServer, procedure_name: []const u8, output: json.Value) !void {
            if (self.router.runtime_router.output_schemas.get(procedure_name)) |output_schema| {
                try validateSchema(output, &output_schema);
            }
        }

        fn cleanupThreads(self: *GrpcServer) void {
            var to_cleanup = std.ArrayList(*ThreadContext).init(self.allocator);
            defer to_cleanup.deinit();

            // First pass: identify completed threads under mutex
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                var i: usize = 0;
                while (i < self.thread_pool.items.len) {
                    const thread_ctx = self.thread_pool.items[i];
                    if (thread_ctx.done.load(.acquire)) {
                        to_cleanup.append(thread_ctx) catch break;
                        _ = self.thread_pool.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }

            // Second pass: cleanup threads outside mutex
            for (to_cleanup.items) |thread_ctx| {
                thread_ctx.thread.join();
                self.allocator.destroy(thread_ctx);
            }
        }

        fn handleConnection(self: *GrpcServer, conn: std.net.Server.Connection) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const conn_allocator = arena.allocator();

            var buf = std.ArrayList(u8).init(conn_allocator);
            defer buf.deinit();

            try buf.resize(5);
            _ = readFromStream(conn.stream, buf.items[0..5]) catch |err| {
                switch (err) {
                    error.Timeout => try self.writeErrorResponse(conn, GrpcStatus.DeadlineExceeded, "Request timed out"),
                    else => try self.writeErrorResponse(conn, GrpcStatus.Internal, "Failed to read request"),
                }
                return;
            };

            const header_size = try readFromStream(conn.stream, buf.items[0..5]);
            if (header_size == 0) return;

            if (header_size < 5) {
                try self.writeErrorResponse(conn, GrpcStatus.InvalidArgument, "Invalid gRPC frame: incomplete header");
                return;
            }

            const compressed = buf.items[0] == 1;
            const length = std.mem.readInt(u32, buf.items[1..5], .big);

            if (length > 1024 * 1024 * 10) {
                try self.writeErrorResponse(conn, GrpcStatus.InvalidArgument, "Message too large: exceeds 10MB limit");
                return;
            }

            try buf.resize(5 + length);
            _ = try readFromStream(conn.stream, buf.items[5..]);
            const message = buf.items[5..];
            if (compressed) {
                try self.writeErrorResponse(conn, GrpcStatus.Unimplemented, "Compression not supported: please send uncompressed data");
                return;
            }

            const parsed = json.parseFromSlice(json.Value, conn_allocator, message, .{}) catch {
                try self.writeErrorResponse(conn, GrpcStatus.InvalidArgument, "Invalid JSON request: malformed JSON data");
                return;
            };
            defer parsed.deinit();

            const procedure_name = if (parsed.value.object.get("method")) |method| blk: {
                if (method == .string) {
                    break :blk method.string;
                }
                try self.writeErrorResponse(conn, GrpcStatus.InvalidArgument, "Invalid method type: expected string");
                return;
            } else {
                try self.writeErrorResponse(conn, GrpcStatus.InvalidArgument, "Missing method field in request");
                return;
            };

            const params = parsed.value.object.get("params");
            self.validateInput(procedure_name, params) catch |err| {
                const msg = switch (err) {
                    error.InvalidInput => "Missing required input parameters for procedure",
                    error.InvalidType => try std.fmt.allocPrint(conn_allocator, "Invalid parameter type for procedure '{s}'", .{procedure_name}),
                    error.MissingRequiredProperty => try std.fmt.allocPrint(conn_allocator, "Missing required property in parameters for procedure '{s}'", .{procedure_name}),
                };
                try self.writeErrorResponse(conn, GrpcStatus.InvalidContent, msg);
                return;
            };

            var request = core.Request.init(conn_allocator);
            defer request.deinit();

            request.method = .POST;
            request.path = try std.fmt.allocPrint(conn_allocator, "/trpc/{s}", .{procedure_name});
            request.body = try core.Request.allocBody(conn_allocator, message);

            var response = core.Response.init(conn_allocator);
            defer response.deinit();

            var ctx = core.Context.init(conn_allocator, &request, &response);
            try ctx.params.put(
                try conn_allocator.dupe(u8, "procedure"),
                try conn_allocator.dupe(u8, procedure_name),
            );
            defer ctx.deinit();

            self.router.runtime_router.handleRequest(&ctx) catch |err| {
                const msg = switch (err) {
                    error.InvalidInput => "Invalid input parameters",
                    error.InvalidType => "Invalid parameter type",
                    error.MissingRequiredProperty => "Missing required property",
                    else => "Internal server error",
                };
                try self.writeErrorResponse(conn, GrpcStatus.Internal, msg);
                return;
            };

            if (response.status >= 200 and response.status < 300) {
                var result = json.parseFromSlice(json.Value, conn_allocator, response.body, .{}) catch {
                    try self.writeErrorResponse(conn, GrpcStatus.Internal, "Invalid response format: malformed JSON");
                    return;
                };
                defer result.deinit();

                self.validateOutput(procedure_name, result.value) catch |err| {
                    const msg = switch (err) {
                        error.InvalidType => try std.fmt.allocPrint(conn_allocator, "Invalid response type from procedure '{s}'", .{procedure_name}),
                        error.MissingRequiredProperty => try std.fmt.allocPrint(conn_allocator, "Missing required property in response from procedure '{s}'", .{procedure_name}),
                    };
                    try self.writeErrorResponse(conn, GrpcStatus.Internal, msg);
                    return;
                };
            }

            var response_json = std.ArrayList(u8).init(conn_allocator);
            defer response_json.deinit();

            var writer = response_json.writer();
            try writer.writeAll("{\"jsonrpc\":\"2.0\",");

            if (parsed.value.object.get("id")) |id| {
                if (id == .string) {
                    const id_str = try std.fmt.allocPrint(conn_allocator, "\"{s}\"", .{id.string});
                    defer conn_allocator.free(id_str);
                    try std.fmt.format(writer, "\"id\":{s},", .{id_str});
                } else {
                    const id_str = try std.fmt.allocPrint(conn_allocator, "{d}", .{id.integer});
                    defer conn_allocator.free(id_str);
                    try std.fmt.format(writer, "\"id\":{s},", .{id_str});
                }
            }

            if (response.status >= 200 and response.status < 300) {
                try writer.writeAll("\"result\":");
                try writer.writeAll(response.body);
                try writer.writeByte('}');
            } else {
                try std.fmt.format(writer, "\"error\":{{\"code\":{d},\"message\":", .{response.status});
                try json.stringify(response.body, .{}, writer);
                try writer.writeAll("}}");
            }

            try buf.resize(5);
            buf.items[0] = 0;
            const response_data = response_json.items;
            std.mem.writeInt(u32, buf.items[1..5], @intCast(response_data.len), .big);
            try buf.appendSlice(response_data);

            try conn.stream.writeAll(buf.items);
        }

        pub fn start(self: *GrpcServer) !void {
            const server = self;
            self.server_thread = try std.Thread.spawn(.{}, struct {
                fn run(server_inner: *GrpcServer) !void {
                    while (server_inner.running.load(.acquire)) {
                        // Check running state before accept
                        if (!server_inner.running.load(.acquire)) break;

                        const conn = server_inner.socket.accept() catch |err| {
                            switch (err) {
                                error.ConnectionAborted, error.ConnectionResetByPeer => {
                                    if (!server_inner.running.load(.acquire)) break;
                                    continue;
                                },
                                else => {
                                    if (!server_inner.running.load(.acquire)) break;
                                    std.log.err("Accept error: {}", .{err});
                                    std.time.sleep(10 * std.time.ns_per_ms); // Backoff on error
                                    continue;
                                },
                            }
                        };

                        // Check running state after accept
                        if (!server_inner.running.load(.acquire)) {
                            conn.stream.close();
                            break;
                        }

                        // Check running state before cleanup
                        if (!server_inner.running.load(.acquire)) {
                            conn.stream.close();
                            break;
                        }

                        server_inner.cleanupThreads();

                        const thread_ctx = server_inner.allocator.create(ThreadContext) catch |err| {
                            std.log.err("Failed to create thread context: {}", .{err});
                            conn.stream.close();
                            continue;
                        };
                        errdefer server_inner.allocator.destroy(thread_ctx);

                        thread_ctx.* = ThreadContext.init(std.Thread.spawn(.{}, struct {
                            fn handle(server_ctx: *GrpcServer, connection: std.net.Server.Connection, ctx: *ThreadContext) !void {
                                ctx.connection = connection;
                                defer {
                                    ctx.done.store(true, .release);
                                    connection.stream.close();
                                }
                                try server_ctx.handleConnection(connection);
                            }
                        }.handle, .{ server_inner, conn, thread_ctx }) catch |err| {
                            std.log.err("Failed to spawn thread: {}", .{err});
                            conn.stream.close();
                            server_inner.allocator.destroy(thread_ctx);
                            continue;
                        });

                        server_inner.mutex.lock();
                        server_inner.thread_pool.append(thread_ctx) catch |err| {
                            std.log.err("Failed to append thread context: {}", .{err});
                            thread_ctx.thread.detach();
                            server_inner.allocator.destroy(thread_ctx);
                            conn.stream.close();
                            server_inner.mutex.unlock();
                            continue;
                        };
                        server_inner.mutex.unlock();
                    }
                }
            }.run, .{server});
        }
    };

    pub fn listen(self: *Self, port: u16) !void {
        if (self.server != null) return error.AlreadyListening;

        self.server = try GrpcServer.init(self.allocator, self, port);
        try self.server.?.start();
    }
};
