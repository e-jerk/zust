const std = @import("std");
const safe = @import("safe");
const Box = safe.Box;
const LinkedList = safe.LinkedList;
const Provenance = @import("Provenance.zig");
const Diagnostic = @import("Diagnostics.zig");
const Contract = @import("Contract.zig");
const zig = std.zig;

// The analyzer dog-foods zust's ownership primitives where they fit naturally.
//
// DOGFOODED:
// - safe.Box: parsed AST lifecycle (single owner, explicit deinit)
// - safe.LinkedList: tracked_pointers (ownership tracking, each node is a safe.Box)
// - safe.String: LSP message envelope building (see JSONRPC.zig)
//
// KEPT AS std (with justification):
// - std.ArrayList(Diagnostic.Diagnostic): diagnostics buffer needs indexed
//   non-removing access; safe.ArrayList stores Box(T) and get() removes
// - std.StringHashMap(VarState): variable registry needs string keys;
//   safe.HashMap uses u64 keys
// - std.StringHashMap(FunctionInfo): function registry needs string keys;
//   safe.HashMap uses u64 keys
// - []const u8: file paths and source text are borrowed slices, not owned strings

/// Pointer origin tracking for a variable.
const PtrOrigin = union(enum) {
    None,
    Box: struct {
        var_name: []const u8,
        decl_line: u32,
    },
    Borrow: struct {
        var_name: []const u8,
        is_mutable: bool,
    },
    RawFromBox: struct {
        box_var: []const u8,
        unsafe_ptr_line: u32,
    },
};

const TypeCategory = enum {
    Box, Rc, Arc, Weak, Mutex, RwLock, Cell, RefCell,
    ManuallyDrop, MaybeUninit, Pin, OnceCell, LazyCell, OnceBox,
    Channel, Oneshot, String, HashMap, BTreeMap, HashSet,
    BinaryHeap, VecDeque, LinkedList, ArrayList, UnsafeCell,
    Raw, Unknown,
};

/// State of a variable that holds a pointer or Box.
const VarState = struct {
    name: []const u8,
    is_box: bool,
    is_live: bool,
    origin: PtrOrigin,
    decl_line: u32,
    decl_col: u32,
    type_category: TypeCategory = .Unknown,
    // Type-specific state flags:
    is_dropped: bool = false,        // For ManuallyDrop: has drop() been called?
    is_locked: bool = false,         // For Mutex/RwLock: is currently locked?
    is_initialized: bool = false,    // For OnceCell/MaybeUninit
    is_closed: bool = false,         // For Channel
    is_sent: bool = false,           // For Oneshot
};

/// Information about a function's signature for cross-function analysis.
const FunctionInfo = struct {
    name: []const u8,
    /// Does this function take any raw pointer parameters?
    has_raw_pointer_params: bool,
    /// Does this function return a raw pointer?
    returns_raw_pointer: bool,
    /// Number of parameters
    param_count: usize,
    /// Parameter types (simplified: true if raw pointer/slice)
    param_is_raw_pointer: []const bool,
    /// Has @safe(nocapture) annotation?
    has_nocapture_annotation: bool = false,
    /// Ownership contract for return value
    return_ownership: Contract.Ownership = .unknown,
    /// Ownership contracts for parameters (index 0..7, fixed buffer)
    param_contracts: [8]Contract.Ownership = .{.unknown} ** 8,
};

