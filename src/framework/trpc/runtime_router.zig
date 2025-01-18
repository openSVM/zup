const std = @import("std");
const json = std.json;
const core = @import("core");
const Schema = @import("schema").Schema;

pub const RuntimeProcedure = struct {
    handler: *const fn (*core.Context, ?json.Value) anyerror!json.Value,
};

pub const RuntimeRouter = struct {
    allocator: std.mem.Allocator,
    procedures: std.StringHashMap(RuntimeProcedure),
    input_schemas: std.StringHashMap(Schema),
    output_schemas: std.StringHashMap(Schema),
    max_input_tokens: usize = 4096,
    max_output_tokens: usize = 4096,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .procedures = std.StringHashMap(RuntimeProcedure).init(allocator),
            .input_schemas = std.StringHashMap(Schema).init(allocator),
            .output_schemas = std.StringHashMap(Schema).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // First deinitialize the schemas since they reference the keys
        self.input_schemas.deinit();
        self.output_schemas.deinit();

        // Then free the procedure keys and deinit the procedures map
        var it = self.procedures.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.procedures.deinit();
    }

    pub fn procedure(
        self: *Self,
        name: []const u8,
        handler: *const fn (*core.Context, ?json.Value) anyerror!json.Value,
        input_schema: ?Schema,
        output_schema: ?Schema,
    ) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer {
            // Only free if we haven't successfully put it in procedures
            if (!self.procedures.contains(owned_name)) {
                self.allocator.free(owned_name);
            }
        }

        // Try to put in procedures first
        if (try self.procedures.fetchPut(owned_name, .{ .handler = handler })) |_| {
            // If we're replacing an existing entry, we need to free our new key
            self.allocator.free(owned_name);
            return error.ProcedureAlreadyExists;
        }

        // From this point on, owned_name is owned by the procedures map
        errdefer {
            _ = self.procedures.remove(owned_name);
        }

        if (input_schema) |schema| {
            try self.input_schemas.put(owned_name, schema);
        }

        if (output_schema) |schema| {
            try self.output_schemas.put(owned_name, schema);
        }
    }

    pub fn handleRequest(router: *Self, ctx: *core.Context) !void {
        const procedure_name = ctx.params.get("procedure").?;
        const proc = router.procedures.get(procedure_name) orelse {
            return error.ProcedureNotFound;
        };

        // Parse and validate request body
        const parsed = try json.parseFromSlice(json.Value, router.allocator, ctx.request.body, .{});
        defer parsed.deinit();

        // Validate input schema if present
        if (router.input_schemas.get(procedure_name)) |*schema| {
            try validateSchema(parsed.value.object.get("params") orelse return error.InvalidParams, schema);
        }

        // Call procedure handler
        const result = try proc.handler(ctx, parsed.value.object.get("params"));

        // Validate output schema if present
        if (router.output_schemas.get(procedure_name)) |*schema| {
            try validateSchema(result, schema);
        }

        // Create response object
        var arena = std.heap.ArenaAllocator.init(router.allocator);
        defer arena.deinit();

        var response_obj = std.json.ObjectMap.init(arena.allocator());
        try response_obj.put("id", parsed.value.object.get("id") orelse json.Value{ .null = {} });
        try response_obj.put("result", result);

        const response_value = std.json.Value{ .object = response_obj };
        try ctx.json(response_value);
    }

    pub fn mount(self: *Self, server: *@import("framework").Server) !void {
        const RouterContext = struct {
            router: *Self,

            pub fn handle(ctx: *core.Context) anyerror!void {
                const router_ctx = @as(*@This(), @ptrCast(@alignCast(ctx.data.?)));
                try router_ctx.router.handleRequest(ctx);
            }
        };

        const router_ctx = try self.allocator.create(RouterContext);
        router_ctx.* = .{ .router = self };

        try server.post("/trpc/:procedure", RouterContext.handle, router_ctx);
    }
};

const validateSchema = @import("schema").validateSchema;
