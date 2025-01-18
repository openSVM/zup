const std = @import("std");
const testing = std.testing;
const json = std.json;
const trpc = @import("trpc.zig");
const core = @import("core.zig");
const Server = @import("server.zig").Server;
const RuntimeRouter = @import("trpc/runtime_router.zig").RuntimeRouter;

const Counter = struct {
    counter: usize = 0,
    mutex: std.Thread.Mutex = .{},
};

var global_counter: Counter = .{};

fn counterHandler(ctx: *core.Context, _: ?json.Value) !json.Value {
    _ = ctx;
    global_counter.mutex.lock();
    defer global_counter.mutex.unlock();
    global_counter.counter += 1;
    return json.Value{ .integer = @intCast(global_counter.counter) };
}

test "trpc - basic procedure call" {
    const allocator = testing.allocator;

    var router = RuntimeRouter.init(allocator);
    defer router.deinit();

    try router.procedure("counter", counterHandler, null, null);

    var server = try Server.init(allocator, .{
        .port = 0, // Random port for testing
        .thread_count = 1,
    });
    defer server.deinit();

    try router.mount(&server);

    const thread = try std.Thread.spawn(.{}, Server.start, .{&server});
    defer {
        server.running.store(false, .release);
        thread.join();
    }

    std.time.sleep(10 * std.time.ns_per_ms);

    // First call
    {
        const client = try std.net.tcpConnectToAddress(server.listener.listen_address);
        defer client.close();

        const request =
            \\POST /trpc/counter HTTP/1.1
            \\Host: localhost
            \\Content-Type: application/json
            \\Content-Length: 43
            \\
            \\{"id":"1","method":"counter","params":null}
        ;

        try client.writer().writeAll(request);

        var buf: [1024]u8 = undefined;
        const n = try client.read(&buf);
        const response = buf[0..n];

        std.debug.print("\nResponse: {s}\n", .{response});

        try testing.expect(std.mem.indexOf(u8, response, "\"result\":1") != null);
    }

    // Second call
    {
        const client = try std.net.tcpConnectToAddress(server.listener.listen_address);
        defer client.close();

        const request =
            \\POST /trpc/counter HTTP/1.1
            \\Host: localhost
            \\Content-Type: application/json
            \\Content-Length: 43
            \\
            \\{"id":"2","method":"counter","params":null}
        ;

        try client.writer().writeAll(request);

        var buf: [1024]u8 = undefined;
        const n = try client.read(&buf);
        const response = buf[0..n];

        std.debug.print("\nResponse: {s}\n", .{response});

        try testing.expect(std.mem.indexOf(u8, response, "\"result\":2") != null);
    }
}