/// Main analysis engine.
pub const Analyzer = struct {
    gpa: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic.Diagnostic),
    variables: std.StringHashMap(VarState),
    tracked_pointers: LinkedList(Provenance.PointerValue),
    next_ptr_id: u32,
    /// Registry of function signatures for cross-function analysis
    functions: std.StringHashMap(FunctionInfo),
    /// Current analysis strictness level
    strictness: Strictness = .Medium,

    pub fn init(gpa: std.mem.Allocator) Analyzer {
        return .{
            .gpa = gpa,
            .diagnostics = .empty,
            .variables = std.StringHashMap(VarState).init(gpa),
            .tracked_pointers = LinkedList(Provenance.PointerValue).init(gpa),
            .next_ptr_id = 0,
            .functions = std.StringHashMap(FunctionInfo).init(gpa),
            .strictness = .Medium,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.diagnostics.deinit(self.gpa);
        self.tracked_pointers.deinit();
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.variables.deinit();
        var fn_iter = self.functions.iterator();
        while (fn_iter.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.param_is_raw_pointer);
        }
        self.functions.deinit();
    }

    /// Track a new pointer allocation using safe.LinkedList (each node is a safe.Box).
    pub fn trackAllocation(self: *Analyzer, prov: Provenance.Provenance) !u32 {
        const id = self.next_ptr_id;
        self.next_ptr_id += 1;
        try self.tracked_pointers.push(.{
            .id = id,
            .prov = prov,
            .ty = "*u8",
            .is_live = true,
        });
        return id;
    }

    /// Mark a pointer as deallocated by scanning the safe list.
    pub fn markDeallocated(self: *Analyzer, ptr_id: u32, site: Provenance.SourceLocation) void {
        _ = site;
        self.tracked_pointers.forEachMut(&ptr_id, struct {
            fn f(target_id: *const u32, ptr: *Provenance.PointerValue) void {
                if (ptr.id == target_id.*) {
                    ptr.is_live = false;
                }
            }
        }.f);
    }

    /// Check if using a pointer at a given site is valid.
    pub fn checkUse(self: *Analyzer, ptr_id: u32, use_site: Provenance.SourceLocation) !void {
        var ctx = .{ .ptr_id = ptr_id, .use_site = use_site, .self = self };
        self.tracked_pointers.forEach(&ctx, struct {
            fn f(c: *const @TypeOf(ctx), ptr: *const Provenance.PointerValue) void {
                if (ptr.id == c.ptr_id and !ptr.is_live) {
                    c.self.diagnostics.append(c.self.gpa, .{
                        .kind = .UseAfterFree,
                        .message = "use of dangling pointer",
                        .location = c.use_site,
                        .notes = &.{},
                        .severity = .Error,
                    }) catch {};
                }
            }
        }.f);
    }

    pub const Strictness = enum { Low, Medium, High };

    pub const WorkspaceFile = struct {
        path: []const u8,
        source: []const u8,
    };

    /// Parse and analyze a Zig source file.
    pub fn analyzeFile(self: *Analyzer, file_path: []const u8, source: []const u8, strictness: Strictness) !void {
        // For single-file analysis, clear everything including the function registry
        self.clearVariables();
        self.clearFunctions();
        try self.analyzeFileWithRegistry(file_path, source, strictness);
    }

    pub fn analyzeWorkspace(self: *Analyzer, files: []const WorkspaceFile, strictness: Strictness) !void {
        // Phase 1: Build combined function registry from all files
        self.clearFunctions();
        for (files) |file| {
            try self.buildRegistryForFile(file.path, file.source);
        }

        // Phase 2: Analyze each file with the combined registry
        for (files) |file| {
            self.clearVariables();
            try self.analyzeFileWithRegistry(file.path, file.source, strictness);
        }
    }

    fn clearVariables(self: *Analyzer) void {
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.variables.clearRetainingCapacity();
    }

    fn clearFunctions(self: *Analyzer) void {
        var fn_iter = self.functions.iterator();
        while (fn_iter.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.param_is_raw_pointer);
        }
        self.functions.clearRetainingCapacity();
    }

    fn buildRegistryForFile(self: *Analyzer, file_path: []const u8, source: []const u8) !void {
        const source_z = try self.gpa.dupeZ(u8, source);
        defer self.gpa.free(source_z);

        var ast_box = try Box(std.zig.Ast, 0, 0, 0).init(self.gpa, undefined);
        ast_box.ptr.* = try std.zig.Ast.parse(self.gpa, source_z, .zig);
        defer {
            ast_box.ptr.deinit(self.gpa);
            const dead = ast_box.deinit();
            _ = dead;
        }

        if (ast_box.ptr.errors.len > 0) return;

        const decls = ast_box.ptr.rootDecls();
        for (decls) |decl| {
            const tag = ast_box.ptr.nodes.items(.tag)[@intFromEnum(decl)];
            if (tag == .fn_decl) {
                try self.buildFunctionRegistry(file_path, ast_box.ptr, @intFromEnum(decl));
            }
        }
    }

    fn analyzeFileWithRegistry(self: *Analyzer, file_path: []const u8, source: []const u8, strictness: Strictness) !void {
        self.strictness = strictness;

        // Parse the source into an AST, managed by safe.Box for single ownership
        const source_z = try self.gpa.dupeZ(u8, source);
        defer self.gpa.free(source_z);

        var ast_box = try Box(std.zig.Ast, 0, 0, 0).init(self.gpa, undefined);
        ast_box.ptr.* = try std.zig.Ast.parse(self.gpa, source_z, .zig);
        // Ensure Ast is deinit'd exactly once via Box ownership
        defer {
            ast_box.ptr.deinit(self.gpa);
            const dead = ast_box.deinit();
            _ = dead;
        }

        if (ast_box.ptr.errors.len > 0) {
            try self.diagnostics.append(self.gpa, .{
                .kind = .UseAfterFree,
                .message = "parse errors in source file",
                .location = .{
                    .file = file_path,
                    .line = 1,
                    .column = 1,
                },
                .notes = &.{},
                .severity = .Error,
            });
            return;
        }

        // Pass 1: Build function signature registry (for single-file mode this was already done)
        // In workspace mode, this is a no-op because registry is already populated
        const decls = ast_box.ptr.rootDecls();
        for (decls) |decl| {
            const tag = ast_box.ptr.nodes.items(.tag)[@intFromEnum(decl)];
            if (tag == .fn_decl) {
                try self.buildFunctionRegistry(file_path, ast_box.ptr, @intFromEnum(decl));
            }
        }

        // Pass 2: Analyze all function bodies with cross-function knowledge
        for (decls) |decl| {
            const tag = ast_box.ptr.nodes.items(.tag)[@intFromEnum(decl)];
            if (tag == .fn_decl) {
                try self.analyzeFnDecl(file_path, ast_box.ptr, @intFromEnum(decl));
            }
        }
    }

    /// Pass 1: Extract function signature information for cross-function analysis.
    fn buildFunctionRegistry(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, fn_node: u32) !void {
        const data = ast.nodes.items(.data)[fn_node];
        const proto_node = data.node_and_node[0];
        const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(proto_node)]);

        var fn_proto_buffer: [1]zig.Ast.Node.Index = undefined;
        if (ast.fullFnProto(&fn_proto_buffer, proto_node)) |fn_proto| {
            // Get function name
            const fn_name = if (fn_proto.name_token) |name_tok|
                ast.tokenSlice(name_tok)
            else
                "anonymous";

            // Check return type
            var returns_raw = false;
            if (fn_proto.ast.return_type.unwrap()) |return_type| {
                returns_raw = isRawPointerType(ast, return_type) or isSliceType(ast, return_type);
                // Check if function has ownership contract declaring return as owned
                // (This requires looking for doc comments first, done below)
            }

            // Check parameters
            var has_raw_params = false;
            var param_raw_flags = try self.gpa.alloc(bool, fn_proto.ast.params.len);
            var param_idx: usize = 0;

            var param_it = fn_proto.iterate(ast);
            while (param_it.next()) |param| : (param_idx += 1) {
                if (param.type_expr) |type_expr| {
                    const is_raw = isRawPointerType(ast, type_expr) or isSliceType(ast, type_expr);
                    param_raw_flags[param_idx] = is_raw;
                    if (is_raw) {
                        has_raw_params = true;
                        const param_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(type_expr)]);
                        try self.addDiagnostic(file_path, .UseAfterFree, "function parameter uses raw pointer/slice type; consider using safe.Box(T, 0, 0, 0)", @intCast(param_loc.line), @intCast(param_loc.column));
                    }
                } else {
                    param_raw_flags[param_idx] = false;
                }
            }

            // Check for ownership contract annotations in doc comments
            var has_nocapture = false;
            var doc_token: ?zig.Ast.TokenIndex = null;
            
            // Look for doc comments before the fn token
            const fn_token = fn_proto.ast.fn_token;
            if (fn_token > 0) {
                var tok_idx = fn_token;
                // Walk backwards looking for doc comments
                while (tok_idx > 0) {
                    tok_idx -= 1;
                    const tag = ast.tokens.items(.tag)[tok_idx];
                    if (tag == .doc_comment) {
                        doc_token = tok_idx;
                        break;
                    } else if (tag != .identifier and tag != .period and tag != .keyword_pub and tag != .keyword_extern and tag != .keyword_export and tag != .keyword_inline and tag != .keyword_noinline) {
                        break;
                    }
                }
            }
            
            var return_ownership: Contract.Ownership = .unknown;
            var param_contracts: [8]Contract.Ownership = .{.unknown} ** 8;
            if (doc_token) |dt| {
                const doc_text = ast.tokenSlice(dt);
                var contract_buf: [8]Contract.ParamContract = undefined;
                if (Contract.parseContract(doc_text, &contract_buf)) |contract| {
                    if (contract.nocapture) {
                        has_nocapture = true;
                    }
                    return_ownership = contract.return_ownership;
                    for (contract.params, 0..) |pc, i| {
                        if (i < 8) param_contracts[i] = pc.ownership;
                    }
                }
            }

            // Emit return type warning (after contract check so we can skip if contract says owned)
            if (returns_raw and return_ownership != .owned) {
                try self.addDiagnostic(file_path, .UseAfterFree, "function returns raw pointer/slice; consider returning safe.Box(T, 0, 0, 0) instead", @intCast(token_loc.line), @intCast(token_loc.column));
            }

            // Store in registry (only if it has a real name)
            if (!std.mem.eql(u8, fn_name, "anonymous")) {
                if (self.functions.contains(fn_name)) {
                    // Already registered (e.g., second pass or workspace mode)
                    self.gpa.free(param_raw_flags);
                } else {
                    const name_copy = try self.gpa.dupe(u8, fn_name);
                    try self.functions.put(name_copy, .{
                        .name = name_copy,
                        .has_raw_pointer_params = has_raw_params,
                        .returns_raw_pointer = returns_raw,
                        .param_count = fn_proto.ast.params.len,
                        .param_is_raw_pointer = param_raw_flags,
                        .has_nocapture_annotation = has_nocapture,
                        .return_ownership = return_ownership,
                        .param_contracts = param_contracts,
                    });
                }
            } else {
                self.gpa.free(param_raw_flags);
            }
        }
    }

    fn analyzeFnDecl(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, fn_node: u32) !void {
        const data = ast.nodes.items(.data)[fn_node];
        const body_node = data.node_and_node[1];

        // Check return type for raw pointers
        const proto_node = data.node_and_node[0];
        const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(proto_node)]);
        var fn_proto_buffer: [1]zig.Ast.Node.Index = undefined;
        if (ast.fullFnProto(&fn_proto_buffer, proto_node)) |fn_proto| {
            const fn_name_here = if (fn_proto.name_token) |name_tok| ast.tokenSlice(name_tok) else "anonymous";
            if (fn_proto.ast.return_type.unwrap()) |return_type| {
                if (isRawPointerType(ast, return_type) or isSliceType(ast, return_type)) {
                    // Check if function has ownership contract declaring return as owned
                    var skip_warning = false;
                    if (self.functions.get(fn_name_here)) |fn_info| {
                        if (fn_info.return_ownership == .owned) {
                            skip_warning = true;
                        }
                    }
                    if (!skip_warning) {
                        try self.addDiagnostic(file_path, .UseAfterFree, "function returns raw pointer/slice; consider returning safe.Box(T, 0, 0, 0) instead", @intCast(token_loc.line), @intCast(token_loc.column));
                    }
                }
            }
            // Check parameters for raw pointer types
            var param_it = fn_proto.iterate(ast);
            while (param_it.next()) |param| {
                if (param.type_expr) |type_expr| {
                    if (isRawPointerType(ast, type_expr) or isSliceType(ast, type_expr)) {
                        const param_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(type_expr)]);
                        try self.addDiagnostic(file_path, .UseAfterFree, "function parameter uses raw pointer/slice type; consider using safe.Box(T, 0, 0, 0)", @intCast(param_loc.line), @intCast(param_loc.column));
                    }
                }
            }
        }

        // Clear variable state for this function
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.variables.clearRetainingCapacity();

        // Analyze the function body
        try self.analyzeBlock(file_path, ast, body_node);

        // Check for leaks and unclosed resources at end of function
        var var_iter = self.variables.iterator();
        while (var_iter.next()) |entry| {
            const var_state = entry.value_ptr;
            if (var_state.type_category == .ManuallyDrop and !var_state.is_dropped) {
                try self.addDiagnostic(file_path, .MemoryLeak, "ManuallyDrop not explicitly dropped before end of scope; call .drop() or .take()", var_state.decl_line, var_state.decl_col);
            }
            if ((var_state.type_category == .Mutex or var_state.type_category == .RwLock) and var_state.is_locked) {
                try self.addDiagnostic(file_path, .Deadlock, "Mutex/RwLock left locked at end of function; ensure unlock() is called", var_state.decl_line, var_state.decl_col);
            }
        }
    }

    const AnalyzeError = error{OutOfMemory};

    fn analyzeBlock(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, block_node: zig.Ast.Node.Index) AnalyzeError!void {
        const tag = ast.nodes.items(.tag)[@intFromEnum(block_node)];

        switch (tag) {
            .block_two, .block_two_semicolon => {
                const data = ast.nodes.items(.data)[@intFromEnum(block_node)];
                if (data.opt_node_and_opt_node[0].unwrap()) |stmt0| try self.analyzeStatement(file_path, ast, stmt0);
                if (data.opt_node_and_opt_node[1].unwrap()) |stmt1| try self.analyzeStatement(file_path, ast, stmt1);
            },
            .block, .block_semicolon => {
                const data = ast.nodes.items(.data)[@intFromEnum(block_node)];
                const extra = ast.extra_data[@intFromEnum(data.extra_range.start)..@intFromEnum(data.extra_range.end)];
                for (extra) |stmt_idx| {
                    try self.analyzeStatement(file_path, ast, @enumFromInt(stmt_idx));
                }
            },
            else => {
                // Single statement
                try self.analyzeStatement(file_path, ast, block_node);
            },
        }
    }

    fn analyzeStatement(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, stmt: zig.Ast.Node.Index) AnalyzeError!void {
        const tag = ast.nodes.items(.tag)[@intFromEnum(stmt)];

        switch (tag) {
            .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                try self.analyzeVarDecl(file_path, ast, stmt);
            },
            .assign => {
                try self.analyzeAssign(file_path, ast, stmt);
            },
            .call, .call_comma, .call_one, .call_one_comma => {
                try self.analyzeCall(file_path, ast, stmt);
            },
            .block_two, .block_two_semicolon, .block, .block_semicolon => {
                try self.analyzeBlock(file_path, ast, stmt);
            },
            .if_simple => {
                try self.analyzeIf(file_path, ast, stmt);
            },
            .while_simple, .while_cont => {
                try self.analyzeWhile(file_path, ast, stmt);
            },
            .for_simple, .for_range => {
                try self.analyzeFor(file_path, ast, stmt);
            },
            .@"errdefer" => {
                // Errdefer body executes only on error paths.
                // We analyze it to catch error-path deallocations.
                const data = ast.nodes.items(.data)[@intFromEnum(stmt)];
                const body = data.opt_token_and_node[1];
                // Save current state so errdefer analysis is isolated
                var saved = try self.cloneVariables();
                defer saved.deinit();
                try self.analyzeBlock(file_path, ast, body);
                // Restore state: errdefer only runs on error, not normal path
                try self.restoreVariables(saved);
            },
            else => {
                // Other statements - try to find any calls within them
                try self.findCallsInExpr(file_path, ast, stmt);
                // Check for raw pointer dereferences
                try self.checkDerefs(file_path, ast, stmt);
            },
        }
    }

    fn analyzeVarDecl(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const main_token = ast.nodes.items(.main_token)[@intFromEnum(node)];
        const decl_name = ast.tokenSlice(main_token + 1); // skip 'var'/'const'
        const token_loc = ast.tokenLocation(0, main_token + 1);

        // Check if the type annotation is a raw pointer type
        if (ast.fullVarDecl(node)) |var_decl| {
            if (var_decl.ast.type_node.unwrap()) |type_node| {
                if (isRawPointerType(ast, type_node) or isSliceType(ast, type_node)) {
                    try self.addDiagnostic(file_path, .UseAfterFree, "raw pointer/slice type in variable declaration; consider using safe.Box(T, 0, 0, 0) instead", @intCast(token_loc.line), @intCast(token_loc.column));
                }
            }
        }

        // Get init expression
        const data = ast.nodes.items(.data)[@intFromEnum(node)];
        const init_node = switch (ast.nodes.items(.tag)[@intFromEnum(node)]) {
            .local_var_decl => data.extra_and_opt_node[1].unwrap(),
            .simple_var_decl => data.opt_node_and_opt_node[1].unwrap(),
            .aligned_var_decl => data.node_and_opt_node[1].unwrap(),
            else => null,
        };

        if (init_node) |init_expr| {
            // Check if init is a call to a function that returns a raw pointer
            const init_tag = ast.nodes.items(.tag)[@intFromEnum(init_expr)];
            if (init_tag == .call or init_tag == .call_one or init_tag == .call_comma or init_tag == .call_one_comma) {
                const call_callee = getCallee(ast, init_expr);
                const call_name = getBaseVar(ast, call_callee);
                if (call_name.len > 0) {
                    if (self.functions.get(call_name)) |fn_info| {
                        if (fn_info.returns_raw_pointer) {
                            try self.addDiagnostic(file_path, .UseAfterFree, "variable initialized with raw pointer from function call; consider using safe.Box(T, 0, 0, 0) to take ownership", @intCast(token_loc.line), @intCast(token_loc.column));
                        }
                    }
                }
            }

            // Check if init is Box.init() call
            if (isBoxInit(ast, init_expr)) {
                const name_copy = try self.gpa.dupe(u8, decl_name);
                try self.variables.put(name_copy, .{
                    .name = name_copy,
                    .is_box = true,
                    .is_live = true,
                    .origin = .{ .Box = .{ .var_name = name_copy, .decl_line = @intCast(token_loc.line) } },
                    .decl_line = @intCast(token_loc.line),
                    .decl_col = @intCast(token_loc.column),
                });

                // Also detect zust type for Box
                if (self.variables.getPtr(name_copy)) |var_state| {
                    var_state.type_category = .Box;
                }
            } else if (isUnsafePtrCall(ast, init_expr)) {
                // var raw = box.unsafePtr()
                const unwrapped = unwrapNode(ast, init_expr);
                const callee = getCallee(ast, unwrapped);
                const base_var = getBaseVar(ast, callee);
                const name_copy = try self.gpa.dupe(u8, decl_name);
                try self.variables.put(name_copy, .{
                    .name = name_copy,
                    .is_box = false,
                    .is_live = true,
                    .origin = .{ .RawFromBox = .{ .box_var = base_var, .unsafe_ptr_line = @intCast(token_loc.line) } },
                    .decl_line = @intCast(token_loc.line),
                    .decl_col = @intCast(token_loc.column),
                });
            } else if (isBorrowCall(ast, init_expr)) {
                const unwrapped = unwrapNode(ast, init_expr);
                const callee = getCallee(ast, unwrapped);
                const base_var = getBaseVar(ast, callee);
                const is_mut = isBorrowMutCall(ast, init_expr);
                const name_copy = try self.gpa.dupe(u8, decl_name);
                try self.variables.put(name_copy, .{
                    .name = name_copy,
                    .is_box = true,
                    .is_live = true,
                    .origin = .{ .Borrow = .{ .var_name = base_var, .is_mutable = is_mut } },
                    .decl_line = @intCast(token_loc.line),
                    .decl_col = @intCast(token_loc.column),
                });
            } else if (isDeinitCall(ast, init_expr)) {
                // var = something.deinit() - the variable becomes Freed
                const unwrapped = unwrapNode(ast, init_expr);
                const callee = getCallee(ast, unwrapped);
                const base_var = getBaseVar(ast, callee);
                
                // Validate: check if base variable is still live
                if (self.variables.getPtr(base_var)) |base_state| {
                    if (!base_state.is_live) {
                        try self.addDiagnostic(file_path, .DoubleFree, "double free detected", @intCast(token_loc.line), @intCast(token_loc.column));
                    } else {
                        base_state.is_live = false;
                        
                        // Check if any raw pointers derived from this box are still live
                        // and mark them as dead too (since the source Box is gone)
                        var derived_iter = self.variables.iterator();
                        while (derived_iter.next()) |entry| {
                            const other = entry.value_ptr;
                            if (other.origin == .RawFromBox and std.mem.eql(u8, other.origin.RawFromBox.box_var, base_var) and other.is_live) {
                                try self.addDiagnostic(file_path, .PointerEscape, "dangling pointer after deallocation", other.decl_line, other.decl_col);
                                other.is_live = false;
                            }
                        }
                    }
                }
                
                const name_copy = try self.gpa.dupe(u8, decl_name);
                try self.variables.put(name_copy, .{
                    .name = name_copy,
                    .is_box = true,
                    .is_live = false,
                    .origin = .{ .Box = .{ .var_name = base_var, .decl_line = @intCast(token_loc.line) } },
                    .decl_line = @intCast(token_loc.line),
                    .decl_col = @intCast(token_loc.column),
                });
            } else {
                const name_copy = try self.gpa.dupe(u8, decl_name);
                try self.variables.put(name_copy, .{
                    .name = name_copy,
                    .is_box = false,
                    .is_live = true,
                    .origin = .None,
                    .decl_line = @intCast(token_loc.line),
                    .decl_col = @intCast(token_loc.column),
                });
            }

            // Detect zust type from initialization for all declarations
            if (detectZustInit(ast, init_expr)) |category| {
                if (self.variables.getPtr(decl_name)) |var_state| {
                    var_state.type_category = category;
                    switch (category) {
                        .OnceCell, .LazyCell, .OnceBox => {
                            var_state.is_initialized = false;
                        },
                        .Channel => {
                            var_state.is_closed = false;
                        },
                        .Oneshot => {
                            var_state.is_sent = false;
                        },
                        else => {},
                    }
                }
            }

            // Check for Pin move in variable initialization
            const init_tag2 = ast.nodes.items(.tag)[@intFromEnum(init_expr)];
            if (init_tag2 == .identifier) {
                const rhs_name = getVarName(ast, init_expr) orelse "";
                if (self.variables.get(rhs_name)) |rhs_state| {
                    if (rhs_state.type_category == .Pin) {
                        try self.addDiagnostic(file_path, .InvalidMove, "Pin value moved; Pin guarantees the value won't move in memory", @intCast(token_loc.line), @intCast(token_loc.column));
                    }
                }
            }
        }
    }

    fn analyzeAssign(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const data = ast.nodes.items(.data)[@intFromEnum(node)];
        const lhs = data.node_and_node[0];
        const rhs = data.node_and_node[1];

        // Check if lhs or rhs involves dereferenced dead pointers
        try self.checkPointerUse(ast, lhs, file_path, node);
        try self.checkPointerUse(ast, rhs, file_path, node);

        // Check for raw pointer dereferences in assignment
        try self.checkDerefs(file_path, ast, lhs);
        try self.checkDerefs(file_path, ast, rhs);

        const lhs_name = getVarName(ast, lhs);
        if (lhs_name) |name| {
            if (self.variables.getPtr(name)) |var_state| {
                // Check if RHS is unsafePtr() - track provenance
                if (isUnsafePtrCall(ast, rhs)) {
                    const unwrapped = unwrapNode(ast, rhs);
                    const callee = getCallee(ast, unwrapped);
                    const base_var = getBaseVar(ast, callee);
                    var_state.origin = .{ .RawFromBox = .{ .box_var = base_var, .unsafe_ptr_line = var_state.decl_line } };
                } else if (isDeinitCall(ast, rhs)) {
                    // var = something.deinit() - the variable becomes Freed
                    var_state.is_live = false;
                }
            }
        }

        // Check if assigning to a global/field - pointer escape
        const rhs_name = getVarName(ast, rhs) orelse "";
        if (!isLocalVar(ast, lhs)) {
            if (self.variables.get(rhs_name)) |rhs_state| {
                if (rhs_state.origin == .RawFromBox) {
                    const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                    try self.addDiagnostic(file_path, .PointerEscape, "pointer escapes to non-local storage", @intCast(token_loc.line), @intCast(token_loc.column));
                }
            }
        }

        // Check if assigning a Pin value (moving it)
        if (self.variables.get(rhs_name)) |rhs_state| {
            if (rhs_state.type_category == .Pin) {
                const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                try self.addDiagnostic(file_path, .InvalidMove, "Pin value moved; Pin guarantees the value won't move in memory", @intCast(token_loc.line), @intCast(token_loc.column));
            }
        }

        // Recurse into rhs and lhs to find any nested calls
        try self.findCallsInExpr(file_path, ast, lhs);
        try self.findCallsInExpr(file_path, ast, rhs);
    }

    fn checkPointerUse(self: *Analyzer, ast: *const std.zig.Ast, expr: zig.Ast.Node.Index, file_path: []const u8, node: zig.Ast.Node.Index) AnalyzeError!void {
        const tag = ast.nodes.items(.tag)[@intFromEnum(expr)];
        switch (tag) {
            .deref => {
                const data_inner = ast.nodes.items(.data)[@intFromEnum(expr)];
                const operand = data_inner.node;
                const var_name = getVarName(ast, operand);
                if (var_name) |name| {
                    if (self.variables.get(name)) |var_state| {
                        if (!var_state.is_live) {
                            const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                            try self.addDiagnostic(file_path, .UseAfterFree, "use of dangling pointer", @intCast(token_loc.line), @intCast(token_loc.column));
                        } else if (var_state.origin == .RawFromBox) {
                            // Check if the source Box is still live
                            const box_var = var_state.origin.RawFromBox.box_var;
                            if (self.variables.get(box_var)) |box_state| {
                                if (!box_state.is_live) {
                                    const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                                    try self.addDiagnostic(file_path, .UseAfterFree, "use of dangling pointer (derived from deallocated Box)", @intCast(token_loc.line), @intCast(token_loc.column));
                                }
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    fn analyzeCall(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const callee = getCallee(ast, node);
        const method_name = getMethodName(ast, callee);

        if (method_name) |method| {
            const base_var = getCallBaseVar(ast, node);
            const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);

            // Type-specific method checks
            if (self.variables.getPtr(base_var)) |var_state| {
                switch (var_state.type_category) {
                    .ManuallyDrop => {
                        if (std.mem.eql(u8, method, "drop")) {
                            var_state.is_dropped = true;
                        } else if (std.mem.eql(u8, method, "take")) {
                            var_state.is_dropped = true;
                        }
                    },
                    .OnceCell, .OnceBox => {
                        if (std.mem.eql(u8, method, "set")) {
                            if (var_state.is_initialized) {
                                try self.addDiagnostic(file_path, .AlreadyInitialized, "double set on OnceCell; use getOrInit() for idempotent initialization", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                            var_state.is_initialized = true;
                        } else if (std.mem.eql(u8, method, "get")) {
                            if (!var_state.is_initialized) {
                                try self.addDiagnostic(file_path, .NotInitialized, "reading uninitialized OnceCell; initialize with set() or use LazyCell", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                        }
                    },
                    .MaybeUninit => {
                        if (std.mem.eql(u8, method, "assumeInit")) {
                            if (!var_state.is_initialized) {
                                try self.addDiagnostic(file_path, .NotInitialized, "calling assumeInit() on uninitialized MaybeUninit; call write() first", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                        } else if (std.mem.eql(u8, method, "write")) {
                            var_state.is_initialized = true;
                        }
                    },
                    .Channel => {
                        if (std.mem.eql(u8, method, "close")) {
                            var_state.is_closed = true;
                        } else if (std.mem.eql(u8, method, "send")) {
                            if (var_state.is_closed) {
                                try self.addDiagnostic(file_path, .ChannelClosed, "sending to closed Channel", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                        }
                    },
                    .Oneshot => {
                        if (std.mem.eql(u8, method, "send")) {
                            if (var_state.is_sent) {
                                try self.addDiagnostic(file_path, .AlreadySent, "double send on Oneshot; can only send once", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                            var_state.is_sent = true;
                        }
                    },
                    .Mutex, .RwLock => {
                        if (std.mem.eql(u8, method, "lock") or std.mem.eql(u8, method, "readLock") or std.mem.eql(u8, method, "writeLock")) {
                            if (var_state.is_locked) {
                                try self.addDiagnostic(file_path, .Deadlock, "locking an already-locked Mutex/RwLock; potential deadlock", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                            var_state.is_locked = true;
                        } else if (std.mem.eql(u8, method, "unlock") or std.mem.eql(u8, method, "readUnlock") or std.mem.eql(u8, method, "writeUnlock")) {
                            var_state.is_locked = false;
                        }
                    },
                    else => {},
                }
            }

            if (std.mem.eql(u8, method, "deinit")) {
                try self.checkDeinit(file_path, ast, node);
            } else if (std.mem.eql(u8, method, "unsafePtr")) {
                // unsafePtr() call - no immediate issue, but track the result
            } else if (std.mem.eql(u8, method, "borrowMut")) {
                // borrowMut - library catches this at compile time, but we track too
            } else if (std.mem.eql(u8, method, "destroy")) {
                // allocator.destroy(ptr)
                try self.checkDestroy(file_path, ast, node);
            } else if (std.mem.eql(u8, method, "create")) {
                // allocator.create(T) - suggest using safe.Box
                try self.checkRawCreate(file_path, ast, node);
            }
        } else {
            // Regular function call - check if any args are dangling pointers
            try self.checkCallArgs(file_path, ast, node);
            // Cross-function analysis
            try self.checkCrossFunctionCall(file_path, ast, node, callee);
        }
    }

    fn checkCrossFunctionCall(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index, callee: zig.Ast.Node.Index) AnalyzeError!void {
        // Get the function name being called
        const callee_name = getBaseVar(ast, callee);
        if (callee_name.len == 0) return;

        // Look up in function registry
        if (self.functions.get(callee_name)) |fn_info| {
            const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);

            // Get call arguments (needed for both contract and raw-pointer checks)
            const data = ast.nodes.items(.data)[@intFromEnum(node)];
            const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
            var arg_nodes: []const zig.Ast.Node.Index = &.{};
            var needs_free = false;

            switch (tag) {
                .call_one, .call_one_comma => {
                    if (data.node_and_opt_node[1].unwrap()) |arg| {
                        arg_nodes = &.{arg};
                    }
                },
                .call, .call_comma => {
                    const extra = ast.extra_data[@intFromEnum(data.node_and_extra[1])..];
                    const arg_count = extra[0];
                    const u32_slice = extra[1 .. 1 + arg_count];
                    const casted = try self.gpa.alloc(zig.Ast.Node.Index, u32_slice.len);
                    for (u32_slice, 0..) |val, i| {
                        casted[i] = @enumFromInt(val);
                    }
                    arg_nodes = casted;
                    needs_free = true;
                },
                else => {},
            }

            // Check each argument against ownership contracts
            for (arg_nodes, 0..) |arg, i| {
                if (i >= fn_info.param_count) break;

                const arg_name = getVarName(ast, arg);
                if (arg_name) |name| {
                    if (self.variables.getPtr(name)) |var_state| {
                        // Ownership contract: if callee takes ownership, mark arg dead
                        if (i < 8 and fn_info.param_contracts[i] == .owned) {
                            if (!var_state.is_live) {
                                try self.addDiagnostic(file_path, .UseAfterFree, "use-after-free: passing already-deallocated value to function that takes ownership", @intCast(token_loc.line), @intCast(token_loc.column));
                            } else {
                                var_state.is_live = false;
                                // Check for dangling derived pointers
                                var derived_iter = self.variables.iterator();
                                while (derived_iter.next()) |entry| {
                                    const other = entry.value_ptr;
                                    if (other.origin == .RawFromBox and std.mem.eql(u8, other.origin.RawFromBox.box_var, name) and other.is_live) {
                                        try self.addDiagnostic(file_path, .PointerEscape, "dangling pointer after ownership transfer", other.decl_line, other.decl_col);
                                        other.is_live = false;
                                    }
                                }
                            }
                        }

                        // Raw pointer param checks
                        if (fn_info.has_raw_pointer_params and fn_info.param_is_raw_pointer[i]) {
                            if (!var_state.is_live) {
                                // Passing a dead pointer to a function - interprocedural UAF
                                try self.addDiagnostic(file_path, .UseAfterFree, "use-after-free: passing dangling pointer to function call", @intCast(token_loc.line), @intCast(token_loc.column));
                            } else if (var_state.origin == .RawFromBox and !fn_info.has_nocapture_annotation) {
                                // Pointer from a Box is escaping to another function
                                // (Skip if callee has @safe(nocapture) annotation)
                                try self.addDiagnostic(file_path, .PointerEscape, "raw pointer from Box escapes to function call; callee may deallocate or alias it", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                        }
                    }
                }
            }

            // Free temporary allocation
            if (needs_free) {
                self.gpa.free(arg_nodes);
            }
        }
    }

    fn checkRawCreate(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
        try self.addDiagnostic(file_path, .UseAfterFree, "raw allocator.create(T) detected; consider using safe.Box(T, 0, 0, 0).init(allocator, value) instead", @intCast(token_loc.line), @intCast(token_loc.column));
    }

    fn checkDeinit(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const base_var = getCallBaseVar(ast, node);
        const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);

        if (self.variables.getPtr(base_var)) |var_state| {
            if (!var_state.is_live) {
                try self.addDiagnostic(file_path, .DoubleFree, "double free detected", @intCast(token_loc.line), @intCast(token_loc.column));
            } else if (!var_state.is_box) {
                try self.addDiagnostic(file_path, .UseAfterFree, "deinit called on non-Box type", @intCast(token_loc.line), @intCast(token_loc.column));
            } else {
                // Mark as deallocated
                var_state.is_live = false;

                // Check if any raw pointers derived from this box are still live
                // and mark them as dead too (since the source Box is gone)
                var iter = self.variables.iterator();
                while (iter.next()) |entry| {
                    const other = entry.value_ptr;
                    if (other.origin == .RawFromBox and std.mem.eql(u8, other.origin.RawFromBox.box_var, base_var) and other.is_live) {
                        try self.addDiagnostic(file_path, .PointerEscape, "dangling pointer after deallocation", other.decl_line, other.decl_col);
                        other.is_live = false;
                    }
                }
            }
        }
    }

    fn checkDestroy(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const arg = getCallArg(ast, node, 0);
        const arg_name = getVarName(ast, arg) orelse return;
        const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);

        if (self.variables.getPtr(arg_name)) |var_state| {
            if (!var_state.is_live) {
                try self.addDiagnostic(file_path, .DoubleFree, "double free (destroy) detected", @intCast(token_loc.line), @intCast(token_loc.column));
            } else {
                var_state.is_live = false;
            }
        } else {
            // Raw destroy on untracked pointer - suggest using Box
            try self.addDiagnostic(file_path, .UseAfterFree, "raw allocator.destroy(ptr) detected; consider using safe.Box(T, 0, 0, 0).deinit() instead", @intCast(token_loc.line), @intCast(token_loc.column));
        }
    }

    fn checkDerefs(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
        switch (tag) {
            .deref => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                const inner = data.node;
                if (getVarName(ast, inner)) |var_name| {
                    if (self.variables.get(var_name)) |var_state| {
                        if (!var_state.is_box and var_state.is_live) {
                            const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                            try self.addDiagnostic(file_path, .UseAfterFree, "raw pointer dereference; consider using safe.Box(T, 0, 0, 0).withImm() or .withMut() instead", @intCast(token_loc.line), @intCast(token_loc.column));
                        }
                    } else {
                        // Untracked raw pointer dereference
                        const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                        try self.addDiagnostic(file_path, .UseAfterFree, "raw pointer dereference detected; consider using safe.Box(T, 0, 0, 0) for memory safety", @intCast(token_loc.line), @intCast(token_loc.column));
                    }
                }
            },
            .field_access => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.checkDerefs(file_path, ast, data.node_and_token[0]);
            },
            .call, .call_comma, .call_one, .call_one_comma => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                const callee = getCallee(ast, node);
                try self.checkDerefs(file_path, ast, callee);
                // Check args too
                switch (tag) {
                    .call_one, .call_one_comma => {
                        if (data.node_and_opt_node[1].unwrap()) |arg| {
                            try self.checkDerefs(file_path, ast, arg);
                        }
                    },
                    .call, .call_comma => {
                        const extra = ast.extra_data[@intFromEnum(data.node_and_extra[1])..];
                        const arg_count = extra[0];
                        for (extra[1 .. 1 + arg_count]) |arg_idx| {
                            try self.checkDerefs(file_path, ast, @enumFromInt(arg_idx));
                        }
                    },
                    else => {},
                }
            },
            else => {
                // Recurse into child nodes via data fields
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                switch (tag) {
                    .block_two, .block_two_semicolon => {
                        if (data.opt_node_and_opt_node[0].unwrap()) |n| try self.checkDerefs(file_path, ast, n);
                        if (data.opt_node_and_opt_node[1].unwrap()) |n| try self.checkDerefs(file_path, ast, n);
                    },
                    .block, .block_semicolon => {
                        const extra = ast.extra_data[@intFromEnum(data.extra_range.start)..@intFromEnum(data.extra_range.end)];
                        for (extra) |n| try self.checkDerefs(file_path, ast, @enumFromInt(n));
                    },
                    .if_simple => {
                        try self.checkDerefs(file_path, ast, data.node_and_node[0]);
                        try self.checkDerefs(file_path, ast, data.node_and_node[1]);
                    },
                    .while_simple, .while_cont => {
                        try self.checkDerefs(file_path, ast, data.node_and_node[0]);
                        try self.checkDerefs(file_path, ast, data.node_and_node[1]);
                    },
                    .assign => {
                        try self.checkDerefs(file_path, ast, data.node_and_node[0]);
                        try self.checkDerefs(file_path, ast, data.node_and_node[1]);
                    },
                    .address_of => {
                        try self.checkDerefs(file_path, ast, data.node);
                    },
                    else => {},
                }
            },
        }
    }

    fn checkCallArgs(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const data = ast.nodes.items(.data)[@intFromEnum(node)];
        const tag = ast.nodes.items(.tag)[@intFromEnum(node)];

        var arg_nodes: []const zig.Ast.Node.Index = &.{};
        switch (tag) {
            .call_one, .call_one_comma => {
                const opt_arg = data.node_and_opt_node[1];
                if (opt_arg.unwrap()) |arg| {
                    arg_nodes = &.{arg};
                }
            },
            .call, .call_comma => {
                const extra = ast.extra_data[@intFromEnum(data.node_and_extra[1])..];
                const arg_count = extra[0];
                const u32_slice = extra[1 .. 1 + arg_count];
                // Cast []u32 to []Node.Index
                const casted = try self.gpa.alloc(zig.Ast.Node.Index, u32_slice.len);
                for (u32_slice, 0..) |val, i| {
                    casted[i] = @enumFromInt(val);
                }
                arg_nodes = casted;
            },
            else => {},
        }

        for (arg_nodes) |arg| {
            const arg_name = getVarName(ast, arg) orelse continue;
            const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(arg)]);

            if (self.variables.get(arg_name)) |var_state| {
                if (!var_state.is_live) {
                try self.addDiagnostic(file_path, .UseAfterFree, "use of dangling pointer as function argument", @intCast(token_loc.line), @intCast(token_loc.column));
                }
            }
        }
    }

    fn shouldReport(self: *Analyzer, kind: Diagnostic.DiagnosticKind) bool {
        return switch (self.strictness) {
            .Low => switch (kind) {
                .DoubleFree,
                .UseAfterFree,
                .UseAfterMove,
                .MutableAliasing,
                .PointerEscape,
                .StackUseAfterReturn,
                .DataRace,
                .Deadlock,
                .AlreadyInitialized,
                .NotInitialized,
                .ChannelClosed,
                .AlreadySent,
                .InvalidMove => true,
                else => false,
            },
            .Medium => switch (kind) {
                .DoubleFree,
                .UseAfterFree,
                .UseAfterMove,
                .MutableAliasing,
                .PointerEscape,
                .StackUseAfterReturn,
                .DataRace,
                .IteratorInvalidation,
                .MixedBorrow,
                .MemoryLeak,
                .Deadlock,
                .AlreadyInitialized,
                .NotInitialized,
                .ChannelClosed,
                .AlreadySent,
                .InvalidMove,
                .StdAlternative => true,
                else => false,
            },
            .High => true,
        };
    }

    pub fn hasDiagnostic(self: *Analyzer, kind: Diagnostic.DiagnosticKind) bool {
        for (self.diagnostics.items) |diag| {
            if (diag.kind == kind) return true;
        }
        return false;
    }

    fn addDiagnostic(
        self: *Analyzer,
        file_path: []const u8,
        kind: Diagnostic.DiagnosticKind,
        message: []const u8,
        line: u32,
        col: u32,
    ) AnalyzeError!void {
        if (!self.shouldReport(kind)) return;
        try self.diagnostics.append(self.gpa, .{
            .kind = kind,
            .message = message,
            .location = .{
                .file = file_path,
                .line = line,
                .column = col,
            },
            .notes = &.{},
            .severity = switch (kind) {
                .DoubleFree, .UseAfterFree, .UseAfterMove, .MutableAliasing, .StackUseAfterReturn, .DataRace, .Deadlock, .AlreadyInitialized, .NotInitialized, .ChannelClosed, .AlreadySent, .InvalidMove => .Error,
                .MemoryLeak, .StdAlternative => .Warning,
                else => .Warning,
            },
        });
    }

    // ─── Control flow ───

    fn analyzeIf(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const data = ast.nodes.items(.data)[@intFromEnum(node)];
        const then_body = data.node_and_node[1];
        const else_body = if (@intFromEnum(data.node_and_opt_node[1]) != 0) data.node_and_opt_node[1].unwrap() else null;

        // Save current state
        var saved = try self.cloneVariables();
        defer saved.deinit();

        // Analyze then branch
        try self.analyzeBlock(file_path, ast, then_body);

        // Save then-final state for merging
        var then_state = try self.cloneVariables();
        defer then_state.deinit();

        if (else_body) |else_node| {
            // Restore state for else branch
            try self.restoreVariables(saved);
            try self.analyzeBlock(file_path, ast, else_node);

            // Merge: variable is dead after if if dead in THEN OR ELSE (conservative)
            try self.mergeVariables(then_state);
        } else {
            // No else: restore original state (then branch may not execute)
            try self.restoreVariables(saved);
        }
    }

    /// Conservative merge: a variable is considered dead if dead in ANY branch.
    fn mergeVariables(self: *Analyzer, then_state: std.StringHashMap(VarState)) AnalyzeError!void {
        // For each variable in current state (else-final), if it was dead in then, mark dead
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            if (then_state.get(name)) |then_var| {
                if (!then_var.is_live and entry.value_ptr.is_live) {
                    entry.value_ptr.is_live = false;
                    entry.value_ptr.origin = then_var.origin;
                }
            }
        }
        // Also handle variables that exist in then but not else (were created in then)
        var then_iter = then_state.iterator();
        while (then_iter.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!self.variables.contains(name)) {
                // Variable only in then branch: add to merged state as possibly uninitialized
                const name_copy = try self.gpa.dupe(u8, name);
                try self.variables.put(name_copy, .{
                    .name = name_copy,
                    .is_box = entry.value_ptr.is_box,
                    .is_live = entry.value_ptr.is_live,
                    .origin = entry.value_ptr.origin,
                    .decl_line = entry.value_ptr.decl_line,
                    .decl_col = entry.value_ptr.decl_col,
                });
            }
        }
    }

    fn analyzeWhile(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const data = ast.nodes.items(.data)[@intFromEnum(node)];
        const body = data.node_and_node[1];

        // For while loops, we analyze once conservatively
        // In a full implementation, we'd iterate to a fixed point
        try self.analyzeBlock(file_path, ast, body);
    }

    fn analyzeFor(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const data = ast.nodes.items(.data)[@intFromEnum(node)];
        const body = data.node_and_node[1];

        try self.analyzeBlock(file_path, ast, body);
    }

    fn cloneVariables(self: *Analyzer) !std.StringHashMap(VarState) {
        var clone = std.StringHashMap(VarState).init(self.gpa);
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            const key_copy = try self.gpa.dupe(u8, entry.key_ptr.*);
            try clone.put(key_copy, entry.value_ptr.*);
        }
        return clone;
    }

    fn restoreVariables(self: *Analyzer, saved: std.StringHashMap(VarState)) !void {
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.variables.clearRetainingCapacity();

        var saved_iter = saved.iterator();
        while (saved_iter.next()) |entry| {
            const key_copy = try self.gpa.dupe(u8, entry.key_ptr.*);
            try self.variables.put(key_copy, entry.value_ptr.*);
        }
    }

    fn findCallsInExpr(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        // Recursively find all call expressions
        const tag = ast.nodes.items(.tag)[@intFromEnum(node)];

        switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => {
                try self.analyzeCall(file_path, ast, node);
            },
            .assign => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.findCallsInExpr(file_path, ast, data.node_and_node[0]);
                try self.findCallsInExpr(file_path, ast, data.node_and_node[1]);
            },
            .field_access => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.findCallsInExpr(file_path, ast, data.node_and_token[0]);
            },
            .deref => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.findCallsInExpr(file_path, ast, data.node);
            },
            .address_of => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.findCallsInExpr(file_path, ast, data.node);
            },
            .block_two, .block_two_semicolon => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                if (data.opt_node_and_opt_node[0].unwrap()) |n| try self.findCallsInExpr(file_path, ast, n);
                if (data.opt_node_and_opt_node[1].unwrap()) |n| try self.findCallsInExpr(file_path, ast, n);
            },
            .block, .block_semicolon => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                const extra = ast.extra_data[@intFromEnum(data.extra_range.start)..@intFromEnum(data.extra_range.end)];
                for (extra) |n| try self.findCallsInExpr(file_path, ast, @enumFromInt(n));
            },
            .if_simple => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.findCallsInExpr(file_path, ast, data.node_and_node[0]);
                try self.findCallsInExpr(file_path, ast, data.node_and_node[1]);
            },
            .while_simple, .while_cont => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.findCallsInExpr(file_path, ast, data.node_and_node[0]);
                try self.findCallsInExpr(file_path, ast, data.node_and_node[1]);
            },
            else => {
                // Leaf node or unhandled - stop recursing
            },
        }
    }
};

