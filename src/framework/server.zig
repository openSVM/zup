const std = @import("std");
const net = std.net;
const mem = std.mem;
const Allocator = mem.Allocator;
const core = @import("core.zig");
const router = @import("router.zig");
const ws = @import("websocket.zig");

pub const Config = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    thread_count: ?u32 = null,
    backlog: u31 = 4096,
    reuse_address: bool = true,
};

pub const Server = struct {
    allocator: Allocator,
    router: router.Router,
    address: net.Address,
    listener: net.Server,
    running: std.atomic.Value(bool),
    thread_count: u32,
    threads: []?std.Thread,

    pub fn init(allocator: Allocator, config: Config) !Server {
        const address = try net.Address.parseIp(config.address, config.port);
        const thread_count = config.thread_count orelse @as(u32, @intCast(try std.Thread.getCpuCount()));

        // Pre-allocate thread array
        const threads = try allocator.alloc(?std.Thread, thread_count);
        errdefer allocator.free(threads);

        // Initialize threads to null
        for (threads) |*thread| {
            thread.* = null;
        }

        return Server{
            .allocator = allocator,
            .router = router.Router.init(allocator),
            .address = address,
            .listener = try address.listen(.{
                .reuse_address = config.reuse_address,
                .kernel_backlog = @as(u31, @intCast(config.backlog)),
            }),
            .running = std.atomic.Value(bool).init(true),
            .thread_count = thread_count,
            .threads = threads,
        };
    }

    pub fn deinit(self: *Server) void {
        // Signal threads to stop
        self.running.store(false, .release);

        // Deinit listener to unblock accept()
        self.listener.deinit();

        // Wait for spawned threads to finish
        for (self.threads) |maybe_thread| {
            if (maybe_thread) |thread| {
                thread.join();
            }
        }

        // Clean up resources
        self.allocator.free(self.threads);
        self.router.deinit();
    }

    pub fn start(self: *Server) !void {
        // Start worker threads
        for (self.threads) |*maybe_thread| {
            maybe_thread.* = try std.Thread.spawn(.{}, workerThread, .{self});
        }
    }

    // Router delegation methods
    pub fn get(self: *Server, path: []const u8, handler: core.Handler) !void {
        try self.router.get(path, handler);
    }

    pub fn post(self: *Server, path: []const u8, handler: core.Handler) !void {
        try self.router.post(path, handler);
    }

    pub fn put(self: *Server, path: []const u8, handler: core.Handler) !void {
        try self.router.put(path, handler);
    }

    pub fn delete(self: *Server, path: []const u8, handler: core.Handler) !void {
        try self.router.delete(path, handler);
    }

    pub fn use(self: *Server, middleware: core.Middleware) !void {
        try self.router.use(middleware);
    }
};

fn workerThread(server: *Server) void {
    while (server.running.load(.acquire)) {
        const conn = server.listener.accept() catch |err| {
            if (!server.running.load(.acquire)) break;
            if (err == error.ConnectionAborted) break;
            std.log.err("Accept error: {}", .{err});
            continue;
        };
        defer conn.stream.close();

        handleConnection(server, conn.stream) catch |err| {
            std.log.err("Connection error: {}", .{err});
            continue;
        };
    }
}

fn handleConnection(server: *Server, stream: net.Stream) !void {
    var buf: [8192]u8 = undefined;
    const n = stream.read(&buf) catch |err| switch (err) {
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.ConnectionTimedOut,
        error.WouldBlock,
        => return err,
        else => return error.ConnectionClosed,
    };
    if (n == 0) return error.ConnectionResetByPeer;

    const data = buf[0..n];
    std.log.debug("Received request: {s}", .{data});

    // WebSocket upgrade check
    if (mem.startsWith(u8, data, "GET") and mem.indexOf(u8, data, "Upgrade: websocket") != null) {
        try handleWebSocket(stream, data);
        return;
    }

    // Parse HTTP request
    var request = core.Request.parse(server.allocator, data) catch |err| {
        try sendHttpError(stream, 400, "Bad Request");
        return err;
    };
    defer request.deinit();

    var response = core.Response.init(server.allocator);
    defer response.deinit();

    var ctx = core.Context.init(server.allocator, &request, &response);
    defer ctx.deinit();

    // Handle the request through the router
    server.router.handle(&ctx) catch |err| {
        response.status = 500;
        try ctx.text("Internal Server Error");
        std.log.err("Error handling request: {}", .{err});
    };

    // Write response
    try response.write(stream.writer());
    std.log.debug("Response sent", .{});
}

fn handleWebSocket(stream: net.Stream, data: []const u8) !void {
    try ws.handleUpgrade(stream, data);

    while (true) {
        const frame = ws.readMessage(stream) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            error.ConnectionTimedOut,
            error.WouldBlock,
            => return,
            else => return err,
        };
        defer std.heap.page_allocator.free(frame.payload);

        switch (frame.opcode) {
            .text, .binary => try ws.writeMessage(stream, frame.payload),
            .ping => {
                const pong = ws.WebSocketFrame{
                    .opcode = .pong,
                    .payload = frame.payload,
                };
                var buffer: [128]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buffer);
                try pong.encode(fbs.writer());
                try stream.writeAll(fbs.getWritten());
            },
            .close => return,
            else => {},
        }
    }
}

fn sendHttpError(stream: net.Stream, code: u16, message: []const u8) !void {
    var buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(&buf,
        \\HTTP/1.1 {} {s}
        \\Content-Type: text/plain
        \\Content-Length: {}
        \\Connection: close
        \\
        \\{s}
    , .{ code, message, message.len, message });
    try stream.writeAll(response);
}
