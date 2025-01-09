# Zup Benchmarking Guide

## Overview

Zup includes built-in benchmarking tools to measure and optimize server performance. The benchmarking system uses multi-threaded testing to simulate real-world load conditions.

## Benchmarking Tools

### HTTP Load Testing

The `benchmark` CLI tool provides comprehensive HTTP load testing capabilities:

```bash
# Basic benchmark with default settings
zig build bench

# Run benchmark executable directly
./zig-out/bin/benchmark
```

### Configuration Parameters

The benchmark tool automatically:
- Uses all available CPU cores for parallel request handling
- Maintains persistent connections with keep-alive
- Provides detailed performance metrics
- Tracks and reports errors

### Output Metrics

The benchmark results include:
- Requests per second (RPS)
- Total successful requests
- Test duration in milliseconds
- Number of errors encountered

## Implementation Details

### Connection Management

The benchmarking system:
- Creates one persistent TCP connection per thread
- Uses HTTP keep-alive for connection reuse
- Implements automatic connection retry on failures
- Handles connection errors gracefully

### Performance Optimizations

The benchmark implementation includes several optimizations:
- Pre-allocated buffers for requests and responses
- Thread-local context to minimize contention
- Efficient error handling and recovery
- Keep-alive connections to reduce overhead

## Using in Code

You can also use the benchmarking functionality programmatically:

```zig
const std = @import("std");
const benchmark = @import("benchmark.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure benchmark
    const address = try std.net.Address.parseIp("127.0.0.1", 8080);
    const duration_ms: u64 = 30 * 1000; // 30 seconds

    // Run HTTP GET benchmark
    const result = try benchmark.benchmarkHttp(
        allocator,
        address,
        "GET",
        duration_ms
    );

    // Print results
    std.debug.print(
        \\Benchmark Results:
        \\  Requests/second: {d:.2}
        \\  Total requests: {}
        \\  Duration: {}ms
        \\  Errors: {}
        \\
    , .{
        result.requests_per_second,
        result.total_requests,
        result.duration_ms,
        result.errors,
    });
}
```

## Best Practices

### Server Configuration

For optimal benchmark results:
1. Ensure the server has sufficient file descriptor limits
   ```bash
   ulimit -n 65535
   ```

2. Configure the server with appropriate thread count
   ```zig
   var server = try Server.init(allocator, .{
       .thread_count = 8, // Adjust based on CPU cores
       .backlog = 4096,
   });
   ```

3. Enable keep-alive support
   ```zig
   .reuse_address = true,
   ```

### Benchmark Parameters

For meaningful results:
1. Run benchmarks multiple times and average the results
2. Test with different concurrent connection counts
3. Vary request payload sizes for POST/PUT tests
4. Test both short and long durations

### Common Issues

1. Connection Errors
   - Check server's max connection settings
   - Verify network buffer sizes
   - Monitor system resource usage

2. Performance Degradation
   - Look for memory leaks
   - Check for connection pool exhaustion
   - Monitor CPU and memory usage

3. Inconsistent Results
   - Ensure stable test environment
   - Run multiple iterations
   - Account for warm-up period

## Example Benchmark Script

Here's a shell script to run comprehensive benchmarks:

```bash
#!/bin/bash

# Build latest version
zig build

# Run series of benchmarks
echo "Running GET benchmarks..."
./zig-out/bin/benchmark --method GET --duration 30s

echo "Running POST benchmarks..."
./zig-out/bin/benchmark --method POST --duration 30s

echo "Running concurrent connection test..."
./zig-out/bin/benchmark --method GET --duration 30s --connections 1000
```

## Performance Tuning

### Server Optimizations

1. Connection Pooling
   ```zig
   const Config = struct {
       backlog: u31 = 4096,
       reuse_address: bool = true,
   };
   ```

2. Buffer Management
   ```zig
   var buf: [8192]u8 = undefined; // Adjust buffer size based on needs
   ```

3. Thread Pool Configuration
   ```zig
   .thread_count = @min(16, try std.Thread.getCpuCount()),
   ```

### System Tuning

1. Network Parameters (Linux)
   ```bash
   # Increase TCP buffer sizes
   sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
   sysctl -w net.ipv4.tcp_wmem="4096 87380 16777216"

   # Increase max connections
   sysctl -w net.core.somaxconn=65535
   ```

2. File Descriptors
   ```bash
   # /etc/security/limits.conf
   * soft nofile 65535
   * hard nofile 65535
   ```

## Monitoring

During benchmarks, monitor:
1. CPU usage
2. Memory consumption
3. Network utilization
4. Open file descriptors
5. Error rates

Use tools like:
- `top` or `htop` for system resources
- `netstat` for connection stats
- `dstat` for combined metrics