// ─── AST Helpers ───

fn unwrapNode(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) zig.Ast.Node.Index {
    const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
    switch (tag) {
        .@"catch" => {
            const data = ast.nodes.items(.data)[@intFromEnum(node)];
            return unwrapNode(ast, data.node_and_node[0]);
        },
        .@"try" => {
            const data = ast.nodes.items(.data)[@intFromEnum(node)];
            return unwrapNode(ast, data.node);
        },
        else => return node,
    }
}

fn isBoxInit(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    const unwrapped = unwrapNode(ast, node);
    const tag = ast.nodes.items(.tag)[@intFromEnum(unwrapped)];
    if (tag != .call and tag != .call_one and tag != .call_comma and tag != .call_one_comma) return false;

    const callee = getCallee(ast, unwrapped);
    return isFieldAccess(ast, callee, "init");
}

fn isUnsafePtrCall(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    const unwrapped = unwrapNode(ast, node);
    const tag = ast.nodes.items(.tag)[@intFromEnum(unwrapped)];
    if (tag != .call and tag != .call_one and tag != .call_comma and tag != .call_one_comma) return false;

    const callee = getCallee(ast, unwrapped);
    return isFieldAccess(ast, callee, "unsafePtr");
}

fn isBorrowCall(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    const unwrapped = unwrapNode(ast, node);
    const tag = ast.nodes.items(.tag)[@intFromEnum(unwrapped)];
    if (tag != .call and tag != .call_one and tag != .call_comma and tag != .call_one_comma) return false;

    const callee = getCallee(ast, unwrapped);
    return isFieldAccess(ast, callee, "borrowImm") or isFieldAccess(ast, callee, "borrowMut");
}

