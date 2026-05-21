const std = @import("std");

/// Lightweight call graph analyzer for the zust transpiler.
///
/// Parses all .zig files in a project to build a map of which files
/// call which functions. Used to identify non-public functions that
/// are only called from within their own file — these are safe to
/// convert from `*T` parameters to `safe.Box(T)`.
///
/// Approach: Name-based analysis (Approach A)
/// - For each file, extract all function declarations (name, is_public)
/// - For each file, extract all direct function calls (name)
/// - A function is "safe to convert" if no OTHER file calls it by name
///
/// Limitations (acceptable for Approach A):
/// - Does not resolve method calls (obj.method()) to specific types
/// - Does not track function pointers or comptime calls
/// - Does not resolve imports/aliases
/// - Conservatively rejects conversion if function name is ambiguous
const CallerEntry = struct {
    function_name: []const u8,
    files: std.StringHashMap(void),
};

pub const CallGraph = struct {
    allocator: std.mem.Allocator,

    /// Array of caller entries (function_name -> set of file paths)
    callers: std.ArrayList(CallerEntry),

    /// Map: "file_path#function_name" -> is_public (bool as u8)
    /// StringHashMap in Zig 0.16 requires caller to manage key memory
    declarations: std.StringHashMap(u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .callers = std.ArrayList(CallerEntry).empty,
            .declarations = std.StringHashMap(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up caller entries
        for (self.callers.items) |*entry| {
            self.allocator.free(entry.function_name);
            // Free file path keys in the files hashmap
            var file_it = entry.files.iterator();
            while (file_it.next()) |file_entry| {
                self.allocator.free(file_entry.key_ptr.*);
            }
            entry.files.deinit();
        }
        self.callers.deinit(self.allocator);

        // Free declaration keys
        var decl_it = self.declarations.iterator();
        while (decl_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.declarations.deinit();
    }

    /// Analyze all .zig files in the given list of paths.
    pub fn analyzeFiles(self: *Self, file_paths: []const []const u8) !void {
        for (file_paths) |path| {
            if (std.mem.endsWith(u8, path, ".zig")) {
                try self.analyzeFile(path);
            }
        }
    }

    /// Analyze a single .zig file given its source content.
    pub fn analyzeSource(self: *Self, source: []const u8, file_path: []const u8) !void {
        const source_z = try self.allocator.dupeZ(u8, source);
        defer self.allocator.free(source_z);

        var ast = try std.zig.Ast.parse(self.allocator, source_z, .zig);
        defer ast.deinit(self.allocator);

        // Extract function declarations
        try self.extractDeclarations(&ast, source, file_path);

        // Extract function calls
        try self.extractCalls(&ast, source, file_path);
    }

    /// Extract function declarations from AST.
    fn extractDeclarations(self: *Self, ast: *const std.zig.Ast, source: []const u8, file_path: []const u8) !void {
        const tags = ast.nodes.items(.tag);

        for (0..ast.nodes.len) |i| {
            const node: std.zig.Ast.Node.Index = @enumFromInt(i);
            const tag = tags[i];

            if (tag != .fn_decl) continue;

            // Get function prototype
            const data = ast.nodeData(node).node_and_node;
            const proto = data[0];

            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const fn_proto = switch (ast.nodeTag(proto)) {
                .fn_proto => ast.fnProto(proto),
                .fn_proto_multi => ast.fnProtoMulti(proto),
                .fn_proto_one => ast.fnProtoOne(&buffer, proto),
                .fn_proto_simple => ast.fnProtoSimple(&buffer, proto),
                else => continue,
            };

            // Get function name
            const name_token = fn_proto.name_token orelse continue;
            const name = ast.tokenSlice(name_token);

            // Check if public
            const main_tok = ast.nodeMainToken(proto);
            const fn_start = ast.tokens.items(.start)[main_tok];
            var fn_line_start = fn_start;
            while (fn_line_start > 0 and source[fn_line_start - 1] != '\n') {
                fn_line_start -= 1;
            }
            const fn_prefix = source[fn_line_start..fn_start];
            const is_public = std.mem.indexOf(u8, fn_prefix, "pub") != null;

            // Store declaration (key owned by hashmap, NOT copied by StringHashMap)
            const key = try std.fmt.allocPrint(self.allocator, "{s}#{s}", .{ file_path, name });
            try self.declarations.put(key, if (is_public) 1 else 0);
        }
    }

    /// Extract function calls from AST.
    fn extractCalls(self: *Self, ast: *const std.zig.Ast, source: []const u8, file_path: []const u8) !void {
        _ = source;
        const tags = ast.nodes.items(.tag);

        for (0..ast.nodes.len) |i| {
            const node: std.zig.Ast.Node.Index = @enumFromInt(i);
            const tag = tags[i];

            if (tag != .call and tag != .call_one) continue;

            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const call_info = switch (tag) {
                .call => ast.callFull(node),
                .call_one => ast.callOne(&buffer, node),
                else => continue,
            };

            const fn_expr = call_info.ast.fn_expr;
            const fn_name = try self.extractCallName(ast, fn_expr);

            if (fn_name.len == 0) {
                // Empty string is not allocated, no need to free
                continue;
            }

            // Record call
            // Find existing entry or create new one
            var found = false;
            for (self.callers.items) |*entry| {
                if (std.mem.eql(u8, entry.function_name, fn_name)) {
                    self.allocator.free(fn_name); // Free duplicate, entry already owns the name
                    // Duplicate file_path since StringHashMap doesn't copy keys
                    const duped_path = try self.allocator.dupe(u8, file_path);
                    try entry.files.put(duped_path, {});
                    found = true;
                    break;
                }
            }
            if (!found) {
                var new_set = std.StringHashMap(void).init(self.allocator);
                // Duplicate file_path since StringHashMap doesn't copy keys
                const duped_path = try self.allocator.dupe(u8, file_path);
                try new_set.put(duped_path, {});
                // fn_name ownership transferred to callers array
                try self.callers.append(self.allocator, .{
                    .function_name = fn_name,
                    .files = new_set,
                });
            }
        }
    }

    /// Extract a function name from a call expression.
    /// Returns allocated string (caller must free) or empty string.
    fn extractCallName(self: *Self, ast: *const std.zig.Ast, fn_expr: std.zig.Ast.Node.Index) ![]const u8 {
        const tag = ast.nodeTag(fn_expr);

        switch (tag) {
            .identifier => {
                const tok = ast.nodeMainToken(fn_expr);
                return self.allocator.dupe(u8, ast.tokenSlice(tok));
            },
            .field_access => {
                // For `obj.method()`, extract "method"
                const data = ast.nodeData(fn_expr).node_and_token;
                const field_tok = data[1];
                return self.allocator.dupe(u8, ast.tokenSlice(field_tok));
            },
            else => {
                return "";
            },
        }
    }

    /// Check if a function is safe to convert from *T to Box(T).
    /// A function is safe if:
    /// 1. It is declared in the given file
    /// 2. It is NOT public
    /// 3. It is NOT called from any other file
    /// 4. If called from the same file, that's OK
    pub fn isSafeToConvert(self: *Self, file_path: []const u8, function_name: []const u8) bool {
        // Check if declared in this file and is non-public
        const decl_key = std.fmt.allocPrint(self.allocator, "{s}#{s}", .{ file_path, function_name }) catch return false;
        defer self.allocator.free(decl_key);

        const is_public = self.declarations.get(decl_key) orelse return false;
        if (is_public != 0) return false;

        // Check if called from other files
        for (self.callers.items) |entry| {
            if (std.mem.eql(u8, entry.function_name, function_name)) {
                var it = entry.files.keyIterator();
                while (it.next()) |caller_file| {
                    if (!std.mem.eql(u8, caller_file.*, file_path)) {
                        return false; // Called from another file
                    }
                }
                return true; // Found entry, only called from same file (or not at all)
            }
        }

        return true; // No callers at all = safe
    }

    /// Debug: print statistics about the call graph.
    pub fn printStats(self: *Self) void {
        std.debug.print("CallGraph stats:\n", .{});
        std.debug.print("  Declarations: {d}\n", .{self.declarations.count()});
        std.debug.print("  Unique functions called: {d}\n", .{self.callers.items.len});

        var safe_count: usize = 0;
        var it = self.declarations.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            // Split key into file_path and function_name
            if (std.mem.indexOf(u8, key, "#")) |sep_pos| {
                const file_path = key[0..sep_pos];
                const function_name = key[sep_pos + 1 ..];
                if (self.isSafeToConvert(file_path, function_name)) {
                    safe_count += 1;
                }
            }
        }
        std.debug.print("  Safe-to-convert functions: {d}\n", .{safe_count});
    }
};

// ─── Tests ───

test "call graph: detects cross-file calls" {
    const allocator = std.testing.allocator;

    var cg = CallGraph.init(allocator);
    defer cg.deinit();

    // Simulate: file_a.zig declares `fn internal(ptr: *T)`, file_b.zig calls `internal()`
    const file_a = "/tmp/file_a.zig";
    const file_b = "/tmp/file_b.zig";

    // Manually insert declarations
    const key_a = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ file_a, "internal" });
    try cg.declarations.put(key_a, 0); // non-public

    // Manually insert call from file_b
    var caller_set = std.StringHashMap(void).init(allocator);
    const duped_file_b = try allocator.dupe(u8, file_b);
    try caller_set.put(duped_file_b, {});
    const fn_name = try allocator.dupe(u8, "internal");
    try cg.callers.append(allocator, .{
        .function_name = fn_name,
        .files = caller_set,
    });

    // Should NOT be safe (called from file_b)
    try std.testing.expect(!cg.isSafeToConvert(file_a, "internal"));

    // Should be safe if we check file_b (but it's not declared there)
    try std.testing.expect(!cg.isSafeToConvert(file_b, "internal"));
}

test "call graph: same-file calls are safe" {
    const allocator = std.testing.allocator;

    var cg = CallGraph.init(allocator);
    defer cg.deinit();

    const file_a = "/tmp/file_a.zig";

    // Declare internal function
    const key = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ file_a, "helper" });
    try cg.declarations.put(key, 0);

    // Call from same file
    var caller_set = std.StringHashMap(void).init(allocator);
    const duped_file_a = try allocator.dupe(u8, file_a);
    try caller_set.put(duped_file_a, {});
    const fn_name = try allocator.dupe(u8, "helper");
    try cg.callers.append(allocator, .{
        .function_name = fn_name,
        .files = caller_set,
    });

    // Should be safe (only called from same file)
    try std.testing.expect(cg.isSafeToConvert(file_a, "helper"));
}

test "call graph: public functions never safe" {
    const allocator = std.testing.allocator;

    var cg = CallGraph.init(allocator);
    defer cg.deinit();

    const file_a = "/tmp/file_a.zig";

    // Declare public function
    const key = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ file_a, "public_fn" });
    try cg.declarations.put(key, 1); // public

    // Not called anywhere
    // Should NOT be safe (public functions are never converted)
    try std.testing.expect(!cg.isSafeToConvert(file_a, "public_fn"));
}
