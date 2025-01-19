const std = @import("std");
const json = std.json;
const core = @import("../core.zig");
const Schema = @import("schema").Schema;
const Server = @import("framework").Server;
const Procedure = @import("./procedure.zig").Procedure;

pub const Router = struct {
    allocator: std.mem.Allocator,
    procedures: std.StringHashMap(Procedure),
    max_input_tokens: usize = 4096,
    max_output_tokens: usize = 4096,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .procedures = std.StringHashMap(Procedure).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.procedures.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.input_schema) |schema| {
                schema.deinit(self.allocator);
            }
            if (entry.value_ptr.output_schema) |schema| {
                schema.deinit(self.allocator);
            }
        }
        self.procedures.deinit();
    }

    pub fn setTokenLimits(self: *Self, input: usize, output: usize) void {
        self.max_input_tokens = input;
        self.max_output_tokens = output;
    }

    pub fn procedure(
        self: *Self,
        name: []const u8,
        handler: fn (*core.Context, ?json.Value) anyerror!json.Value,
        input_schema: ?*Schema,
        output_schema: ?*Schema,
    ) !void {
        try self.procedures.put(name, .{
            .handler = handler,
            .input_schema = input_schema,
            .output_schema = output_schema,
        });
    }

    pub fn mount(self: *Self, server: *Server) !void {
        try server.addRoute(.POST, "/trpc/:procedure", handleRequest, self);
    }

    fn handleRequest(
        ctx: *core.Context,
        request: *Server.Request,
        response: *Server.Response,
        router: *Self,
    ) !void {
        const procedure_name = request.params.get("procedure").?;
        const proc = router.procedures.get(procedure_name) orelse {
            return error.ProcedureNotFound;
        };

        // Parse and validate request body
        const body = try request.readAll(router.allocator);
        defer router.allocator.free(body);

        const parsed = try json.parseFromSlice(json.Value, router.allocator, body, .{});
        defer parsed.deinit();

        // Validate input schema if present
        if (proc.input_schema) |schema| {
            try validateSchema(parsed.value.object.get("params") orelse return error.InvalidParams, schema);
        }

        // Call procedure handler
        const result = try proc.handler(ctx, parsed.value.object.get("params"));

        // Validate output schema if present
        if (proc.output_schema) |schema| {
            try validateSchema(result, schema);
        }

        // Serialize response
        const response_body = try json.stringifyAlloc(router.allocator, result, .{});
        defer router.allocator.free(response_body);

        try response.writeAll(response_body);
    }
};

const validateSchema = @import("./validation.zig").validateSchema;
