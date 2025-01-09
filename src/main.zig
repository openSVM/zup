const std = @import("std");
const spice = @import("spice");
const net = std.net;
const mem = std.mem;
const Allocator = mem.Allocator;
const ws = @import("websocket.zig");

pub const Server = struct {
    allocator: Allocator,
    address: net.Address,
    listener: net.Server,
    running: std.atomic.Value(bool),

    pub fn init(allocator: Allocator, address: net.Address) !Server {
        const server = Server{
            .allocator = allocator,
            .address = address,
            .listener = try address.listen(.{
                .reuse_address = true,
                .kernel_backlog = 4096,
            }),
            .running = std.atomic.Value(bool).init(true),
        };
        return server;
    }

    pub fn deinit(self: *Server) void {
        self.running.store(false, .release);
        // Give threads time to clean up
        std.time.sleep(10 * std.time.ns_per_ms);
        self.listener.deinit();
    }

    pub fn start(self: *Server) !void {
        // Create worker threads
        const thread_count = if (@import("builtin").is_test) 1 else try std.Thread.getCpuCount();
        const threads = try self.allocator.alloc(std.Thread, thread_count);
        defer self.allocator.free(threads);

        // Start worker threads
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{self});
        }

        // Wait for all threads to finish
        for (threads) |thread| {
            thread.join();
        }
    }
};

fn workerThread(server: *Server) void {
    while (server.running.load(.acquire)) {
        const conn = server.listener.accept() catch |err| switch (err) {
            error.WouldBlock,
            error.ConnectionResetByPeer,
            error.ConnectionAborted,
            error.SocketNotListening,
            error.ProtocolFailure,
            error.BlockedByFirewall,
            error.FileDescriptorNotASocket,
            error.OperationNotSupported,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            => break,
            else => continue,
        };
        defer conn.stream.close();

        // Handle connection with keep-alive
        while (server.running.load(.acquire)) {
            handleConnection(conn.stream) catch |err| switch (err) {
                error.ConnectionResetByPeer,
                error.BrokenPipe,
                error.ConnectionTimedOut,
                error.WouldBlock,
                => break,
                else => continue,
            };
        }
    }
}

fn handleConnection(stream: net.Stream) !void {
    var buf: [4096]u8 = undefined;
    const n = stream.read(&buf) catch |err| switch (err) {
        error.WouldBlock => return error.WouldBlock,
        error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
        error.BrokenPipe => return error.BrokenPipe,
        error.ConnectionTimedOut => return error.ConnectionTimedOut,
        else => return err,
    };
    if (n == 0) return error.ConnectionResetByPeer;

    const data = buf[0..n];

    // Check for WebSocket upgrade first
    if (mem.startsWith(u8, data, "GET") and
        mem.indexOf(u8, data, "Upgrade: websocket") != null and
        mem.indexOf(u8, data, "Connection: Upgrade") != null and
        mem.indexOf(u8, data, "Sec-WebSocket-Key:") != null)
    {
        try handleWebSocket(stream, data);
        return;
    }

    // Handle regular HTTP requests
    if (mem.startsWith(u8, data, "GET /")) {
        try stream.writeAll(GET_RESPONSE);
        return;
    }
    if (mem.startsWith(u8, data, "POST /")) {
        try stream.writeAll(POST_RESPONSE);
        return;
    }

    try sendHttpError(stream, 400, "Bad Request");
}

const GET_RESPONSE =
    \\HTTP/1.1 200 OK
    \\Content-Type: text/plain
    \\Content-Length: 13
    \\Connection: keep-alive
    \\
    \\Hello, World!
;

const POST_RESPONSE =
    \\HTTP/1.1 200 OK
    \\Content-Type: text/plain
    \\Content-Length: 2
    \\Connection: keep-alive
    \\
    \\OK
;

