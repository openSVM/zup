const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;

pub const Route = struct {
    method: core.Method,
    pattern: []const u8,
    handler: core.Handler,
    middleware: std.ArrayList(core.Middleware),

    pub fn init(allocator: Allocator, method: core.Method, pattern: []const u8, handler: core.Handler) Route {
        return .{
            .method = method,
            .pattern = pattern,
            .handler = handler,
            .middleware = std.ArrayList(core.Middleware).init(allocator),
        };
    }

    pub fn deinit(self: *Route) void {
        for (self.middleware.items) |*mw| {
            mw.deinit();
        }
        self.middleware.deinit();
    }
};

pub const Router = struct {
    allocator: Allocator,
    routes: std.ArrayList(Route),
    global_middleware: std.ArrayList(core.Middleware),

    pub fn init(allocator: Allocator) Router {
        return .{
            .allocator = allocator,
            .routes = std.ArrayList(Route).init(allocator),
            .global_middleware = std.ArrayList(core.Middleware).init(allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |*route| {
            route.deinit();
        }
        self.routes.deinit();

        for (self.global_middleware.items) |*mw| {
            mw.deinit();
        }
        self.global_middleware.deinit();
    }

    pub fn get(self: *Router, pattern: []const u8, handler: core.Handler) !void {
        const route = Route.init(self.allocator, .GET, pattern, handler);
        try self.routes.append(route);
    }

    pub fn post(self: *Router, pattern: []const u8, handler: core.Handler) !void {
        const route = Route.init(self.allocator, .POST, pattern, handler);
        try self.routes.append(route);
    }

    pub fn put(self: *Router, pattern: []const u8, handler: core.Handler) !void {
        const route = Route.init(self.allocator, .PUT, pattern, handler);
        try self.routes.append(route);
    }

    pub fn delete(self: *Router, pattern: []const u8, handler: core.Handler) !void {
        const route = Route.init(self.allocator, .DELETE, pattern, handler);
        try self.routes.append(route);
    }

    pub fn use(self: *Router, middleware: core.Middleware) !void {
        try self.global_middleware.append(middleware);
    }

    pub fn handle(self: *Router, ctx: *core.Context) !void {
        // Find matching route
        const route = self.findRoute(ctx.request.method, ctx.request.path) orelse return error.RouteNotFound;

        // Extract path parameters
        try extractParams(ctx, route.pattern, ctx.request.path);

        // If no middleware, just call the handler
        if (self.global_middleware.items.len == 0) {
            return route.handler(ctx);
        }

        // Apply middleware in sequence
        for (self.global_middleware.items) |mw| {
            try mw.handle(ctx, route.handler);
        }

        // Call the final handler
        try route.handler(ctx);
    }

    fn findRoute(self: *Router, method: core.Method, path: []const u8) ?*Route {
        for (self.routes.items) |*route| {
            if (route.method == method and self.matchPattern(route.pattern, path)) {
                return route;
            }
        }
        return null;
    }

    fn matchPattern(self: *Router, pattern: []const u8, path: []const u8) bool {
        _ = self;
        
        // Handle root path
        if (std.mem.eql(u8, pattern, "/") and std.mem.eql(u8, path, "/")) {
            return true;
        }
        
        var pattern_parts = std.mem.split(u8, pattern, "/");
        var path_parts = std.mem.split(u8, path, "/");
        
        // Skip empty first part if path starts with "/"
        if (pattern.len > 0 and pattern[0] == '/') _ = pattern_parts.next();
        if (path.len > 0 and path[0] == '/') _ = path_parts.next();
        
        while (true) {
            const pattern_part = pattern_parts.next() orelse {
                // If we've reached the end of the pattern, the match is successful
                // only if we've also reached the end of the path
                return path_parts.next() == null;
            };
            
            const path_part = path_parts.next() orelse {
                // If we've reached the end of the path but not the pattern,
                // the match fails
                return false;
            };
            
            // Handle path parameters (starting with ":")
            if (std.mem.startsWith(u8, pattern_part, ":")) {
                // This is a path parameter, it matches any path part
                continue;
            }
            
            // For regular path parts, they must match exactly
            if (!std.mem.eql(u8, pattern_part, path_part)) {
                return false;
            }
        }
    }
    
    fn extractParams(ctx: *core.Context, pattern: []const u8, path: []const u8) !void {
        var pattern_parts = std.mem.split(u8, pattern, "/");
        var path_parts = std.mem.split(u8, path, "/");
        
        // Skip empty first part if path starts with "/"
        if (pattern.len > 0 and pattern[0] == '/') _ = pattern_parts.next();
        if (path.len > 0 and path[0] == '/') _ = path_parts.next();
        
        while (true) {
            const pattern_part = pattern_parts.next() orelse break;
            const path_part = path_parts.next() orelse break;
            
            // Extract parameter if pattern part starts with ":"
            if (std.mem.startsWith(u8, pattern_part, ":")) {
                const param_name = pattern_part[1..]; // Skip the ":" prefix
                try ctx.params.put(param_name, path_part);
            }
        }
    }
};