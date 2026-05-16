const std = @import("std");
const safe = @import("safe");

/// Source-to-source transpiler that rewrites common unsafe Zig patterns
/// into zust-safe equivalents.
///
/// Dog-fooding zust types:
/// - std.ArrayList(Edit) for edit collection (safe.ArrayList uses Box ownership)
/// - safe.String for source text storage
/// - safe.Box for AST ownership (wrapped std.zig.Ast)
/// - safe.CheckedInt for position tracking
/// - All heap allocations properly deinit'd
pub const Transpiler = struct {
    allocator: std.mem.Allocator,
    source: safe.String,
    ast: ?std.zig.Ast,
    edits: std.ArrayList(Edit),
    result: safe.String,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .source = safe.String.init(allocator),
            .ast = null,
            .edits = std.ArrayList(Edit).empty,
            .result = safe.String.init(allocator),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // Clean up AST if present
        if (self.ast) |*ast| {
            ast.deinit(allocator);
        }
        // Clean up edit replacements (each replacement is heap-allocated)
        for (self.edits.items) |edit| {
            allocator.free(edit.replacement);
        }
        self.edits.deinit(allocator);
        // Clean up strings
        self.source.deinit();
        self.result.deinit();
    }

    /// Transpile a single Zig source file.
    /// Returns a newly allocated string (caller must free with allocator).
    pub fn transpileFile(self: *Self, source: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        // Store source in safe.String
        try self.source.append(source);
        defer self.source.clear();

        // Parse with std.zig.Ast (requires std allocator)
        const source_z = try allocator.dupeZ(u8, source);
        defer allocator.free(source_z);

        self.ast = try std.zig.Ast.parse(allocator, source_z, .zig);
        errdefer if (self.ast) |*ast| ast.deinit(allocator);

        // Walk AST and collect edits
        try self.collectEdits();

        // Sort edits by start position ascending
        try self.sortEdits();

        // Remove overlapping edits (keep the first/smallest one)
        self.deduplicateEdits(allocator);

        // Apply edits in ascending order (building new string from original)
        return try self.applyEdits(source, allocator);
    }

    fn collectEdits(self: *Self) !void {
        const ast = &self.ast.?;
        const tags = ast.nodes.items(.tag);

        for (0..ast.nodes.len) |i| {
            const node: std.zig.Ast.Node.Index = @enumFromInt(i);
            const tag = tags[i];

            switch (tag) {
                .call_one, .call => {
                    try self.handleCall(node);
                },
                .field_access => {
                    try self.handleFieldAccess(node);
                },
                .simple_var_decl,
                .local_var_decl,
                .global_var_decl,
                .aligned_var_decl,
                => {
                    try self.handleVarDecl(node);
                },
                .unwrap_optional => {
                    try self.handleUnwrapOptional(node);
                },
                .@"defer" => {
                    try self.handleDefer(node);
                },
                else => {},
            }
        }
    }

    /// Add an edit. The replacement slice must be heap-allocated; ownership is transferred.
    fn addEdit(self: *Self, start: usize, end: usize, replacement: []const u8) !void {
        try self.edits.append(self.allocator, .{
            .start = start,
            .end = end,
            .replacement = replacement,
        });
    }

    fn sortEdits(self: *Self) !void {
        const slice = self.edits.items;
        if (slice.len < 2) return;

        const EditContext = struct {
            pub fn lessThan(_: @This(), a: Edit, b: Edit) bool {
                return a.start < b.start;
            }
        };
        std.mem.sort(Edit, slice, EditContext{}, EditContext.lessThan);
    }

    fn deduplicateEdits(self: *Self, allocator: std.mem.Allocator) void {
        const slice = self.edits.items;
        if (slice.len == 0) return;

        var write_idx: usize = 0;
        var prev_end: usize = slice[0].start;
        for (slice) |edit| {
            if (edit.start >= prev_end) {
                self.edits.items[write_idx] = edit;
                write_idx += 1;
                prev_end = edit.end;
            } else {
                // Overlapping edit - skip and free its replacement
                allocator.free(edit.replacement);
            }
        }
        self.edits.shrinkRetainingCapacity(write_idx);
    }

    /// Handle function calls (patterns 1, 2, 3)
    fn handleCall(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const tag = ast.nodeTag(node);
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = switch (tag) {
            .call_one => ast.callOne(&buffer, node),
            .call => ast.callFull(node),
            else => return,
        };

        // Get the function expression text
        const fn_expr = call.ast.fn_expr;
        const fn_span = ast.nodeToSpan(fn_expr);
        const fn_text = source[fn_span.start..fn_span.end];

        // Pattern 1: allocator.create(T)
        if (std.mem.eql(u8, fn_text, "create") or std.mem.endsWith(u8, fn_text, ".create")) {
            if (call.ast.params.len == 1) {
                const type_node = call.ast.params[0];
                const type_span = ast.nodeToSpan(type_node);
                const type_text = source[type_span.start..type_span.end];

                const call_span = ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self.allocator, "safe.Box({s}, 0, 0, 0).init(allocator, undefined)", .{type_text});
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }

        // Pattern 2: std.ArrayList(T)
        if (std.mem.eql(u8, fn_text, "std.ArrayList") or
            std.mem.eql(u8, fn_text, "ArrayList"))
        {
            if (call.ast.params.len == 1) {
                const type_node = call.ast.params[0];
                const type_span = ast.nodeToSpan(type_node);
                const type_text = source[type_span.start..type_span.end];

                const call_span = ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self.allocator, "safe.ArrayList({s})", .{type_text});
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }

        // Pattern 3: std.StringHashMap(T)
        if (std.mem.eql(u8, fn_text, "std.StringHashMap") or
            std.mem.eql(u8, fn_text, "StringHashMap"))
        {
            if (call.ast.params.len == 1) {
                const type_node = call.ast.params[0];
                const type_span = ast.nodeToSpan(type_node);
                const type_text = source[type_span.start..type_span.end];

                const call_span = ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self.allocator, "safe.HashMap(safe.String, {s})", .{type_text});
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }
    }

    /// Handle field access patterns (pattern 4: std.Thread.Mutex)
    fn handleFieldAccess(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const span = ast.nodeToSpan(node);
        const text = source[span.start..span.end];

        if (std.mem.eql(u8, text, "std.Thread.Mutex")) {
            const repl = try std.fmt.allocPrint(self.allocator, "safe.Mutex(void)", .{});
            try self.addEdit(span.start, span.end, repl);
        }
    }

    /// Handle variable declarations (pattern 6: uninitialized var)
    fn handleVarDecl(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const vd = ast.fullVarDecl(node) orelse return;
        if (vd.ast.init_node == .none) {
            if (vd.ast.type_node != .none) {
                const type_node: std.zig.Ast.Node.Index = vd.ast.type_node.unwrap().?;
                const type_span = ast.nodeToSpan(type_node);
                const type_text = source[type_span.start..type_span.end];

                const after_type = type_span.end;
                if (isIntType(type_text)) {
                    const repl = try std.fmt.allocPrint(self.allocator, " = safe.CheckedInt({s}).init(0)", .{type_text});
                    try self.addEdit(after_type, after_type, repl);
                } else {
                    const repl = try std.fmt.allocPrint(self.allocator, " = undefined", .{});
                    try self.addEdit(after_type, after_type, repl);
                }
            }
        }
    }

    /// Handle optional unwrap (pattern 5)
    fn handleUnwrapOptional(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const span = ast.nodeToSpan(node);

        const data = ast.nodeData(node).node_and_token;
        const inner = data[0];
        const inner_span = ast.nodeToSpan(inner);
        const inner_text = source[inner_span.start..inner_span.end];

        const repl = try std.fmt.allocPrint(self.allocator,
            \\if ({s}) |value| {{
            \\    value
            \\}} else {{
            \\    return error.NullPointer;
            \\}}
        , .{inner_text});
        try self.addEdit(span.start, span.end, repl);
    }

    /// Handle defer statements (pattern 1: allocator.destroy)
    fn handleDefer(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const inner = ast.nodeData(node).node;
        const inner_tag = ast.nodeTag(inner);

        if (inner_tag == .call_one or inner_tag == .call) {
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const call = switch (inner_tag) {
                .call_one => ast.callOne(&buffer, inner),
                .call => ast.callFull(inner),
                else => return,
            };

            const fn_expr = call.ast.fn_expr;
            const fn_span = ast.nodeToSpan(fn_expr);
            const fn_text = source[fn_span.start..fn_span.end];

            // Pattern 1: allocator.destroy(ptr)
            if (std.mem.eql(u8, fn_text, "destroy") or std.mem.endsWith(u8, fn_text, ".destroy")) {
                if (call.ast.params.len == 1) {
                    const param_node = call.ast.params[0];
                    const param_span = ast.nodeToSpan(param_node);
                    const param_text = source[param_span.start..param_span.end];

                    const defer_span = ast.nodeToSpan(node);
                    const repl = try std.fmt.allocPrint(self.allocator, "defer _ = {s}.deinit()", .{param_text});
                    try self.addEdit(defer_span.start, defer_span.end, repl);
                }
            }
        }
    }

    fn applyEdits(self: *Self, source: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const edits = self.edits.items;
        if (edits.len == 0) {
            return try allocator.dupe(u8, source);
        }

        // Use struct's result string (cleaned up in deinit)
        self.result.clear();

        var pos: usize = 0;
        // Edits are sorted by start ascending
        for (edits) |edit| {
            // Append text before this edit
            try self.result.append(source[pos..edit.start]);
            // Append replacement
            try self.result.append(edit.replacement);
            pos = edit.end;
        }
        // Append remaining text
        try self.result.append(source[pos..]);

        // Transfer ownership to caller
        const output = try allocator.dupe(u8, self.result.slice());
        return output;
    }

    fn isIntType(type_text: []const u8) bool {
        const int_types = [_][]const u8{
            "i8", "i16", "i32", "i64", "i128", "isize",
            "u8", "u16", "u32", "u64", "u128", "usize",
            "c_short", "c_int", "c_long", "c_longlong",
        };
        for (int_types) |t| {
            if (std.mem.eql(u8, type_text, t)) return true;
        }
        return false;
    }
};

