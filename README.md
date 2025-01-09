# Zup Server

A high-performance HTTP and WebSocket server framework written in Zig, designed for building scalable web applications with built-in parallel computing capabilities via SPICE integration.

## Features

- 🚀 Multi-threaded HTTP server with automatic CPU core detection
- 🔌 WebSocket support with automatic upgrade handling
- 💪 Keep-alive connection support for improved performance
- 🔄 Integration with SPICE for parallel computing tasks
- 📊 Built-in benchmarking tools
- 🧪 Comprehensive test suite

## Installation

1. Ensure you have Zig 0.11.0 or later installed
2. Clone the repository:
```bash
git clone https://github.com/yourusername/zup.git
cd zup
```

## Building

Build the project using Zig's build system:

```bash
zig build
```

This will create the following executables in `zig-out/bin/`:
- `server`: The main server executable
- `example-server`: An example server implementation
- `benchmark`: Benchmarking tool

## Usage

### Running the Server

Start the server on localhost:8080:

```bash
zig build run
```

Or run directly:

```bash
./zig-out/bin/server
```

### Example Server

Run the example server implementation:

```bash
zig build example
```

### Running Tests

Run the test suite:

```bash
zig build test
```

Run framework-specific tests:

```bash
zig build test-framework
```

### Benchmarking

Run HTTP benchmarks:

```bash
zig build bench
```

## API Documentation

### HTTP Server

The core server provides a simple interface for handling HTTP requests:

```zig
const std = @import("std");
const Server = @import("main.zig").Server;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp("127.0.0.1", 8080);
    var server = try Server.init(allocator, address);
    defer server.deinit();

    try server.start();
}
```

### WebSocket Support

The server automatically handles WebSocket upgrades and provides a simple message-based API:

```zig
// WebSocket frame handling example
const ws = @import("websocket.zig");

// Echo server implementation
while (true) {
    const frame = try ws.readMessage(stream);
    defer allocator.free(frame.payload);

    switch (frame.opcode) {
        .text, .binary => try ws.writeMessage(stream, frame.payload),
        .close => break,
        else => {},
    }
}
```

### Framework Module

The framework module provides additional utilities for building web applications:

```zig
const framework = @import("framework");

// Initialize router
var router = try framework.Router.init(allocator);
defer router.deinit();

// Add routes
try router.get("/", handleRoot);
try router.post("/api/data", handleData);
```

## Performance

The server is designed for high performance:
- Multi-threaded architecture utilizing all available CPU cores
- Keep-alive connection support
- Efficient WebSocket implementation
- Integration with SPICE for parallel computing tasks

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
