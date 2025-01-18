const std = @import("std");
const net = std.net;
const mem = std.mem;
const core = @import("core");
const Allocator = mem.Allocator;

pub const ServerConfig = struct {
    port: u16 = 8080,
    host: []const u8 = "127.0.0.1",
    thread_count: usize = 4,
};

pub const Server = struct {
    const Self = @This();
    const ThreadPool = std.ArrayList(*std.Thread);

    allocator: Allocator,
    socket: net.Server,
    routes: std.StringHashMap(core.Handler),
    running: std.atomic.Value(bool),
    config: ServerConfig,
    active_threads: ThreadPool,
    thread_mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator, config: ServerConfig) !Self {
        const address = try net.Address.parseIp(config.host, config.port);
        const socket = try address.listen(.{
            .reuse_address = true,
        });
        errdefer socket.deinit();

        return .{
            .allocator = allocator,
            .socket = socket,
            .routes = std.StringHashMap(core.Handler).init(allocator),
            .running = std.atomic.Value(bool).init(true),
            .config = config,
            .active_threads = ThreadPool.init(allocator),
            .thread_mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        // First stop accepting new connections
        self.stop();

        // Close the socket to interrupt any blocking accept calls
        self.socket.deinit();

        // Wait for all threads to complete
        {
            self.thread_mutex.lock();
            defer self.thread_mutex.unlock();

            // Copy thread handles to avoid modification during iteration
            var threads = std.ArrayList(*std.Thread).init(self.allocator);
            defer threads.deinit();

            for (self.active_threads.items) |thread| {
                threads.append(thread) catch continue;
            }

            // Clear active threads list
            self.active_threads.clearAndFree();

            // Join and cleanup threads
            for (threads.items) |thread| {
                thread.join();
                self.allocator.destroy(thread);
            }
        }

        // Clean up routes
        var it = self.routes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.routes.deinit();
    }

    pub fn get(self: *Self, path: []const u8, handler: core.Handler) !void {
        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);
        try self.routes.put(path_owned, handler);
    }

    pub fn post(self: *Self, path: []const u8, handler: core.Handler) !void {
        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);
        try self.routes.put(path_owned, handler);
    }

    pub fn listen(self: *Self) !void {
        while (self.running.load(.acquire)) {
            const conn = self.socket.accept() catch |err| switch (err) {
                error.ConnectionAborted,
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.SystemResources,
                error.SocketNotListening,
                error.ConnectionResetByPeer,
                error.WouldBlock,
                error.ProtocolFailure,
                error.BlockedByFirewall,
                => {
                    if (!self.running.load(.acquire)) break;
                    std.time.sleep(10 * std.time.ns_per_ms);
                    continue;
                },
                error.FileDescriptorNotASocket,
                error.OperationNotSupported,
                error.NetworkSubsystemFailed,
                error.Unexpected,
                => return err,
            };

            // Allocate thread handle on heap so it lives beyond this scope
            const thread_handle = try self.allocator.create(std.Thread);
            errdefer self.allocator.destroy(thread_handle);

            // Add thread to active pool before spawning to ensure cleanup
            {
                self.thread_mutex.lock();
                defer self.thread_mutex.unlock();
                try self.active_threads.append(thread_handle);
            }

            thread_handle.* = try std.Thread.spawn(.{}, struct {
                fn run(server: *Self, connection: net.Server.Connection, thread: *std.Thread) !void {
                    defer {
                        connection.stream.close();
                        server.thread_mutex.lock();
                        defer server.thread_mutex.unlock();

                        for (server.active_threads.items, 0..) |t, i| {
                            if (t == thread) {
                                _ = server.active_threads.orderedRemove(i);
                                server.allocator.destroy(thread);
                                break;
                            }
                        }
                    }

                    var request_buf: [4096]u8 = undefined;
                    const bytes_read = try connection.stream.read(&request_buf);
                    if (bytes_read == 0) return;
                    const request_data = request_buf[0..bytes_read];

                    var request = try core.Request.parse(server.allocator, request_data);
                    defer request.deinit();

                    var response = core.Response.init(server.allocator);
                    defer response.deinit();

                    var ctx = core.Context.init(server.allocator, &request, &response);
                    defer ctx.deinit();

                    if (server.routes.get(request.path)) |handler| {
                        handler(&ctx) catch |err| {
                            _ = ctx.status(500);
                            try ctx.text("Internal Server Error");
                            std.log.err("Handler error: {}", .{err});
                        };
                    } else {
                        _ = ctx.status(404);
                        try ctx.text("Not Found");
                    }

                    try response.write(connection.stream.writer());
                }
            }.run, .{ self, conn, thread_handle });
        }
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);

        // Close the socket to interrupt any blocking accept calls
        self.socket.deinit();
    }
};
