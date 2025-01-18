const std = @import("std");
const core = @import("core");
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const RuntimeRouter = struct {
    const Self = @This();

    const Procedure = struct {
        name: []const u8,
        input_schema: ?[]const u8,
        output_schema: ?[]const u8,
        handler_fn: *const fn (*core.Context, ?json.Value) anyerror!json.Value,
    };

    procedures: std.StringHashMap(Procedure),
    middlewares: std.ArrayList(core.Middleware),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Self {
        return .{
            .procedures = std.StringHashMap(Procedure).init(allocator),
            .middlewares = std.ArrayList(core.Middleware).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.procedures.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.input_schema) |schema| {
                self.allocator.free(schema);
            }
            if (entry.value_ptr.output_schema) |schema| {
                self.allocator.free(schema);
            }
        }
        self.procedures.deinit();

        for (self.middlewares.items) |*middleware| {
            middleware.deinit();
        }
        self.middlewares.deinit();
    }

    pub fn procedure(
        self: *Self,
        name: []const u8,
        input_schema: ?[]const u8,
        output_schema: ?[]const u8,
        handler_fn: *const fn (*core.Context, ?json.Value) anyerror!json.Value,
    ) !void {
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);

        const input_schema_owned = if (input_schema) |schema| try self.allocator.dupe(u8, schema) else null;
        errdefer if (input_schema_owned) |schema| self.allocator.free(schema);

        const output_schema_owned = if (output_schema) |schema| try self.allocator.dupe(u8, schema) else null;
        errdefer if (output_schema_owned) |schema| self.allocator.free(schema);

        const proc = Procedure{
            .name = name_owned,
            .input_schema = input_schema_owned,
            .output_schema = output_schema_owned,
            .handler_fn = handler_fn,
        };

        try self.procedures.put(name_owned, proc);
    }

    pub fn use(self: *Self, middleware: core.Middleware) !void {
        try self.middlewares.append(middleware);
    }

    pub fn handleRequest(self: *Self, ctx: *core.Context) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const body = ctx.request.body;
        std.debug.print("Request body: {s}\n", .{body});

        if (body.len == 0) {
            return error.InvalidRequest;
        }

        // Skip any whitespace at the start of the body
        var body_start: usize = 0;
        while (body_start < body.len and std.ascii.isWhitespace(body[body_start])) {
            body_start += 1;
        }
        if (body_start >= body.len) {
            return error.InvalidRequest;
        }

        const json_body = body[body_start..];
        std.debug.print("JSON body: {s}\n", .{json_body});

        var parsed = try std.json.parseFromSlice(
            json.Value,
            arena.allocator(),
            json_body,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            std.debug.print("Invalid root type: {}\n", .{root});
            return error.InvalidRequest;
        }

        const method = root.object.get("method") orelse return error.MissingMethod;
        if (method != .string) return error.InvalidMethod;
        const method_str = method.string;
        std.debug.print("Method: {s}\n", .{method_str});

        const proc = self.procedures.get(method_str) orelse return error.MissingProcedure;
        const request_id = root.object.get("id");

        if (proc.input_schema != null) {
            const params = root.object.get("params") orelse return error.MissingParams;
            if (params != .object) return error.InvalidParams;
            std.debug.print("Params: {}\n", .{params});
        }

        // Call handler with params and get result
        const result = try proc.handler_fn(ctx, root.object.get("params"));
        std.debug.print("Result: {}\n", .{result});

        // Construct response with id and result
        var response_obj = std.json.ObjectMap.init(arena.allocator());
        try response_obj.put("id", request_id orelse json.Value{ .null = {} });
        try response_obj.put("result", result);

        const response_value = json.Value{ .object = response_obj };
        try ctx.json(response_value);
    }

    const RouterHandler = struct {
        router: *RuntimeRouter,
        current_middleware: usize,

        fn init(router: *RuntimeRouter) @This() {
            return .{
                .router = router,
                .current_middleware = 0,
            };
        }

        fn nextFn(ctx: *core.Context) anyerror!void {
            if (HandlerContext.current_handler) |handler_instance| {
                try handler_instance.next(ctx);
            }
        }

        pub fn next(self: *@This(), ctx: *core.Context) !void {
            if (self.current_middleware < self.router.middlewares.items.len) {
                const middleware = &self.router.middlewares.items[self.current_middleware];
                self.current_middleware += 1;
                HandlerContext.current_handler = self;
                try middleware.handle(ctx, nextFn);
            } else {
                try self.router.handleRequest(ctx);
            }
        }
    };

    const HandlerContext = struct {
        var router_instance: ?*Self = null;
        var current_handler: ?*RouterHandler = null;

        pub fn handle(ctx: *core.Context) !void {
            if (router_instance) |router| {
                var handler_state = RouterHandler.init(router);
                try handler_state.next(ctx);
            } else {
                return error.RouterNotInitialized;
            }
        }
    };

    pub fn handler(self: *Self) *const fn (*core.Context) anyerror!void {
        HandlerContext.router_instance = self;
        return &HandlerContext.handle;
    }
};
