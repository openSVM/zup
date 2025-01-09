# Zup Framework Documentation

## Table of Contents
- [Server](#server)
- [Router](#router)
- [WebSocket](#websocket)
- [Error Handling](#error-handling)
- [Examples](#examples)

## Server

### Configuration

The server can be configured using the `Config` struct:

```zig
const Config = struct {
    address: []const u8 = "127.0.0.1",    // Server bind address
    port: u16 = 8080,                     // Server port
    thread_count: ?u32 = null,            // Number of worker threads (null = CPU count)
    backlog: u31 = 4096,                  // Connection backlog size
    reuse_address: bool = true,           // Enable SO_REUSEADDR
};
```

### Initialization

Initialize a new server instance:

```zig
const std = @import("std");
const framework = @import("framework");

// Create server with default config
var server = try framework.Server.init(allocator, .{});
defer server.deinit();

// Custom configuration
var server = try framework.Server.init(allocator, .{
    .address = "0.0.0.0",
    .port = 3000,
    .thread_count = 4,
});
defer server.deinit();
```

### Starting the Server

```zig
try server.start();
```

## Router

The router provides a simple interface for handling HTTP routes:

### Route Handlers

```zig
// Basic route handler
fn handleRoot(ctx: *Context) !void {
    try ctx.text("Hello, World!");
}

// Add routes
try server.get("/", handleRoot);
try server.post("/api/data", handleData);
try server.put("/api/update", handleUpdate);
try server.delete("/api/remove", handleDelete);
```

### Middleware

Middleware functions can process requests before they reach route handlers:

```zig
fn logRequest(ctx: *Context, next: Next) !void {
    std.log.info("Request: {s} {s}", .{ctx.request.method, ctx.request.path});
    try next(ctx);
}

// Add middleware
try server.use(logRequest);
```

### Context

The `Context` struct provides request and response handling utilities:

```zig
// Response helpers
try ctx.text("Plain text response");
try ctx.json(.{ .status = "success" });
try ctx.html("<h1>Hello</h1>");

// Request data
const body = ctx.request.body;
const headers = ctx.request.headers;
const method = ctx.request.method;
```

## WebSocket

The framework provides built-in WebSocket support:

### Handling WebSocket Connections

```zig
fn handleWebSocket(stream: net.Stream) !void {
    while (true) {
        const frame = try ws.readMessage(stream);
        defer allocator.free(frame.payload);

        switch (frame.opcode) {
            .text => try ws.writeMessage(stream, frame.payload),
            .binary => try ws.writeMessage(stream, frame.payload),
            .ping => {
                // Send pong response
                try ws.writeFrame(stream, .{
                    .opcode = .pong,
                    .payload = frame.payload,
                });
            },
            .close => break,
            else => {},
        }
    }
}
```

### WebSocket Frame Types

- `.text`: UTF-8 encoded text data
- `.binary`: Raw binary data
- `.ping`: Ping control frame
- `.pong`: Pong control frame
- `.close`: Connection close frame

## Error Handling

The framework provides comprehensive error handling:

```zig
// Custom error handler
fn errorHandler(ctx: *Context, err: anyerror) !void {
    switch (err) {
        error.NotFound => try ctx.status(404).text("Not Found"),
        error.InvalidRequest => try ctx.status(400).text("Bad Request"),
        else => {
            std.log.err("Internal error: {}", .{err});
            try ctx.status(500).text("Internal Server Error");
        },
    }
}

// Set custom error handler
try server.setErrorHandler(errorHandler);
```

## Examples

### Basic HTTP Server

```zig
const std = @import("std");
const framework = @import("framework");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try framework.Server.init(allocator, .{
        .port = 3000,
    });
    defer server.deinit();

    // Add routes
    try server.get("/", handleRoot);
    try server.post("/api/data", handleData);

    // Add middleware
    try server.use(logRequests);

    // Start server
    try server.start();
}

fn handleRoot(ctx: *Context) !void {
    try ctx.json(.{
        .message = "Welcome to Zup",
        .version = "1.0.0",
    });
}

fn handleData(ctx: *Context) !void {
    const data = try ctx.request.json();
    // Process data...
    try ctx.status(201).json(.{ .status = "created" });
}

fn logRequests(ctx: *Context, next: Next) !void {
    const start = std.time.milliTimestamp();
    try next(ctx);
    const duration = std.time.milliTimestamp() - start;
    std.log.info("{s} {s} - {}ms", .{
        ctx.request.method,
        ctx.request.path,
        duration,
    });
}
```

### WebSocket Echo Server

```zig
const std = @import("std");
const framework = @import("framework");
const ws = framework.websocket;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try framework.Server.init(allocator, .{});
    defer server.deinit();

    try server.get("/ws", handleWebSocket);
    try server.start();
}

fn handleWebSocket(ctx: *Context) !void {
    const stream = ctx.request.stream;
    try ws.handleUpgrade(stream, ctx.request.headers);

    while (true) {
        const frame = try ws.readMessage(stream);
        defer ctx.allocator.free(frame.payload);

        switch (frame.opcode) {
            .text, .binary => try ws.writeMessage(stream, frame.payload),
            .close => break,
            else => {},
        }
    }
}
