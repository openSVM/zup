const std = @import("std");
const core = @import("core");
const Router = @import("router.zig").Router;
const net = std.net;
const Thread = std.Thread;
const Atomic = std.atomic.Atomic;

pub const ServerConfig = struct {
    port: u16 = 8080,
    host: []const u8 = "127.0.0.1",
    max_connections: usize = 1000,
    thread_count: ?usize = null, // If null, use available CPU cores
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    address: net.Address,
    listener: ?net.StreamServer = null,
    running: Atomic(bool) = Atomic(bool).init(false),
    threads: std.ArrayList(Thread) = undefined,
    
    pub fn init(allocator: std.mem.Allocator, config: ServerConfig, router: ?*const Router) !Server {
        const address = try net.Address.parseIp(config.host, config.port);
        
        return Server{
            .allocator = allocator,
            .config = config,
            .address = address,
            .threads = std.ArrayList(Thread).init(allocator),
            .router = router,
        };
    }
    
    pub fn deinit(self: *Server) void {
        if (self.running.load(.acquire)) {
            self.stop();
        }
        
        if (self.listener) |*listener| {
            listener.deinit();
        }
        
        self.threads.deinit();
    }
    
    pub fn start(self: *Server) !void {
        if (self.running.load(.acquire)) {
            return error.ServerAlreadyRunning;
        }
        
        // Initialize the listener
        self.listener = net.StreamServer.init(.{
            .reuse_address = true,
        });
        
        // Bind to the address
        try self.listener.?.listen(self.address);
        
        // Set running flag
        self.running.store(true, .release);
        
        // Determine thread count
        const thread_count = self.config.thread_count orelse try Thread.getCpuCount();
        
        // Start worker threads
        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            const thread = try Thread.spawn(.{}, workerThread, .{self});
            try self.threads.append(thread);
        }
        
        std.log.info("Server started on {s}:{d} with {d} threads", .{
            self.config.host, 
            self.config.port, 
            thread_count
        });
    }
    
    pub fn stop(self: *Server) void {
        if (!self.running.load(.acquire)) {
            return;
        }
        
        // Set running flag to false
        self.running.store(false, .release);
        
        // Close the listener
        if (self.listener) |*listener| {
            listener.close();
        }
        
        // Wait for all threads to finish
        for (self.threads.items) |thread| {
            thread.join();
        }
        
        self.threads.clearAndFree();
        
        std.log.info("Server stopped", .{});
    }
    
    fn workerThread(server: *Server) !void {
        while (server.running.load(.acquire)) {
            // Accept a connection
            const connection = server.listener.?.accept() catch |err| {
                if (err == error.ConnectionAborted) {
                    // This happens when the server is shutting down
                    if (!server.running.load(.acquire)) {
                        break;
                    }
                }
                std.log.err("Failed to accept connection: {s}", .{@errorName(err)});
                continue;
            };
            
            // Handle the connection
            handleConnection(server, connection) catch |err| {
                std.log.err("Error handling connection: {s}", .{@errorName(err)});
            };
        }
    }
    
    fn handleConnection(server: *Server, connection: net.StreamServer.Connection) !void {
        defer connection.stream.close();
        
        // Create a buffer for reading the request
        var buf: [4096]u8 = undefined;
        const n = try connection.stream.read(&buf);
        
        if (n == 0) {
            return error.EmptyRequest;
        }
        
        // Parse the request
        const request = buf[0..n];
        
        // Check if it's a WebSocket upgrade request
        if (std.mem.indexOf(u8, request, "Upgrade: websocket") != null) {
            // Handle WebSocket upgrade
            try handleWebSocketUpgrade(server.allocator, connection.stream, request);
            return;
        }
        
        // Create a context for the request
        var ctx = core.Context.init(server.allocator);
        defer ctx.deinit();
        
        // Parse the request and fill the context
        try parseRequest(&ctx, request);
        
        // Set default response headers
        try ctx.response.headers.put("Content-Type", "text/plain");
        try ctx.response.headers.put("Server", "Zup");
        
        // Route the request to the appropriate handler if router is available
        if (server.router) |router| {
            router.handle(&ctx) catch |err| {
                if (err == error.RouteNotFound) {
                    ctx.response.status = 404;
                    ctx.response.body = try server.allocator.dupe(u8, "Not Found");
                } else {
                    ctx.response.status = 500;
                    ctx.response.body = try server.allocator.dupe(u8, "Internal Server Error");
                    std.log.err("Error handling request: {s}", .{@errorName(err)});
                }
            };
        } else {
            // If no router, just return a simple response
            ctx.response.body = try server.allocator.dupe(u8, "Hello from Zup Server!");
        }
        
        // Build and send the HTTP response
        var response_buffer = std.ArrayList(u8).init(server.allocator);
        defer response_buffer.deinit();
        
        // Write status line
        try std.fmt.format(response_buffer.writer(), "HTTP/1.1 {d} {s}\r\n", .{
            ctx.response.status,
            if (ctx.response.status == 200) "OK" else "Error",
        });
        
        // Write headers
        var header_it = ctx.response.headers.iterator();
        while (header_it.next()) |entry| {
            try std.fmt.format(response_buffer.writer(), "{s}: {s}\r\n", .{
                entry.key_ptr.*,
                entry.value_ptr.*,
            });
        }
        
        // Write Content-Length header
        const body_len = if (ctx.response.body) |body| body.len else 0;
        try std.fmt.format(response_buffer.writer(), "Content-Length: {d}\r\n", .{body_len});
        
        // End headers
        try response_buffer.appendSlice("\r\n");
        
        // Write body if present
        if (ctx.response.body) |body| {
            try response_buffer.appendSlice(body);
        }
        
        // Send the response
        _ = try connection.stream.write(response_buffer.items);
    }
};

