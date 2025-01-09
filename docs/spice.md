# SPICE Integration Guide for Zup

## Overview

Zup integrates with SPICE (Simple Parallel Interface for Concurrent Execution) to provide efficient parallel processing capabilities. SPICE enables easy parallelization of tasks across multiple threads with a simple, future-based API.

## Features

- Thread pool management
- Task-based parallelism
- Future-based asynchronous operations
- Automatic work distribution
- Efficient thread synchronization

## Basic Usage

### Thread Pool Initialization

```zig
const spice = @import("spice");

// Create and start a thread pool
var thread_pool = spice.ThreadPool.init(allocator);
defer thread_pool.deinit();

// Start with specific number of background workers
thread_pool.start(.{
    .background_worker_count = 4, // Number of worker threads
});
```

### Task Execution

```zig
// Define a task function
fn processData(t: *spice.Task, data: []const u8) u64 {
    var result: u64 = 0;
    // Process data...
    return result;
}

// Execute task
const result = thread_pool.call(u64, processData, data);
```

### Parallel Processing with Futures

```zig
fn parallelSum(t: *spice.Task, node: *Node) i64 {
    var result: i64 = node.value;

    if (node.left) |left| {
        if (node.right) |right| {
            // Fork right branch to run in parallel
            var future = spice.Future(*Node, i64).init();
            future.fork(t, parallelSum, right);

            // Process left branch in current thread
            result += t.call(i64, parallelSum, left);

            // Join right branch result
            if (future.join(t)) |val| {
                result += val;
            } else {
                // Fallback if task couldn't be scheduled
                result += t.call(i64, parallelSum, right);
            }
            return result;
        }
        // Single branch case
        result += t.call(i64, parallelSum, left);
    }
    return result;
}
```

## Advanced Features

### Task Scheduling

SPICE automatically handles task scheduling across available threads:

```zig
const Config = struct {
    // Configure thread pool
    background_worker_count: ?usize = null, // null = CPU count - 1
    min_tasks_per_thread: usize = 1,
    max_tasks_per_thread: usize = 256,
};

thread_pool.start(.{
    .background_worker_count = 8,
    .min_tasks_per_thread = 4,
    .max_tasks_per_thread = 64,
});
```

### Work Stealing

SPICE implements work stealing for better load balancing:

```zig
// Tasks are automatically distributed
// Large tasks are split when possible
fn processLargeData(t: *spice.Task, data: []const u8) void {
    if (data.len < 1024) {
        // Process directly if small enough
        processChunk(data);
        return;
    }

    // Split large tasks
    const mid = data.len / 2;
    var future = spice.Future(void, void).init();
    future.fork(t, processLargeData, data[0..mid]);
    t.call(void, processLargeData, data[mid..]);
    _ = future.join(t);
}
```

## Performance Considerations

1. Task Granularity
   ```zig
   // Too fine-grained (inefficient)
   for (items) |item| {
       thread_pool.call(void, processItem, item);
   }

   // Better: Process chunks
   const chunk_size = 1000;
   var i: usize = 0;
   while (i < items.len) {
       const end = @min(i + chunk_size, items.len);
       thread_pool.call(void, processChunk, items[i..end]);
       i = end;
   }
   ```

2. Thread Pool Configuration
   ```zig
   // Adjust based on workload
   const optimal_threads = @min(
       try std.Thread.getCpuCount(),
       (total_work_size + min_work_per_thread - 1) / min_work_per_thread
   );
   ```

3. Memory Management
   ```zig
   // Use arena allocator for task-local allocations
   var arena = std.heap.ArenaAllocator.init(allocator);
   defer arena.deinit();
   
   // Task function
   fn processWithArena(t: *spice.Task, data: []const u8) !void {
       var arena = std.heap.ArenaAllocator.init(t.allocator);
       defer arena.deinit();
       // Process data using arena.allocator()...
   }
   ```

## Example: Parallel Tree Processing

Here's a complete example of parallel tree processing using SPICE:

```zig
const Node = struct {
    value: i64,
    left: ?*Node = null,
    right: ?*Node = null,
};

const TreeProcessor = struct {
    thread_pool: spice.ThreadPool,

    pub fn init(allocator: std.mem.Allocator) TreeProcessor {
        var processor = TreeProcessor{
            .thread_pool = spice.ThreadPool.init(allocator),
        };
        processor.thread_pool.start(.{});
        return processor;
    }

    pub fn deinit(self: *TreeProcessor) void {
        self.thread_pool.deinit();
    }

    pub fn processTree(self: *TreeProcessor, root: *Node) i64 {
        return self.thread_pool.call(i64, parallelSum, root);
    }
};

// Usage
var processor = TreeProcessor.init(allocator);
defer processor.deinit();

const result = processor.processTree(root);
```

## Best Practices

1. Thread Pool Lifecycle
   - Create one thread pool per major subsystem
   - Reuse thread pools instead of creating new ones
   - Properly clean up with deinit()

2. Task Design
   - Keep tasks coarse-grained enough to justify parallelization
   - Use futures for dependent tasks
   - Avoid excessive synchronization

3. Resource Management
   - Use arena allocators for task-local allocations
   - Clean up resources in task functions
   - Avoid sharing mutable state between tasks

4. Error Handling
   - Propagate errors through task results
   - Use try/catch in task functions
   - Handle task failures gracefully

## Debugging Tips

1. Enable Debug Logging
   ```zig
   const spice_config = struct {
       pub const log_level = .debug;
   };
   ```

2. Monitor Thread Pool Stats
   ```zig
   const stats = thread_pool.getStats();
   std.debug.print("Active tasks: {}\n", .{stats.active_tasks});
   ```

3. Task Tracing
   ```zig
   fn tracedTask(t: *spice.Task, data: []const u8) void {
       std.debug.print("Task started: {}\n", .{t.id});
       defer std.debug.print("Task completed: {}\n", .{t.id});
       // Task work...
   }
