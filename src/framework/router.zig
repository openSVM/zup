const std = @import("std");
const core = @import("core.zig");
const Allocator = std.mem.Allocator;

pub const Route = struct {
    method: core.Method,
    path: []const u8,
    handler: core.Handler,
    middleware: []const core.Middleware,

    pub fn init(method: core.Method, path: []const u8, handler: core.Handler, middleware: []const core.Middleware) Route {
        return .{
            .method = method,
            .path = path,
            .handler = handler,
            .middleware = middleware,
        };
    }
};

const MiddlewareChain = struct {
    middlewares: []const core.Middleware,
    handler: core.Handler,
    current_index: usize,

    pub fn init(middlewares: []const core.Middleware, handler: core.Handler) MiddlewareChain {
        return .{
            .middlewares = middlewares,
            .handler = handler,
            .current_index = 0,
        };
    }

    fn handleNext(ctx_: *core.Context) anyerror!void {
        if (ctx_.data) |ptr| {
            const chain = @as(*MiddlewareChain, @ptrCast(@alignCast(ptr)));
            try chain.next(ctx_);
        } else {
            return error.InvalidContext;
        }
    }

    pub fn next(self: *MiddlewareChain, ctx: *core.Context) !void {
        if (self.current_index < self.middlewares.len) {
            const middleware = self.middlewares[self.current_index];
            self.current_index += 1;
            ctx.data = self;
            try middleware.handle(ctx, handleNext);
        } else {
            try self.handler(ctx);
        }
    }
};

pub const Router = struct {
    routes: std.ArrayList(Route),
    allocator: Allocator,
    global_middleware: std.ArrayList(core.Middleware),

    pub fn init(allocator: Allocator) Router {
        return .{
            .routes = std.ArrayList(Route).init(allocator),
            .allocator = allocator,
            .global_middleware = std.ArrayList(core.Middleware).init(allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit();
        self.global_middleware.deinit();
    }

    pub fn add(self: *Router, route: Route) !void {
        try self.routes.append(route);
    }

    pub fn get(self: *Router, path: []const u8, handler: core.Handler) !void {
        try self.add(Route.init(.GET, path, handler, &[_]core.Middleware{}));
    }

    pub fn post(self: *Router, path: []const u8, handler: core.Handler) !void {
        try self.add(Route.init(.POST, path, handler, &[_]core.Middleware{}));
    }

    pub fn put(self: *Router, path: []const u8, handler: core.Handler) !void {
        try self.add(Route.init(.PUT, path, handler, &[_]core.Middleware{}));
    }

    pub fn delete(self: *Router, path: []const u8, handler: core.Handler) !void {
        try self.add(Route.init(.DELETE, path, handler, &[_]core.Middleware{}));
    }

    pub fn use(self: *Router, middleware: core.Middleware) !void {
        try self.global_middleware.append(middleware);
    }

    pub fn match(self: Router, method: core.Method, path: []const u8) !?struct {
        route: Route,
        params: std.StringHashMap([]const u8),
    } {
        var params = std.StringHashMap([]const u8).init(self.allocator);
        errdefer params.deinit();

        for (self.routes.items) |route| {
            if (route.method != method) continue;
            if (try matchPath(route.path, path, &params)) {
                return .{
                    .route = route,
                    .params = params,
                };
            }
            params.clearRetainingCapacity();
        }
        params.deinit();
        return null;
    }

    fn matchPath(pattern: []const u8, path: []const u8, params: *std.StringHashMap([]const u8)) !bool {
        var pattern_parts = std.mem.split(u8, pattern, "/");
        var path_parts = std.mem.split(u8, path, "/");

        while (true) {
            const pattern_part = pattern_parts.next() orelse {
                return path_parts.next() == null;
            };
            const path_part = path_parts.next() orelse return false;

            if (std.mem.startsWith(u8, pattern_part, ":")) {
                const param_name = pattern_part[1..];
                const param_value = try params.allocator.dupe(u8, path_part);
                errdefer params.allocator.free(param_value);
                const param_key = try params.allocator.dupe(u8, param_name);
                errdefer params.allocator.free(param_key);

                // Free old value if it exists
                if (params.getPtr(param_key)) |old_value| {
                    params.allocator.free(old_value.*);
                }

                try params.put(param_key, param_value);
                continue;
            }

            if (!std.mem.eql(u8, pattern_part, path_part)) {
                return false;
            }
        }
    }

    pub fn handle(self: Router, ctx: *core.Context) !void {
        const match_result = (try self.match(ctx.request.method, ctx.request.path)) orelse {
            ctx.response.status = 404;
            try ctx.text("Not Found");
            return;
        };

        // Replace context params with matched params
        ctx.params.deinit();
        ctx.params = match_result.params;

        // Create middleware chain
        var all_middleware = std.ArrayList(core.Middleware).init(self.allocator);
        defer all_middleware.deinit();

        // Add route-specific middleware first (in reverse order)
        var i: usize = match_result.route.middleware.len;
        while (i > 0) {
            i -= 1;
            try all_middleware.append(match_result.route.middleware[i]);
        }

        // Add global middleware (in reverse order)
        i = self.global_middleware.items.len;
        while (i > 0) {
            i -= 1;
            try all_middleware.append(self.global_middleware.items[i]);
        }

        // Create and execute middleware chain
        var chain = MiddlewareChain.init(all_middleware.items, match_result.route.handler);
        try chain.next(ctx);
    }
};
