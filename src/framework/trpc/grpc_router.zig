const std = @import("std");
const build_options = @import("build_options");
const log = std.log.scoped(.grpc_router);
const json = std.json;
const core = @import("core");
const Schema = @import("schema").Schema;
const validateSchema = @import("schema").validateSchema;
const RuntimeRouter = @import("runtime_router").RuntimeRouter;
const Server = @import("framework").Server;
const os = std.os;

const READ_TIMEOUT_NS = 5 * std.time.ns_per_s;

pub const GrpcRouter = struct {
    allocator: std.mem.Allocator,
    runtime_router: RuntimeRouter,
    server: ?*GrpcServer = null,
    router_ctx: ?*RouterContext = null,

    const Self = @This();

    const RouterContext = struct {
        router: *Self,

        pub fn handle(ctx: *core.Context) anyerror!void {
            const router_ctx = @as(*RouterContext, @ptrCast(@alignCast(ctx.data.?)));
            try router_ctx.router.runtime_router.handleRequest(ctx);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .runtime_router = RuntimeRouter.init(allocator),
            .router_ctx = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.server) |server| {
            // Signal shutdown with release ordering
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
                    // Don't call deinit here since it's already called in the thread's defer block
                    self.allocator.destroy(thread_ctx);
                }
                server.thread_pool.deinit();
            }

            server.deinit();
            self.allocator.destroy(server);
            self.server = null;
        }

        // Clean up router context if it exists
        if (self.router_ctx) |ctx| {
            self.allocator.destroy(ctx);
            self.router_ctx = null;
        }

        self.runtime_router.deinit();
    }

    pub fn shutdown(self: *Self) void {
        if (self.server) |server| {
            // Signal shutdown to prevent new connections
            server.running.store(false, .release);

            // Close all active connections to unblock any reads/writes
            {
                server.mutex.lock();
                defer server.mutex.unlock();
                for (server.thread_pool.items) |thread_ctx| {
                    thread_ctx.closeConnection();
                }
            }

            // Socket will be closed in deinit
        }
    }

    pub fn mount(self: *Self, server: *Server) !void {
        // Create router context
        const router_ctx = try self.allocator.create(RouterContext);
        router_ctx.* = .{ .router = self };
        self.router_ctx = router_ctx;

        // Mount the router
        try server.post("/trpc/:procedure", RouterContext.handle, router_ctx);
    }

    pub fn procedure(
        self: *Self,
        name: []const u8,
        handler: *const fn (*core.Context, ?json.Value) anyerror!json.Value,
        _: ?Schema,  // input_schema
        _: ?Schema,  // output_schema
    ) !void {
        // Pass handler directly to runtime router
        try self.runtime_router.procedure(name, null, null, handler);
    }

    pub const GrpcServer = struct {
        allocator: std.mem.Allocator,
        socket: std.net.Server,
        router: *GrpcRouter,
        running: std.atomic.Value(bool),
        server_thread: ?std.Thread = null,
        thread_pool: std.ArrayList(*ThreadContext),
        mutex: std.Thread.Mutex,

        pub const ThreadContext = struct {
            thread: std.Thread,
            done: std.atomic.Value(bool),
            connection: ?std.net.Server.Connection = null,
            is_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            allocator: std.mem.Allocator,
            arena: std.heap.ArenaAllocator,

            fn init(base_allocator: std.mem.Allocator) !ThreadContext {
                var arena = std.heap.ArenaAllocator.init(base_allocator);
                errdefer arena.deinit();

                return ThreadContext{
                    .thread = undefined, // Will be set after creation
                    .done = std.atomic.Value(bool).init(false),
                    .allocator = base_allocator,
                    .arena = arena,
                };
            }

            fn deinit(self: *ThreadContext) void {
                if (self.connection != null) {
                    self.closeConnection();
                }
                self.arena.deinit();
            }

            pub fn closeConnection(self: *ThreadContext) void {
                if (self.connection) |*conn| {
                    if (!self.is_closed.swap(true, .acq_rel)) {
                        conn.stream.close();
                    }
                    self.connection = null;
                }
            }
        };

        pub fn init(allocator: std.mem.Allocator, router: *GrpcRouter, port: u16) !*GrpcServer {
            const server = try allocator.create(GrpcServer);
            errdefer allocator.destroy(server);

            const address = try std.net.Address.parseIp("127.0.0.1", port);
            const socket = try address.listen(.{
                .reuse_address = true,
                .kernel_backlog = 10,
            });
            const flags = try std.posix.fcntl(socket.stream.handle, std.posix.F.GETFL, 0);
            _ = try std.posix.fcntl(socket.stream.handle, std.posix.F.SETFL, flags | std.posix.SOCK.NONBLOCK);

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
            std.log.debug("Starting server shutdown...", .{});
            // Signal shutdown and wait for server thread
            self.running.store(false, .release);
            if (self.server_thread) |thread| {
                std.log.debug("Waiting for server thread to complete...", .{});
                thread.join();
                std.log.debug("Server thread completed", .{});
            }

            // Clean up thread pool first
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                // First signal all threads to stop and close connections
                for (self.thread_pool.items) |thread_ctx| {
                    thread_ctx.done.store(true, .release);
                    thread_ctx.closeConnection();
                }

                // Then wait for threads to complete with timeout
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
                    // Thread context cleanup is handled by the thread's defer block
                    self.allocator.destroy(thread_ctx);
                }
                self.thread_pool.deinit();
            }

            // Only after all threads are cleaned up, close the socket
            std.log.debug("All threads cleaned up, closing socket...", .{});
            self.socket.deinit();
            std.log.debug("Socket closed", .{});
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
                if (stream.handle == -1) {
                    return error.ConnectionClosed;
                }

                const current_time = std.time.nanoTimestamp();
                if (current_time - read_start_time > READ_TIMEOUT_NS) {
                    return error.Timeout;
                }

                const bytes_read = stream.read(buf[total_read..]) catch |err| {
                    if (err == error.EndOfStream or err == error.ConnectionResetByPeer) {
                        if (buf.len == 5 and total_read > 0) {
                            return total_read;
                        }
                        return if (total_read == 0) error.ConnectionResetByPeer else error.UnexpectedEof;
                    }
                    if (err == error.WouldBlock or err == error.WouldBlockNonBlocking) {
                        std.time.sleep(1 * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };

                if (bytes_read == 0) {
                    if (buf.len == 5 and total_read > 0) {
                        return total_read;
                    }
                    return if (total_read == 0) error.ConnectionResetByPeer else error.UnexpectedEof;
                }

                total_read += bytes_read;
            }
            return total_read;
        }

        fn validateInput(_: *GrpcServer, _: []const u8, _: ?json.Value) !void {}
        fn validateOutput(_: *GrpcServer, _: []const u8, _: json.Value) !void {}

        fn cleanupThreads(self: *GrpcServer) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var i: usize = 0;
            while (i < self.thread_pool.items.len) {
                const thread_ctx = self.thread_pool.items[i];
                if (thread_ctx.done.load(.acquire)) {
                    // Thread cleanup is handled by the thread's defer block
                    // Just remove it from the pool
                    _ = self.thread_pool.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        fn handleConnection(self: *GrpcServer, conn: std.net.Server.Connection, thread_arena: *std.heap.ArenaAllocator) !void {
            const conn_allocator = thread_arena.allocator();

            var buf = std.ArrayList(u8).init(conn_allocator);
            defer buf.deinit();

            try buf.resize(5);
            const header_size = readFromStream(conn.stream, buf.items[0..5]) catch |err| {
                switch (err) {
                    error.Timeout => try self.writeErrorResponse(conn, GrpcStatus.DeadlineExceeded, "Request timed out"),
                    error.UnexpectedEof => try self.writeErrorResponse(conn, GrpcStatus.InvalidArgument, "Incomplete request: connection closed before receiving complete data"),
                    else => try self.writeErrorResponse(conn, GrpcStatus.Internal, "Failed to read request"),
                }
                return;
            };

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
            _ = readFromStream(conn.stream, buf.items[5..]) catch |err| {
                switch (err) {
                    error.Timeout => try self.writeErrorResponse(conn, GrpcStatus.DeadlineExceeded, "Request timed out while reading message body"),
                    error.UnexpectedEof => try self.writeErrorResponse(conn, GrpcStatus.InvalidArgument, "Incomplete request: connection closed before receiving complete message"),
                    else => try self.writeErrorResponse(conn, GrpcStatus.Internal, "Failed to read message body"),
                }
                return;
            };
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
            self.server_thread = try std.Thread.spawn(.{}, struct {
                fn run(self_inner: *GrpcServer) !void {
                    std.log.debug("Server thread starting on port {}", .{self_inner.socket.listen_address.getPort()});
                    while (self_inner.running.load(.acquire)) {
                        // Try to accept with timeout
                        std.log.debug("Waiting for connection on port {}...", .{self_inner.socket.listen_address.getPort()});

                        // Accept connections in non-blocking mode
                        const conn = self_inner.socket.accept() catch |err| {
                            switch (err) {
                                error.WouldBlock => {
                                    // Check running flag before sleeping
                                    if (!self_inner.running.load(.acquire)) {
                                        std.log.debug("Server shutting down, stopping accept loop", .{});
                                        return;
                                    }
                                    // No connection available, sleep and continue
                                    std.time.sleep(10 * std.time.ns_per_ms);
                                    continue;
                                },
                                error.ConnectionAborted, error.ConnectionResetByPeer, error.FileDescriptorNotASocket, error.SocketNotListening => {
                                    if (!self_inner.running.load(.acquire)) {
                                        std.log.debug("Server shutting down, stopping accept loop", .{});
                                        return;
                                    }
                                    std.log.debug("Recoverable accept error: {}", .{err});
                                    std.time.sleep(10 * std.time.ns_per_ms);
                                    continue;
                                },
                                else => {
                                    if (!self_inner.running.load(.acquire)) {
                                        std.log.debug("Server shutting down, stopping accept loop", .{});
                                        return;
                                    }
                                    std.log.err("Critical accept error: {}", .{err});
                                    std.time.sleep(100 * std.time.ns_per_ms);
                                    continue;
                                },
                            }
                        };

                        // Check if we should stop after accepting
                        if (!self_inner.running.load(.acquire)) {
                            conn.stream.close();
                            return;
                        }

                        self_inner.cleanupThreads();

                        // Create and initialize thread context before spawning thread
                        var thread_ctx = self_inner.allocator.create(ThreadContext) catch |err| {
                            std.log.err("Failed to create thread context: {}", .{err});
                            conn.stream.close();
                            continue;
                        };
                        errdefer self_inner.allocator.destroy(thread_ctx);

                        thread_ctx.* = ThreadContext.init(self_inner.allocator) catch |err| {
                            std.log.err("Failed to initialize thread context: {}", .{err});
                            self_inner.allocator.destroy(thread_ctx);
                            conn.stream.close();
                            continue;
                        };

                        // Add to thread pool before spawning thread to ensure proper cleanup
                        self_inner.mutex.lock();
                        self_inner.thread_pool.append(thread_ctx) catch |err| {
                            std.log.err("Failed to append thread context: {}", .{err});
                            thread_ctx.deinit();
                            self_inner.allocator.destroy(thread_ctx);
                            conn.stream.close();
                            self_inner.mutex.unlock();
                            continue;
                        };
                        self_inner.mutex.unlock();

                        if (self_inner.running.load(.acquire)) {
                            thread_ctx.thread = std.Thread.spawn(.{}, struct {
                                fn handle(server_ctx: *GrpcServer, connection: std.net.Server.Connection, ctx: *ThreadContext) !void {
                                    ctx.connection = connection;
                                    ctx.is_closed.store(false, .release);
                                    defer {
                                        ctx.done.store(true, .release);
                                        ctx.deinit();
                                    }
                                    try server_ctx.handleConnection(connection, &ctx.arena);
                                }
                            }.handle, .{ self_inner, conn, thread_ctx }) catch |err| {
                                std.log.err("Failed to spawn thread: {}", .{err});
                                thread_ctx.done.store(true, .release);
                                conn.stream.close();
                                continue;
                            };
                        } else {
                            thread_ctx.done.store(true, .release);
                            conn.stream.close();
                        }
                    }
                }
            }.run, .{self});
        }
    };

    pub fn listen(self: *Self, port: u16) !void {
        if (self.server != null) return error.AlreadyListening;

        self.server = GrpcServer.init(self.allocator, self, port) catch |err| {
            std.log.err("Failed to initialize server on port {d}: {}", .{ port, err });
            if (err == error.AddressInUse) {
                return error.PortInUse;
            }
            return err;
        };

        self.server.?.start() catch |err| {
            std.log.err("Failed to start server: {}", .{err});
            const server = self.server.?;
            self.server = null;
            server.deinit();
            return err;
        };
    }
};