fn isBorrowMutCall(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    const unwrapped = unwrapNode(ast, node);
    const tag = ast.nodes.items(.tag)[@intFromEnum(unwrapped)];
    if (tag != .call and tag != .call_one and tag != .call_comma and tag != .call_one_comma) return false;

    const callee = getCallee(ast, unwrapped);
    return isFieldAccess(ast, callee, "borrowMut");
}

fn isDeinitCall(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    const unwrapped = unwrapNode(ast, node);
    const tag = ast.nodes.items(.tag)[@intFromEnum(unwrapped)];
    if (tag != .call and tag != .call_one and tag != .call_comma and tag != .call_one_comma) return false;

    const callee = getCallee(ast, unwrapped);
    return isFieldAccess(ast, callee, "deinit");
}

fn isFieldAccess(ast: *const std.zig.Ast, node: zig.Ast.Node.Index, field_name: []const u8) bool {
    const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
    if (tag != .field_access) return false;

    const main_token = ast.nodes.items(.main_token)[@intFromEnum(node)];
    const actual_name = ast.tokenSlice(main_token + 1);
    return std.mem.eql(u8, actual_name, field_name);
}

fn getCallee(ast: *const std.zig.Ast, call_node: zig.Ast.Node.Index) zig.Ast.Node.Index {
    const data = ast.nodes.items(.data)[@intFromEnum(call_node)];
    return switch (ast.nodes.items(.tag)[@intFromEnum(call_node)]) {
        .call_one, .call_one_comma => data.node_and_opt_node[0],
        .call, .call_comma => data.node_and_extra[0],
        else => @enumFromInt(0),
    };
}

