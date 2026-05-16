const std = @import("std");
const safe = @import("safe");

/// Source-to-source transpiler that rewrites common unsafe Zig patterns
/// into zust-safe equivalents.
pub const Transpiler = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    ast: std.zig.Ast,
    edits: std.ArrayList(Edit),

    pub fn init(allocator: std.mem.Allocator) Transpiler {
        return .{
            .allocator = allocator,
            .source = &.{},
            .ast = undefined,
            .edits = std.ArrayList(Edit).empty,
        };
    }

    pub fn deinit(self: *Transpiler) void {
        for (self.edits.items) |edit| {
            self.allocator.free(edit.replacement);
        }
        self.edits.deinit(self.allocator);
        if (self.source.len > 0) {
            self.ast.deinit(self.allocator);
        }
    }

    /// Transpile a single Zig source file.
    pub fn transpileFile(self: *Transpiler, source: []const u8) ![]const u8 {
        self.source = source;
        const source_z = try self.allocator.dupeZ(u8, source);
        defer self.allocator.free(source_z);
        self.ast = try std.zig.Ast.parse(self.allocator, source_z, .zig);
        errdefer self.ast.deinit(self.allocator);

        // Walk AST and collect edits
        try self.collectEdits();

        // Sort edits by start position ascending
        const EditContext = struct {
            pub fn lessThan(_: @This(), a: Edit, b: Edit) bool {
                return a.start < b.start;
            }
        };
        std.mem.sort(Edit, self.edits.items, EditContext{}, EditContext.lessThan);

        // Remove overlapping edits (keep the first/smallest one)
        self.deduplicateEdits();

        // Apply edits in ascending order (building new string from original)
        return try self.applyEdits();
    }

    fn collectEdits(self: *Transpiler) !void {
        const tags = self.ast.nodes.items(.tag);

        for (0..self.ast.nodes.len) |i| {
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
    fn addEdit(self: *Transpiler, start: usize, end: usize, replacement: []const u8) !void {
        try self.edits.append(self.allocator, .{
            .start = start,
            .end = end,
            .replacement = replacement,
        });
    }

    fn deduplicateEdits(self: *Transpiler) void {
        if (self.edits.items.len == 0) return;
        var write_idx: usize = 0;
        var prev_end: usize = self.edits.items[0].start;
        for (self.edits.items) |edit| {
            if (edit.start >= prev_end) {
                self.edits.items[write_idx] = edit;
                write_idx += 1;
                prev_end = edit.end;
            } else {
                // Overlapping edit - skip and free its replacement
                self.allocator.free(edit.replacement);
            }
        }
        self.edits.shrinkRetainingCapacity(write_idx);
    }

    /// Handle function calls (patterns 1, 2, 3)
    fn handleCall(self: *Transpiler, node: std.zig.Ast.Node.Index) !void {
        const tag = self.ast.nodeTag(node);
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = switch (tag) {
            .call_one => self.ast.callOne(&buffer, node),
            .call => self.ast.callFull(node),
            else => return,
        };

        // Get the function expression text
        const fn_expr = call.ast.fn_expr;
        const fn_span = self.ast.nodeToSpan(fn_expr);
        const fn_text = self.source[fn_span.start..fn_span.end];

        // Pattern 1: allocator.create(T)
        if (std.mem.eql(u8, fn_text, "create") or std.mem.endsWith(u8, fn_text, ".create")) {
            if (call.ast.params.len == 1) {
                const type_node = call.ast.params[0];
                const type_span = self.ast.nodeToSpan(type_node);
                const type_text = self.source[type_span.start..type_span.end];

                const call_span = self.ast.nodeToSpan(node);
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
                const type_span = self.ast.nodeToSpan(type_node);
                const type_text = self.source[type_span.start..type_span.end];

                const call_span = self.ast.nodeToSpan(node);
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
                const type_span = self.ast.nodeToSpan(type_node);
                const type_text = self.source[type_span.start..type_span.end];

                const call_span = self.ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self.allocator, "safe.HashMap(safe.String, {s})", .{type_text});
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }
    }

    /// Handle field access patterns (pattern 4: std.Thread.Mutex)
    fn handleFieldAccess(self: *Transpiler, node: std.zig.Ast.Node.Index) !void {
        const span = self.ast.nodeToSpan(node);
        const text = self.source[span.start..span.end];

        if (std.mem.eql(u8, text, "std.Thread.Mutex")) {
            // Find if this field_access is followed by {} struct init
            // For now, we replace the field_access with safe.Mutex(void)
            const repl = try std.fmt.allocPrint(self.allocator, "safe.Mutex(void)", .{});
            try self.addEdit(span.start, span.end, repl);
        }
    }

    /// Handle variable declarations (pattern 6: uninitialized var)
    fn handleVarDecl(self: *Transpiler, node: std.zig.Ast.Node.Index) !void {
        const vd = self.ast.fullVarDecl(node) orelse return;
        if (vd.ast.init_node == .none) {
            if (vd.ast.type_node != .none) {
                const type_node: std.zig.Ast.Node.Index = vd.ast.type_node.unwrap().?;
                const type_span = self.ast.nodeToSpan(type_node);
                const type_text = self.source[type_span.start..type_span.end];

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
    fn handleUnwrapOptional(self: *Transpiler, node: std.zig.Ast.Node.Index) !void {
        const span = self.ast.nodeToSpan(node);

        // unwrap_optional data is .node_and_token
        const data = self.ast.nodeData(node).node_and_token;
        const inner = data[0];
        const inner_span = self.ast.nodeToSpan(inner);
        const inner_text = self.source[inner_span.start..inner_span.end];

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
    fn handleDefer(self: *Transpiler, node: std.zig.Ast.Node.Index) !void {
        const inner = self.ast.nodeData(node).node;
        const inner_tag = self.ast.nodeTag(inner);

        if (inner_tag == .call_one or inner_tag == .call) {
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const call = switch (inner_tag) {
                .call_one => self.ast.callOne(&buffer, inner),
                .call => self.ast.callFull(inner),
                else => return,
            };

            const fn_expr = call.ast.fn_expr;
            const fn_span = self.ast.nodeToSpan(fn_expr);
            const fn_text = self.source[fn_span.start..fn_span.end];

            // Pattern 1: allocator.destroy(ptr)
            if (std.mem.eql(u8, fn_text, "destroy") or std.mem.endsWith(u8, fn_text, ".destroy")) {
                if (call.ast.params.len == 1) {
                    const param_node = call.ast.params[0];
                    const param_span = self.ast.nodeToSpan(param_node);
                    const param_text = self.source[param_span.start..param_span.end];

                    const defer_span = self.ast.nodeToSpan(node);
                    const repl = try std.fmt.allocPrint(self.allocator, "defer _ = {s}.deinit()", .{param_text});
                    try self.addEdit(defer_span.start, defer_span.end, repl);
                }
            }
        }
    }

    fn applyEdits(self: *Transpiler) ![]const u8 {
        const edits = self.edits.items;
        if (edits.len == 0) {
            return try self.allocator.dupe(u8, self.source);
        }

        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);

        var pos: usize = 0;
        // Edits are sorted by start ascending
        for (edits) |edit| {
            // Append text before this edit
            try result.appendSlice(self.allocator, self.source[pos..edit.start]);
            // Append replacement
            try result.appendSlice(self.allocator, edit.replacement);
            pos = edit.end;
        }
        // Append remaining text
        try result.appendSlice(self.allocator, self.source[pos..]);

        return try result.toOwnedSlice(self.allocator);
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
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input);
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
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input);
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
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input);
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
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input);
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
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input);
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
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input);
    defer allocator.free(output);

    try std.testing.expect(std.mem.eql(u8, input, output));
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
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input);
    defer allocator.free(output);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = output,
    });
    std.debug.print("Transpiled {s} -> {s}\n", .{ input_path, output_path });
}