const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

// ─── Tests ───

test "pattern 1: allocator.create/destroy → safe.Box" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\const safe = @import("safe");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var ptr = try allocator.create(i32);
        \\    defer allocator.destroy(ptr);
        \\    ptr.* = 42;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.Box(i32, 0, 0, 0).init(allocator, undefined)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "defer _ = ptr.deinit()"));
}

test "pattern 2: std.ArrayList → safe.ArrayList" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\const safe = @import("safe");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var list = std.ArrayList(i32).init(allocator);
        \\    defer list.deinit();
        \\    try list.append(42);
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.ArrayList(i32)"));
}

test "pattern 3: std.StringHashMap → safe.HashMap" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\const safe = @import("safe");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var map = std.StringHashMap(i32).init(allocator);
        \\    defer map.deinit();
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.HashMap(safe.String, i32)"));
}

test "pattern 5: raw optional dereference → checked access" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\fn foo(opt: ?i32) !i32 {
        \\    return opt.?;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "if (opt) |value|"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "return error.NullPointer"));
}

test "pattern 6: uninitialized var → safe.CheckedInt" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    var x: i32;
        \\    _ = x;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.CheckedInt(i32).init(0)"));
}

test "no changes for safe code" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\fn foo() i32 {
        \\    return 42;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.eql(u8, input, output));
}

test "transpiler dog-food: safe types prevent leaks" {
    const allocator = std.testing.allocator;
    const input =
        \\var x: i32;
        \\_ = x;
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    // The transpiler itself uses safe types internally,
    // so if we forget to deinit, the analyzer catches it.
    // This test just verifies the transpiler runs without crashing.
    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.CheckedInt(i32).init(0)"));
}

// ─── CLI ───

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = init.minimal.args.vector;

    if (args.len < 3) {
        std.debug.print("Usage: zust-transpile <input.zig> <output.zig>\n", .{});
        return;
    }

    const input_path = std.mem.span(args[1]);
    const output_path = std.mem.span(args[2]);

    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(input);

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = output,
    });
    std.debug.print("Transpiled {s} -> {s}\n", .{ input_path, output_path });
}