fn getMethodName(ast: *const std.zig.Ast, callee: zig.Ast.Node.Index) ?[]const u8 {
    const tag = ast.nodes.items(.tag)[@intFromEnum(callee)];
    if (tag == .field_access) {
        const main_token = ast.nodes.items(.main_token)[@intFromEnum(callee)];
        return ast.tokenSlice(main_token + 1);
    }
    return null;
}

fn getBaseVar(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) []const u8 {
    var current = node;
    while (true) {
        const tag = ast.nodes.items(.tag)[@intFromEnum(current)];
        switch (tag) {
            .field_access => {
                const data = ast.nodes.items(.data)[@intFromEnum(current)];
                current = data.node_and_token[0];
            },
            .identifier => {
                const main_token = ast.nodes.items(.main_token)[@intFromEnum(current)];
                return ast.tokenSlice(main_token);
            },
            else => return "",
        }
    }
}

fn getCallBaseVar(ast: *const std.zig.Ast, call_node: zig.Ast.Node.Index) []const u8 {
    const callee = getCallee(ast, call_node);
    return getBaseVar(ast, callee);
}

fn getVarName(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) ?[]const u8 {
    const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
    if (tag == .identifier) {
        const main_token = ast.nodes.items(.main_token)[@intFromEnum(node)];
        return ast.tokenSlice(main_token);
    }
    return null;
}