fn parseRequest(ctx: *core.Context, request: []const u8) !void {
    // Split the request into lines
    var lines = std.mem.split(u8, request, "\r\n");
    
    // Parse the request line
    const request_line = lines.next() orelse return error.InvalidRequest;
    var parts = std.mem.split(u8, request_line, " ");
    
    // Get the method
    const method_str = parts.next() orelse return error.InvalidRequest;
    ctx.request.method = core.Method.fromString(method_str) orelse return error.UnsupportedMethod;
    
    // Get the path
    const path = parts.next() orelse return error.InvalidRequest;
    ctx.request.path = try ctx.allocator.dupe(u8, path);
    
    // Parse headers
    while (lines.next()) |line| {
        if (line.len == 0) break; // Empty line indicates end of headers
        
        const colon_pos = std.mem.indexOf(u8, line, ":") orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon_pos], " ");
        const header_value = std.mem.trim(u8, line[colon_pos + 1 ..], " ");
        
        try ctx.request.headers.put(
            try ctx.allocator.dupe(u8, header_name),
            try ctx.allocator.dupe(u8, header_value),
        );
    }
    
    // Parse body if present
    // Find the empty line that separates headers from body
    var body_start: usize = 0;
    const headers_end = std.mem.indexOf(u8, request, "\r\n\r\n");
    if (headers_end) |pos| {
        body_start = pos + 4; // Skip the \r\n\r\n
        
        // Check if there's a body
        if (body_start < request.len) {
            const body = request[body_start..];
            if (body.len > 0) {
                ctx.request.body = try ctx.allocator.dupe(u8, body);
            }
        }
    }
}

fn handleWebSocketUpgrade(allocator: std.mem.Allocator, stream: net.Stream, request: []const u8) !void {
    const websocket = @import("../websocket.zig");
    try websocket.handleUpgrade(allocator, stream, request);
    
    // After upgrade, handle the WebSocket connection
    // This is a simple echo server for demonstration
    while (true) {
        var frame = websocket.readMessage(allocator, stream) catch |err| {
            if (err == error.ConnectionClosed) {
                break;
            }
            std.log.err("Error reading WebSocket message: {s}", .{@errorName(err)});
            break;
        };
        defer allocator.free(frame.payload);
        
        // Handle different frame types
        switch (frame.opcode) {
            .text, .binary => {
                // Echo the message back
                try websocket.writeMessage(allocator, stream, frame.payload);
            },
            .close => {
                // Send close frame and exit
                try websocket.writeMessage(allocator, stream, "");
                break;
            },
            .ping => {
                // Respond to ping with pong
                const pong_frame = websocket.WebSocketFrame{
                    .opcode = .pong,
                    .payload = frame.payload,
                };
                var frame_buf: [1024]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&frame_buf);
                try pong_frame.encode(allocator, fbs.writer());
                _ = try stream.write(fbs.getWritten());
            },
            else => {}, // Ignore other frame types
        }
    }
}