fn handleWebSocket(stream: net.Stream, data: []const u8) !void {
    try ws.handleUpgrade(stream, data);

    // Echo server - read messages and send them back
    while (true) {
        const frame = ws.readMessage(stream) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            error.ConnectionTimedOut,
            error.WouldBlock,
            => {
                std.debug.print("\nServer: Connection error: {}\n", .{err});
                return;
            },
            else => {
                std.debug.print("\nServer: Other error: {}\n", .{err});
                return err;
            },
        };
        defer std.testing.allocator.free(frame.payload);

        std.debug.print("\nServer: Received frame with opcode: {}, payload: {s}\n", .{ frame.opcode, frame.payload });

        switch (frame.opcode) {
            .text, .binary => {
                std.debug.print("\nServer: Echoing message back\n", .{});
                try ws.writeMessage(stream, frame.payload);
            },
            .ping => {
                const pong_payload = try std.testing.allocator.dupe(u8, frame.payload);
                errdefer std.testing.allocator.free(pong_payload);
                const pong = ws.WebSocketFrame{
                    .opcode = .pong,
                    .payload = pong_payload,
                };
                var buffer: [128]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buffer);
                try pong.encode(fbs.writer());
                try stream.writeAll(fbs.getWritten());
                std.testing.allocator.free(pong_payload);
            },
            .close => {
                // Echo back the close frame
                const close_frame = ws.WebSocketFrame{
                    .opcode = .close,
                    .payload = frame.payload,
                };
                var buffer: [128]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buffer);
                try close_frame.encode(fbs.writer());
                try stream.writeAll(fbs.getWritten());
                return;
            },
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
        \\Connection: keep-alive
        \\
        \\{s}
    , .{ code, message, message.len, message });
    try stream.writeAll(response);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const address = try net.Address.parseIp("127.0.0.1", 8080);
    var server = try Server.init(allocator, address);
    defer server.deinit();

    try server.start();
}

test "HTTP methods" {
    const address = try net.Address.parseIp("127.0.0.1", 0);
    var server = try Server.init(std.testing.allocator, address);
    defer server.deinit();

    // Start server in background
    var server_thread = try std.Thread.spawn(.{}, Server.start, .{&server});

    // Wait for server to start
    std.time.sleep(10 * std.time.ns_per_ms);

    // Test GET request
    {
        const client = try net.tcpConnectToAddress(server.listener.listen_address);
        defer client.close();

        _ = try client.write("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");

        var buf: [1024]u8 = undefined;
        const n = try client.read(&buf);
        const response = buf[0..n];

        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK"));
        try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "Hello, World!"));
    }

    // Test POST request
    {
        const client = try net.tcpConnectToAddress(server.listener.listen_address);
        defer client.close();

        _ = try client.write("POST / HTTP/1.1\r\nConnection: close\r\n\r\n");

        var buf: [1024]u8 = undefined;
        const n = try client.read(&buf);
        const response = buf[0..n];

        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK"));
        try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "OK"));
    }

    // Test invalid method
    {
        const client = try net.tcpConnectToAddress(server.listener.listen_address);
        defer client.close();

        _ = try client.write("INVALID / HTTP/1.1\r\nConnection: close\r\n\r\n");

        var buf: [1024]u8 = undefined;
        const n = try client.read(&buf);
        const response = buf[0..n];

        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request"));
    }

    // Cleanup server
    server.running.store(false, .release);
    server_thread.join();
}