fn getCallArg(ast: *const std.zig.Ast, call_node: zig.Ast.Node.Index, arg_index: usize) zig.Ast.Node.Index {
    const data = ast.nodes.items(.data)[@intFromEnum(call_node)];
    const tag = ast.nodes.items(.tag)[@intFromEnum(call_node)];

    switch (tag) {
        .call_one, .call_one_comma => {
            if (arg_index == 0) {
                if (data.node_and_opt_node[1].unwrap()) |arg| return arg;
            }
        },
        .call, .call_comma => {
            const extra = ast.extra_data[@intFromEnum(data.node_and_extra[1])..];
            const arg_count = extra[0];
            if (arg_index < arg_count) {
                return @enumFromInt(extra[1 + arg_index]);
            }
        },
        else => {},
    }
    return @enumFromInt(0);
}

fn detectZustInit(ast: *const std.zig.Ast, init_expr: zig.Ast.Node.Index) ?TypeCategory {
    const init_tag = ast.nodes.items(.tag)[@intFromEnum(init_expr)];
    if (init_tag != .call and init_tag != .call_one and init_tag != .call_comma and init_tag != .call_one_comma) return null;

    const callee = getCallee(ast, init_expr);
    if (!isFieldAccess(ast, callee, "init")) return null;

    const data = ast.nodes.items(.data)[@intFromEnum(callee)];
    const type_expr = data.node_and_token[0];
    const type_tag = ast.nodes.items(.tag)[@intFromEnum(type_expr)];

    var type_name: []const u8 = "";

    switch (type_tag) {
        .identifier => type_name = getVarName(ast, type_expr) orelse "",
        .call, .call_one, .call_comma, .call_one_comma => {
            const inner_callee = getCallee(ast, type_expr);
            if (getMethodName(ast, inner_callee)) |method| {
                type_name = method;
            } else if (getVarName(ast, inner_callee)) |name| {
                type_name = name;
            }
        },
        .field_access => {
            if (getMethodName(ast, type_expr)) |method| {
                type_name = method;
            } else if (getVarName(ast, type_expr)) |name| {
                type_name = name;
            }
        },
        else => {},
    }

    if (std.mem.eql(u8, type_name, "Box")) return .Box;
    if (std.mem.eql(u8, type_name, "Rc")) return .Rc;
    if (std.mem.eql(u8, type_name, "Arc")) return .Arc;
    if (std.mem.eql(u8, type_name, "Weak")) return .Weak;
    if (std.mem.eql(u8, type_name, "Mutex")) return .Mutex;
    if (std.mem.eql(u8, type_name, "RwLock")) return .RwLock;
    if (std.mem.eql(u8, type_name, "Cell")) return .Cell;
    if (std.mem.eql(u8, type_name, "RefCell")) return .RefCell;
    if (std.mem.eql(u8, type_name, "ManuallyDrop")) return .ManuallyDrop;
    if (std.mem.eql(u8, type_name, "MaybeUninit")) return .MaybeUninit;
    if (std.mem.eql(u8, type_name, "Pin")) return .Pin;
    if (std.mem.eql(u8, type_name, "OnceCell")) return .OnceCell;
    if (std.mem.eql(u8, type_name, "LazyCell")) return .LazyCell;
    if (std.mem.eql(u8, type_name, "OnceBox")) return .OnceBox;
    if (std.mem.eql(u8, type_name, "Channel")) return .Channel;
    if (std.mem.eql(u8, type_name, "Oneshot")) return .Oneshot;
    if (std.mem.eql(u8, type_name, "String")) return .String;
    if (std.mem.eql(u8, type_name, "HashMap")) return .HashMap;
    if (std.mem.eql(u8, type_name, "BTreeMap")) return .BTreeMap;
    if (std.mem.eql(u8, type_name, "HashSet")) return .HashSet;
    if (std.mem.eql(u8, type_name, "BinaryHeap")) return .BinaryHeap;
    if (std.mem.eql(u8, type_name, "VecDeque")) return .VecDeque;
    if (std.mem.eql(u8, type_name, "LinkedList")) return .LinkedList;
    if (std.mem.eql(u8, type_name, "ArrayList")) return .ArrayList;
    if (std.mem.eql(u8, type_name, "UnsafeCell")) return .UnsafeCell;

    return null;
}

fn isRawPointerType(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
    return tag == .ptr_type or tag == .ptr_type_aligned or tag == .ptr_type_sentinel or tag == .ptr_type_bit_range;
}

fn isSliceType(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
    return tag == .array_type or tag == .array_type_sentinel;
}

fn isLocalVar(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    _ = ast;
    _ = node;
    // Simplified: assume all identifiers are local unless proven otherwise
    return true;
}
