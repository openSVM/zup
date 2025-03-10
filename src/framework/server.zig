const std = @import("std");
const core = @import("core");
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
    
    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Server {
        const address = try net.Address.parseIp(config.host, config.port);
        
        return Server{
            .allocator = allocator,
            .config = config,
            .address = address,
            .threads = std.ArrayList(Thread).init(allocator),
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
        
        // TODO: Route the request to the appropriate handler
        
        // For now, just return a simple response
        const response = try std.fmt.allocPrint(
            server.allocator,
            "HTTP/1.1 {d} OK\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "Hello from Zup Server!",
            .{ ctx.response.status, "Hello from Zup Server!".len },
        );
        defer server.allocator.free(response);
        
        _ = try connection.stream.write(response);
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
    
    // TODO: Parse body if present
}

fn handleWebSocketUpgrade(allocator: std.mem.Allocator, stream: net.Stream, request: []const u8) !void {
    // This is a placeholder for WebSocket upgrade handling
    // In a real implementation, you would:
    // 1. Parse the WebSocket key from the request
    // 2. Generate the accept key
    // 3. Send the upgrade response
    // 4. Handle the WebSocket connection
    
    _ = allocator;
    _ = stream;
    _ = request;
}