test "WebSocket handling" {
    const address = try net.Address.parseIp("127.0.0.1", 0);
    var server = try Server.init(std.testing.allocator, address);
    defer server.deinit();

    // Start server in background
    var server_thread = try std.Thread.spawn(.{}, Server.start, .{&server});

    // Wait for server to start
    std.time.sleep(10 * std.time.ns_per_ms);

    // Test WebSocket upgrade and communication
    {
        const client = try net.tcpConnectToAddress(server.listener.listen_address);
        defer client.close();

        // Send WebSocket upgrade request
        const key = "dGhlIHNhbXBsZSBub25jZQ=="; // Base64 encoded
        const upgrade_request = try std.fmt.allocPrint(std.testing.allocator, "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\n\r\n", .{key});
        defer std.testing.allocator.free(upgrade_request);

        _ = try client.write(upgrade_request);

        // Read upgrade response
        var buf: [1024]u8 = undefined;
        const n = try client.read(&buf);
        const response = buf[0..n];

        std.debug.print("\nResponse: {s}\n", .{response});
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 101"));
        try std.testing.expect(std.mem.indexOf(u8, response, "Upgrade: websocket") != null);

        // Test WebSocket frame exchange
        const payload = try std.testing.allocator.dupe(u8, "Hello");
        defer std.testing.allocator.free(payload);
        const frame = ws.WebSocketFrame{
            .opcode = .text,
            .mask = true, // Client frames must be masked
            .payload = payload,
        };

        var frame_buf: [128]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&frame_buf);
        try frame.encode(fbs.writer());
        const written = fbs.getWritten();
        std.debug.print("\nSending frame: {any}\n", .{written});
        _ = try client.write(written);

        // Read and verify echo response
        {
            var retries: usize = 100; // 1 second total with 10ms sleep
            const echo_n = while (retries > 0) : (retries -= 1) {
                if (client.read(&buf)) |read_bytes| {
                    break read_bytes;
                } else |err| switch (err) {
                    error.WouldBlock => {
                        std.time.sleep(10 * std.time.ns_per_ms);
                        continue;
                    },
                    else => {
                        std.debug.print("\nRead error: {}\n", .{err});
                        return err;
                    },
                }
            } else {
                std.debug.print("\nRead timeout after retries\n", .{});
                return error.ConnectionTimedOut;
            };
            std.debug.print("\nReceived response: {any}\n", .{buf[0..echo_n]});
            var stream = std.io.fixedBufferStream(buf[0..echo_n]);
            const echo_frame = try ws.WebSocketFrame.decode(stream.reader());
            defer std.testing.allocator.free(echo_frame.payload);
            std.debug.print("\nDecoded frame payload: {s}\n", .{echo_frame.payload});

            try std.testing.expectEqual(frame.opcode, echo_frame.opcode);
            try std.testing.expectEqualStrings(frame.payload, echo_frame.payload);
        }

        // Send close frame and wait for response
        {
            const close_payload = try std.testing.allocator.dupe(u8, "");
            defer std.testing.allocator.free(close_payload);
            const close_frame = ws.WebSocketFrame{
                .opcode = .close,
                .mask = true,
                .payload = close_payload,
            };
            var close_buf: [128]u8 = undefined;
            var close_fbs = std.io.fixedBufferStream(&close_buf);
            try close_frame.encode(close_fbs.writer());
            _ = try client.write(close_fbs.getWritten());

            // Wait for server's close response
            var close_retries: usize = 100;
            _ = while (close_retries > 0) : (close_retries -= 1) {
                if (client.read(&buf)) |read_bytes| {
                    var close_stream = std.io.fixedBufferStream(buf[0..read_bytes]);
                    const response_frame = try ws.WebSocketFrame.decode(close_stream.reader());
                    if (response_frame.opcode == .close) {
                        std.testing.allocator.free(response_frame.payload);
                        break;
                    }
                    std.testing.allocator.free(response_frame.payload);
                } else |err| switch (err) {
                    error.WouldBlock => {
                        std.time.sleep(10 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return err,
                }
            } else {
                std.debug.print("\nTimeout waiting for close response\n", .{});
                return error.ConnectionTimedOut;
            };
        }
    }

    // Cleanup server
    server.running.store(false, .release);
    server_thread.join();
}

test "connection handling" {
    const address = try net.Address.parseIp("127.0.0.1", 0);
    var server = try Server.init(std.testing.allocator, address);
    defer server.deinit();

    // Start server in background
    var server_thread = try std.Thread.spawn(.{}, Server.start, .{&server});

    // Wait for server to start
    std.time.sleep(10 * std.time.ns_per_ms);

    // Test keep-alive
    {
        const client = try net.tcpConnectToAddress(server.listener.listen_address);
        defer client.close();

        // Send multiple requests on same connection
        for (0..3) |_| {
            _ = try client.write("GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n");

            var buf: [1024]u8 = undefined;
            const n = try client.read(&buf);
            const response = buf[0..n];

            try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK"));
            try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "Hello, World!"));
            try std.testing.expect(std.mem.indexOf(u8, response, "Connection: keep-alive") != null);
        }

        // Send final request with Connection: close
        _ = try client.write("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
        var buf: [1024]u8 = undefined;
        const n = try client.read(&buf);
        const response = buf[0..n];
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK"));
    }

    // Test connection reset
    {
        const client = try net.tcpConnectToAddress(server.listener.listen_address);
        defer client.close();

        // Send partial request and close connection
        _ = try client.write("GET / HTTP/1");
        // Don't call close() here since we're simulating an abrupt connection reset

        // Server should handle the reset gracefully
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    // Cleanup server
    server.running.store(false, .release);
    server_thread.join();
}
