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
    is_mutable: bool = false,        // var vs const
    is_read: bool = false,           // For race detection
    is_written: bool = false,        // For race detection
    null_status: enum { unknown, null, non_null } = .unknown,
    array_len: ?u32 = null,
    is_std_resource: bool = false,   // std File, socket, stream, etc.
    has_cleanup: bool = false,        // close/deinit/destroy seen
};

/// Active iterator tracking for iterator invalidation detection.
const ActiveIterator = struct {
    collection_var: []const u8,
    loop_line: u32,
    loop_col: u32,
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
    /// Active iterators for iterator invalidation detection
    active_iterators: std.ArrayList(ActiveIterator) = .empty,
    /// Has std.Thread.spawn been seen in current function?
    thread_spawns: bool = false,
    /// Has a try expression been seen in current function?
    has_try: bool = false,
    /// Variables deinit'd in errdefer blocks (name -> {})
    errdefer_deinits: std.StringHashMap(void),

    pub fn init(gpa: std.mem.Allocator) Analyzer {
        return .{
            .gpa = gpa,
            .diagnostics = .empty,
            .variables = std.StringHashMap(VarState).init(gpa),
            .tracked_pointers = LinkedList(Provenance.PointerValue).init(gpa),
            .next_ptr_id = 0,
            .functions = std.StringHashMap(FunctionInfo).init(gpa),
            .strictness = .Medium,
            .active_iterators = .empty,
            .thread_spawns = false,
            .has_try = false,
            .errdefer_deinits = std.StringHashMap(void).init(gpa),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        for (self.diagnostics.items) |diag| {
            if (diag.fix) |fix| {
                self.gpa.free(fix.replacements);
            }
        }
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
        self.active_iterators.deinit(self.gpa);
        var ed_iter = self.errdefer_deinits.iterator();
        while (ed_iter.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.errdefer_deinits.deinit();
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

        // Pass 3: Check for raw builtins across entire file
        try self.checkBuiltins(file_path, ast_box.ptr);
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

        // Clear per-function state
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.variables.clearRetainingCapacity();
        self.active_iterators.clearRetainingCapacity();
        self.thread_spawns = false;
        self.has_try = false;
        var ed_iter = self.errdefer_deinits.iterator();
        while (ed_iter.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.errdefer_deinits.clearRetainingCapacity();

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
            // Resource leak in error paths
            if (self.has_try and var_state.is_live and isZustType(var_state.type_category)) {
                if (!self.errdefer_deinits.contains(var_state.name)) {
                    var errdefer_replacements = try self.gpa.alloc(Diagnostic.Replacement, 1);
                    errdefer_replacements[0] = .{
                        .start_line = var_state.decl_line,
                        .start_col = 0,
                        .end_line = var_state.decl_line,
                        .end_col = 0,
                        .new_text = "errdefer resource.deinit();\n",
                    };
                    try self.addDiagnosticWithFix(file_path, .MemoryLeak, "Resource leak: not deinit'd in error path", var_state.decl_line, var_state.decl_col, .{
                        .description = "Add errdefer deinit",
                        .replacements = errdefer_replacements,
                    });
                }
            }
            // General leak check for zust types
            if (var_state.is_live and isZustType(var_state.type_category)) {
                if (var_state.type_category != .ManuallyDrop and var_state.type_category != .Mutex and var_state.type_category != .RwLock) {
                    var defer_replacements = try self.gpa.alloc(Diagnostic.Replacement, 1);
                    defer_replacements[0] = .{
                        .start_line = var_state.decl_line,
                        .start_col = 0,
                        .end_line = var_state.decl_line,
                        .end_col = 0,
                        .new_text = "defer box.deinit();\n",
                    };
                    try self.addDiagnosticWithFix(file_path, .MemoryLeak, "Memory leak: zust type never freed before end of function", var_state.decl_line, var_state.decl_col, .{
                        .description = "Add defer deinit",
                        .replacements = defer_replacements,
                    });
                }
            }
            // Resource leak check for std file/socket handles and raw allocations
            if (var_state.is_std_resource and var_state.is_live and !var_state.has_cleanup) {
                try self.addDiagnostic(file_path, .MemoryLeak, "Resource leak: file/socket handle or raw allocation not closed before end of function; consider defer close() or destroy()", var_state.decl_line, var_state.decl_col);
            }
            // Race condition detection
            if (self.thread_spawns and var_state.is_mutable and var_state.is_read and var_state.is_written) {
                try self.addDiagnostic(file_path, .DataRace, "Possible race condition: shared mutable state", var_state.decl_line, var_state.decl_col);
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
            .if_simple, .@"if" => {
                try self.analyzeIf(file_path, ast, stmt);
            },
            .while_simple, .while_cont => {
                try self.analyzeWhile(file_path, ast, stmt);
            },
            .for_simple, .for_range => {
                try self.analyzeFor(file_path, ast, stmt);
            },
            .@"try" => {
                self.has_try = true;
                const data = ast.nodes.items(.data)[@intFromEnum(stmt)];
                try self.findCallsInExpr(file_path, ast, data.node);
                try self.checkDerefs(file_path, ast, data.node);
                try self.markReadsInExpr(file_path, ast, data.node);
            },
            .@"errdefer" => {
                // Errdefer body executes only on error paths.
                // We analyze it to catch error-path deallocations.
                const data = ast.nodes.items(.data)[@intFromEnum(stmt)];
                const body = data.opt_token_and_node[1];
                // Save current state so errdefer analysis is isolated
                var saved = try self.cloneVariables();
                defer {
                    var it = saved.iterator();
                    while (it.next()) |entry| {
                        self.gpa.free(entry.key_ptr.*);
                    }
                    saved.deinit();
                }
                try self.analyzeBlock(file_path, ast, body);
                try self.recordErrdeferDeinits(saved);
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
        const is_mutable = ast.tokens.items(.tag)[main_token] == .keyword_var;

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
            // Mark reads from init expression
            try self.markReadsInExpr(file_path, ast, init_expr);

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
                    .is_mutable = is_mutable,
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
                    .is_mutable = is_mutable,
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
                    .is_mutable = is_mutable,
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
                    .is_mutable = is_mutable,
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
                    .is_mutable = is_mutable,
                });
                // Analyze init expression for calls (thread spawn, cross-function, etc.)
                try self.findCallsInExpr(file_path, ast, init_expr);
            }

            // Mark declared variable as written (initialized)
            if (self.variables.getPtr(decl_name)) |var_state| {
                var_state.is_written = true;
            }

            // Detect zust type from initialization for all declarations
            if (detectZustInit(ast, init_expr)) |category| {
                if (self.variables.getPtr(decl_name)) |var_state| {
                    var_state.type_category = category;
                    switch (category) {
                        .OnceCell, .LazyCell, .OnceBox, .MaybeUninit => {
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

            // Detect std resource initialization (File, socket, etc.)
            if (isStdResourceInit(ast, init_expr)) {
                if (self.variables.getPtr(decl_name)) |var_state| {
                    var_state.is_std_resource = true;
                }
            }

            // Detect raw allocator.create() for cleanup tracking
            if (isRawCreateCall(ast, init_expr)) {
                if (self.variables.getPtr(decl_name)) |var_state| {
                    var_state.is_std_resource = true;
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
        } else {
            const name_copy = try self.gpa.dupe(u8, decl_name);
            try self.variables.put(name_copy, .{
                .name = name_copy,
                .is_box = false,
                .is_live = true,
                .origin = .None,
                .decl_line = @intCast(token_loc.line),
                .decl_col = @intCast(token_loc.column),
                .is_mutable = is_mutable,
            });
        }

        // Update initialization, null status, and array length
        if (self.variables.getPtr(decl_name)) |var_state| {
            if (init_node) |init_expr| {
                if (!isUndefinedLiteral(ast, init_expr) and var_state.type_category != .MaybeUninit and var_state.type_category != .OnceCell and var_state.type_category != .LazyCell and var_state.type_category != .OnceBox) {
                    var_state.is_initialized = true;
                }
                if (isNullLiteral(ast, init_expr)) {
                    var_state.null_status = .null;
                } else {
                    var_state.null_status = .non_null;
                }
            }
            if (ast.fullVarDecl(node)) |var_decl| {
                if (var_decl.ast.type_node.unwrap()) |type_node| {
                    const type_tag = ast.nodes.items(.tag)[@intFromEnum(type_node)];
                    if (type_tag == .array_type or type_tag == .array_type_sentinel) {
                        const type_data = ast.nodes.items(.data)[@intFromEnum(type_node)];
                        if (getIntLiteralValue(ast, type_data.node_and_node[0])) |len| {
                            var_state.array_len = len;
                        }
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
                var_state.is_written = true;
                var_state.is_initialized = true;
                if (isNullLiteral(ast, rhs)) {
                    var_state.null_status = .null;
                } else {
                    var_state.null_status = .non_null;
                }
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

        // Must-use: detect _ = zust_type.init()
        if (lhs_name) |name| {
            if (std.mem.eql(u8, name, "_") and isZustInitCall(ast, rhs)) {
                const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                try self.addDiagnostic(file_path, .MemoryLeak, "Must-use return value: resource created but not stored", @intCast(token_loc.line), @intCast(token_loc.column));
            }
        }

        // Mark reads in rhs
        try self.markReadsInExpr(file_path, ast, rhs);

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
                    if (self.variables.getPtr(name)) |var_state| {
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
                        if (!var_state.is_initialized and var_state.type_category != .OnceCell and var_state.type_category != .LazyCell and var_state.type_category != .OnceBox and var_state.type_category != .MaybeUninit) {
                            const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                            try self.addDiagnostic(file_path, .NotInitialized, "use of uninitialized variable", @intCast(token_loc.line), @intCast(token_loc.column));
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

            // Mark base variable as read
            if (self.variables.getPtr(base_var)) |var_state| {
                var_state.is_read = true;
                if (!var_state.is_initialized and var_state.type_category != .OnceCell and var_state.type_category != .LazyCell and var_state.type_category != .OnceBox and var_state.type_category != .MaybeUninit) {
                    try self.addDiagnostic(file_path, .NotInitialized, "use of uninitialized variable", @intCast(token_loc.line), @intCast(token_loc.column));
                }
            }

            // Iterator invalidation detection
            if (isMutableCollectionMethod(method)) {
                for (self.active_iterators.items) |iter| {
                    if (std.mem.eql(u8, iter.collection_var, base_var)) {
                        try self.addDiagnostic(file_path, .IteratorInvalidation, "Iterator invalidation: modifying collection during iteration", @intCast(token_loc.line), @intCast(token_loc.column));
                    }
                }
            }

            const mk = methodKindFromName(method);

            // Type-specific method checks
            if (self.variables.getPtr(base_var)) |var_state| {
                switch (var_state.type_category) {
                    .ManuallyDrop => switch (mk) {
                        .drop, .take => var_state.is_dropped = true,
                        else => {},
                    },
                    .OnceCell, .OnceBox => switch (mk) {
                        .set => {
                            if (var_state.is_initialized) {
                                try self.addDiagnostic(file_path, .AlreadyInitialized, "double set on OnceCell; use getOrInit() for idempotent initialization", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                            var_state.is_initialized = true;
                        },
                        .get => {
                            if (!var_state.is_initialized) {
                                try self.addDiagnostic(file_path, .NotInitialized, "reading uninitialized OnceCell; initialize with set() or use LazyCell", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                        },
                        else => {},
                    },
                    .MaybeUninit => switch (mk) {
                        .assumeInit => {
                            if (!var_state.is_initialized) {
                                try self.addDiagnostic(file_path, .NotInitialized, "calling assumeInit() on uninitialized MaybeUninit; call write() first", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                        },
                        .write => var_state.is_initialized = true,
                        else => {},
                    },
                    .Channel => switch (mk) {
                        .close => var_state.is_closed = true,
                        .send => {
                            if (var_state.is_closed) {
                                try self.addDiagnostic(file_path, .ChannelClosed, "sending to closed Channel", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                        },
                        else => {},
                    },
                    .Oneshot => switch (mk) {
                        .send => {
                            if (var_state.is_sent) {
                                try self.addDiagnostic(file_path, .AlreadySent, "double send on Oneshot; can only send once", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                            var_state.is_sent = true;
                        },
                        else => {},
                    },
                    .Mutex, .RwLock => switch (mk) {
                        .lock, .readLock, .writeLock => {
                            if (var_state.is_locked) {
                                try self.addDiagnostic(file_path, .Deadlock, "locking an already-locked Mutex/RwLock; potential deadlock", @intCast(token_loc.line), @intCast(token_loc.column));
                            }
                            var_state.is_locked = true;
                        },
                        .unlock, .readUnlock, .writeUnlock => var_state.is_locked = false,
                        else => {},
                    },
                    else => {},
                }
            }

            switch (mk) {
                .deinit => try self.checkDeinit(file_path, ast, node),
                .unsafePtr => {},
                .borrowMut => {},
                .destroy => try self.checkDestroy(file_path, ast, node),
                .create => try self.checkRawCreate(file_path, ast, node),
                .close => {
                    if (self.variables.getPtr(base_var)) |var_state| {
                        var_state.has_cleanup = true;
                    }
                },
                else => {},
            }
            // Thread spawn detection for method calls too
            if (isThreadSpawnCall(ast, node)) {
                self.thread_spawns = true;
            }
        } else {
            // Regular function call - check if any args are dangling pointers
            try self.checkCallArgs(file_path, ast, node);
            // Cross-function analysis
            try self.checkCrossFunctionCall(file_path, ast, node, callee);
            // Thread spawn detection
            if (isThreadSpawnCall(ast, node)) {
                self.thread_spawns = true;
            }
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
        var replacements = try self.gpa.alloc(Diagnostic.Replacement, 1);
        replacements[0] = .{
            .start_line = @intCast(token_loc.line),
            .start_col = 0,
            .end_line = @intCast(token_loc.line),
            .end_col = 999,
            .new_text = "safe.Box(T, 0, 0, 0).init(allocator, value)",
        };
        try self.addDiagnosticWithFix(file_path, .UseAfterFree, "raw allocator.create(T) detected; consider using safe.Box(T, 0, 0, 0).init(allocator, value) instead", @intCast(token_loc.line), @intCast(token_loc.column), .{
            .description = "Replace with safe.Box",
            .replacements = replacements,
        });
    }

    fn checkDeinit(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const base_var = getCallBaseVar(ast, node);
        const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);

        if (self.variables.getPtr(base_var)) |var_state| {
            if (!var_state.is_live) {
                var replacements = try self.gpa.alloc(Diagnostic.Replacement, 1);
                replacements[0] = .{
                    .start_line = @intCast(token_loc.line),
                    .start_col = 0,
                    .end_line = @intCast(token_loc.line),
                    .end_col = 999,
                    .new_text = "",
                };
                try self.addDiagnosticWithFix(file_path, .DoubleFree, "double free detected", @intCast(token_loc.line), @intCast(token_loc.column), .{
                    .description = "Remove duplicate deinit",
                    .replacements = replacements,
                });
            } else if (!var_state.is_box) {
                try self.addDiagnostic(file_path, .UseAfterFree, "deinit called on non-Box type", @intCast(token_loc.line), @intCast(token_loc.column));
            } else {
                // Mark as deallocated
                var_state.is_live = false;
                var_state.has_cleanup = true;

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
                var_state.has_cleanup = true;
            }
        } else {
            // Raw destroy on untracked pointer - suggest using Box
            try self.addDiagnostic(file_path, .UseAfterFree, "raw allocator.destroy(ptr) detected; consider using safe.Box(T, 0, 0, 0).deinit() instead", @intCast(token_loc.line), @intCast(token_loc.column));
        }
    }

    fn checkBuiltins(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast) AnalyzeError!void {
        const tags = ast.nodes.items(.tag);
        for (tags, 0..) |tag, i| {
            switch (tag) {
                .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                    const main_token = ast.nodes.items(.main_token)[i];
                    const builtin_name = ast.tokenSlice(main_token);
                    if (std.mem.eql(u8, builtin_name, "@ptrCast") or std.mem.eql(u8, builtin_name, "@alignCast")) {
                        const token_loc = ast.tokenLocation(0, main_token);
                        try self.addDiagnostic(file_path, .RawPattern, "raw unsafe cast detected; consider using safe types for type-safe conversions", @intCast(token_loc.line), @intCast(token_loc.column));
                    }
                },
                else => {},
            }
        }
    }

    fn checkDerefs(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
        switch (tag) {
            .deref => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                const inner = data.node;
                if (getVarName(ast, inner)) |var_name| {
                    if (self.variables.getPtr(var_name)) |var_state| {
                        var_state.is_read = true;
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
            .unwrap_optional => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                const operand = data.node_and_token[0];
                if (getVarName(ast, operand)) |var_name| {
                    if (self.variables.getPtr(var_name)) |var_state| {
                        var_state.is_read = true;
                        if (var_state.null_status == .null) {
                            const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                            var replacements = try self.gpa.alloc(Diagnostic.Replacement, 1);
                            replacements[0] = .{
                                .start_line = @intCast(token_loc.line),
                                .start_col = 0,
                                .end_line = @intCast(token_loc.line),
                                .end_col = 999,
                                .new_text = "opt orelse return error.NullValue",
                            };
                            try self.addDiagnosticWithFix(file_path, .NullDereference, "null pointer dereference", @intCast(token_loc.line), @intCast(token_loc.column), .{
                                .description = "Add null check",
                                .replacements = replacements,
                            });
                        }
                    }
                }
            },
            .@"orelse" => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                const lhs = data.node_and_node[0];
                if (getVarName(ast, lhs)) |var_name| {
                    if (self.variables.getPtr(var_name)) |var_state| {
                        var_state.is_read = true;
                        if (var_state.null_status == .null) {
                            const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                            try self.addDiagnostic(file_path, .NullDereference, "null pointer dereference in orelse", @intCast(token_loc.line), @intCast(token_loc.column));
                        }
                    }
                }
                try self.checkDerefs(file_path, ast, data.node_and_node[1]);
            },
            .array_access => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                const arr_expr = data.node_and_node[0];
                const idx_expr = data.node_and_node[1];
                if (getVarName(ast, arr_expr)) |arr_name| {
                    if (self.variables.get(arr_name)) |var_state| {
                        if (var_state.array_len) |arr_len| {
                            if (getIntLiteralValue(ast, idx_expr)) |idx| {
                                if (idx >= arr_len) {
                                    const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                                    try self.addDiagnostic(file_path, .BufferOverflow, "array index out of bounds", @intCast(token_loc.line), @intCast(token_loc.column));
                                }
                            }
                        }
                    }
                }
                try self.checkDerefs(file_path, ast, idx_expr);
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
                    .@"if" => {
                        try self.checkDerefs(file_path, ast, data.node_and_extra[0]);
                        const extra = ast.extra_data[@intFromEnum(data.node_and_extra[1])..];
                        const then_body: zig.Ast.Node.Index = @enumFromInt(extra[0]);
                        try self.checkDerefs(file_path, ast, then_body);
                        const else_idx = extra[1];
                        if (else_idx != 0) {
                            const else_body: zig.Ast.Node.Index = @enumFromInt(else_idx);
                            try self.checkDerefs(file_path, ast, else_body);
                        }
                    },
                    .unwrap_optional => {
                        try self.checkDerefs(file_path, ast, data.node_and_token[0]);
                    },
                    .@"orelse" => {
                        try self.checkDerefs(file_path, ast, data.node_and_node[0]);
                        try self.checkDerefs(file_path, ast, data.node_and_node[1]);
                    },
                    .array_access => {
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

            if (self.variables.getPtr(arg_name)) |var_state| {
                var_state.is_read = true;
                if (!var_state.is_live) {
                    try self.addDiagnostic(file_path, .UseAfterFree, "use of dangling pointer as function argument", @intCast(token_loc.line), @intCast(token_loc.column));
                }
                if (!var_state.is_initialized and var_state.type_category != .OnceCell and var_state.type_category != .LazyCell and var_state.type_category != .OnceBox and var_state.type_category != .MaybeUninit) {
                    try self.addDiagnostic(file_path, .NotInitialized, "use of uninitialized variable", @intCast(token_loc.line), @intCast(token_loc.column));
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
                .InvalidMove,
                .NullDereference,
                .BufferOverflow,
                .RawPattern => true,
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
                .StdAlternative,
                .NullDereference,
                .BufferOverflow,
                .RawPattern => true,
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
        try self.addDiagnosticWithFix(file_path, kind, message, line, col, null);
    }

    fn addDiagnosticWithFix(
        self: *Analyzer,
        file_path: []const u8,
        kind: Diagnostic.DiagnosticKind,
        message: []const u8,
        line: u32,
        col: u32,
        fix: ?Diagnostic.Fix,
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
                .DoubleFree, .UseAfterFree, .UseAfterMove, .MutableAliasing, .StackUseAfterReturn, .DataRace, .Deadlock, .AlreadyInitialized, .NotInitialized, .ChannelClosed, .AlreadySent, .InvalidMove, .NullDereference, .BufferOverflow => .Error,
                .MemoryLeak, .StdAlternative => .Warning,
                else => .Warning,
            },
            .fix = fix,
        });
    }

    // ─── Control flow ───

    fn analyzeIf(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
        const data = ast.nodes.items(.data)[@intFromEnum(node)];

        var cond_expr: zig.Ast.Node.Index = undefined;
        var then_body: zig.Ast.Node.Index = undefined;
        var else_body: ?zig.Ast.Node.Index = null;

        switch (tag) {
            .if_simple => {
                cond_expr = data.node_and_node[0];
                then_body = data.node_and_node[1];
            },
            .@"if" => {
                cond_expr = data.node_and_extra[0];
                const extra = ast.extra_data[@intFromEnum(data.node_and_extra[1])..];
                then_body = @enumFromInt(extra[0]);
                const else_idx = extra[1];
                if (else_idx != 0) else_body = @enumFromInt(else_idx);
            },
            else => unreachable,
        }

        // Check for optional payload
        var cond_name: ?[]const u8 = null;
        if (ast.fullIf(node)) |full_if| {
            if (full_if.payload_token) |_| {
                cond_name = getVarName(ast, cond_expr);
            }
        }

        // Save current state
        var saved = try self.cloneVariables();
        defer {
            var it = saved.iterator();
            while (it.next()) |entry| {
                self.gpa.free(entry.key_ptr.*);
            }
            saved.deinit();
        }

        // Analyze then branch
        if (cond_name) |cn| {
            if (self.variables.getPtr(cn)) |var_state| {
                var_state.null_status = .non_null;
            }
        }
        try self.analyzeBlock(file_path, ast, then_body);

        // Save then-final state for merging
        var then_state = try self.cloneVariables();
        defer {
            var it2 = then_state.iterator();
            while (it2.next()) |entry| {
                self.gpa.free(entry.key_ptr.*);
            }
            then_state.deinit();
        }

        if (else_body) |else_node| {
            // Restore state for else branch
            try self.restoreVariables(saved);
            if (cond_name) |cn| {
                if (self.variables.getPtr(cn)) |var_state| {
                    var_state.null_status = .null;
                }
            }
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
                var state_copy = entry.value_ptr.*;
                state_copy.name = name_copy;
                try self.variables.put(name_copy, state_copy);
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
        const iterable = data.node_and_node[0];
        const body = data.node_and_node[1];

        if (getCollectionVarFromIterable(ast, iterable)) |collection_var| {
            const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
            try self.active_iterators.append(self.gpa, .{
                .collection_var = collection_var,
                .loop_line = @intCast(token_loc.line),
                .loop_col = @intCast(token_loc.column),
            });
            try self.analyzeBlock(file_path, ast, body);
            _ = self.active_iterators.pop();
        } else {
            try self.analyzeBlock(file_path, ast, body);
        }
    }

    fn cloneVariables(self: *Analyzer) !std.StringHashMap(VarState) {
        var clone = std.StringHashMap(VarState).init(self.gpa);
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            const key_copy = try self.gpa.dupe(u8, entry.key_ptr.*);
            var state_copy = entry.value_ptr.*;
            state_copy.name = key_copy;
            try clone.put(key_copy, state_copy);
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
            var state_copy = entry.value_ptr.*;
            state_copy.name = key_copy;
            try self.variables.put(key_copy, state_copy);
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
            .if_simple, .@"if" => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.findCallsInExpr(file_path, ast, data.node_and_node[0]);
                try self.findCallsInExpr(file_path, ast, data.node_and_node[1]);
            },
            .while_simple, .while_cont => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.findCallsInExpr(file_path, ast, data.node_and_node[0]);
                try self.findCallsInExpr(file_path, ast, data.node_and_node[1]);
            },
            .@"try" => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.findCallsInExpr(file_path, ast, data.node);
            },
            .@"catch" => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.findCallsInExpr(file_path, ast, data.node_and_node[0]);
                try self.findCallsInExpr(file_path, ast, data.node_and_node[1]);
            },
            else => {
                // Leaf node or unhandled - stop recursing
            },
        }
    }

    fn recordErrdeferDeinits(self: *Analyzer, before: std.StringHashMap(VarState)) !void {
        var iter = before.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            if (entry.value_ptr.is_live) {
                if (self.variables.get(name)) |after_state| {
                    if (!after_state.is_live) {
                        const name_copy = try self.gpa.dupe(u8, name);
                        try self.errdefer_deinits.put(name_copy, {});
                    }
                }
            }
        }
    }

    fn markReadsInExpr(self: *Analyzer, file_path: []const u8, ast: *const std.zig.Ast, node: zig.Ast.Node.Index) AnalyzeError!void {
        const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
        switch (tag) {
            .identifier => {
                if (getVarName(ast, node)) |name| {
                    if (self.variables.getPtr(name)) |var_state| {
                        var_state.is_read = true;
                        if (!var_state.is_initialized and var_state.type_category != .OnceCell and var_state.type_category != .LazyCell and var_state.type_category != .OnceBox and var_state.type_category != .MaybeUninit) {
                            const token_loc = ast.tokenLocation(0, ast.nodes.items(.main_token)[@intFromEnum(node)]);
                            try self.addDiagnostic(file_path, .NotInitialized, "use of uninitialized variable", @intCast(token_loc.line), @intCast(token_loc.column));
                        }
                    }
                }
            },
            .call, .call_comma, .call_one, .call_one_comma => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.markReadsInExpr(file_path, ast, getCallee(ast, node));
                switch (tag) {
                    .call_one, .call_one_comma => {
                        if (data.node_and_opt_node[1].unwrap()) |arg| {
                            try self.markReadsInExpr(file_path, ast, arg);
                        }
                    },
                    .call, .call_comma => {
                        const extra = ast.extra_data[@intFromEnum(data.node_and_extra[1])..];
                        if (extra.len > 0) {
                            const arg_count = extra[0];
                            const end = @min(extra.len, 1 + arg_count);
                            for (extra[1..end]) |arg_idx| {
                                try self.markReadsInExpr(file_path, ast, @enumFromInt(arg_idx));
                            }
                        }
                    },
                    else => {},
                }
            },
            .field_access => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.markReadsInExpr(file_path, ast, data.node_and_token[0]);
            },
            .deref => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.markReadsInExpr(file_path, ast, data.node);
            },
            .address_of => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.markReadsInExpr(file_path, ast, data.node);
            },
            .assign => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.markReadsInExpr(file_path, ast, data.node_and_node[1]);
            },
            .add, .add_wrap, .sub, .sub_wrap, .mul, .mul_wrap, .div, .mod,
            .shl, .shl_sat, .shr, .bit_and, .bit_or, .bit_xor,
            .bool_and, .bool_or, .equal_equal, .bang_equal, .less_than, .less_or_equal, .greater_than, .greater_or_equal,
            .array_cat, .merge_error_sets => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.markReadsInExpr(file_path, ast, data.node_and_node[0]);
                try self.markReadsInExpr(file_path, ast, data.node_and_node[1]);
            },
            .@"try" => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.markReadsInExpr(file_path, ast, data.node);
            },
            .@"catch" => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.markReadsInExpr(file_path, ast, data.node_and_node[0]);
                try self.markReadsInExpr(file_path, ast, data.node_and_node[1]);
            },
            .block_two, .block_two_semicolon => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                if (data.opt_node_and_opt_node[0].unwrap()) |n| try self.markReadsInExpr(file_path, ast, n);
                if (data.opt_node_and_opt_node[1].unwrap()) |n| try self.markReadsInExpr(file_path, ast, n);
            },
            .block, .block_semicolon => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                const extra = ast.extra_data[@intFromEnum(data.extra_range.start)..@intFromEnum(data.extra_range.end)];
                for (extra) |n| try self.markReadsInExpr(file_path, ast, @enumFromInt(n));
            },
            .if_simple => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.markReadsInExpr(file_path, ast, data.node_and_node[0]);
                try self.markReadsInExpr(file_path, ast, data.node_and_node[1]);
            },
            .@"if" => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.markReadsInExpr(file_path, ast, data.node_and_extra[0]);
                const extra = ast.extra_data[@intFromEnum(data.node_and_extra[1])..];
                const then_body: zig.Ast.Node.Index = @enumFromInt(extra[0]);
                try self.markReadsInExpr(file_path, ast, then_body);
                const else_idx = extra[1];
                if (else_idx != 0) {
                    const else_body: zig.Ast.Node.Index = @enumFromInt(else_idx);
                    try self.markReadsInExpr(file_path, ast, else_body);
                }
            },
            .while_simple, .while_cont => {
                const data = ast.nodes.items(.data)[@intFromEnum(node)];
                try self.markReadsInExpr(file_path, ast, data.node_and_node[0]);
                try self.markReadsInExpr(file_path, ast, data.node_and_node[1]);
            },
            else => {},
        }
    }
};

const MethodKind = enum {
    drop,
    take,
    deinit,
    unsafePtr,
    borrowMut,
    destroy,
    create,
    set,
    get,
    assumeInit,
    write,
    close,
    send,
    lock,
    readLock,
    writeLock,
    unlock,
    readUnlock,
    writeUnlock,
    none,
};

fn methodKindFromName(name: []const u8) MethodKind {
    const names = &[_][]const u8{
        "drop", "take", "deinit", "unsafePtr", "borrowMut", "destroy", "create",
        "set", "get", "assumeInit", "write", "close", "send",
        "lock", "readLock", "writeLock", "unlock", "readUnlock", "writeUnlock",
    };
    for (names, 0..) |n, i| {
        if (safe.SimdUtils.eql(name, n)) return @enumFromInt(i);
    }
    return .none;
}

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

    const type_table = &[_]struct { []const u8, TypeCategory }{
        .{ "Box", .Box },
        .{ "Rc", .Rc },
        .{ "Arc", .Arc },
        .{ "Weak", .Weak },
        .{ "Mutex", .Mutex },
        .{ "RwLock", .RwLock },
        .{ "Cell", .Cell },
        .{ "RefCell", .RefCell },
        .{ "ManuallyDrop", .ManuallyDrop },
        .{ "MaybeUninit", .MaybeUninit },
        .{ "Pin", .Pin },
        .{ "OnceCell", .OnceCell },
        .{ "LazyCell", .LazyCell },
        .{ "OnceBox", .OnceBox },
        .{ "Channel", .Channel },
        .{ "Oneshot", .Oneshot },
        .{ "String", .String },
        .{ "HashMap", .HashMap },
        .{ "BTreeMap", .BTreeMap },
        .{ "HashSet", .HashSet },
        .{ "BinaryHeap", .BinaryHeap },
        .{ "VecDeque", .VecDeque },
        .{ "LinkedList", .LinkedList },
        .{ "ArrayList", .ArrayList },
        .{ "UnsafeCell", .UnsafeCell },
    };
    for (type_table) |entry| {
        if (safe.SimdUtils.eql(type_name, entry.@"0")) return entry.@"1";
    }
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

fn isZustType(category: TypeCategory) bool {
    return category != .Raw and category != .Unknown;
}

fn isMutableCollectionMethod(name: []const u8) bool {
    const methods = &[_][]const u8{ "append", "remove", "clear", "deinit", "insert", "pop", "resize", "replace" };
    for (methods) |m| {
        if (std.mem.eql(u8, name, m)) return true;
    }
    return false;
}

fn getCollectionVarFromIterable(ast: *const std.zig.Ast, iterable: zig.Ast.Node.Index) ?[]const u8 {
    const tag = ast.nodes.items(.tag)[@intFromEnum(iterable)];
    switch (tag) {
        .call_one, .call_one_comma, .call, .call_comma => {
            const callee = getCallee(ast, iterable);
            return getBaseVar(ast, callee);
        },
        .field_access => {
            return getBaseVar(ast, iterable);
        },
        else => return null,
    }
}

fn isThreadSpawnCall(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    const callee = getCallee(ast, node);
    const method = getMethodName(ast, callee) orelse return false;
    if (!std.mem.eql(u8, method, "spawn")) return false;

    var current = callee;
    while (true) {
        const tag = ast.nodes.items(.tag)[@intFromEnum(current)];
        if (tag == .field_access) {
            const main_token = ast.nodes.items(.main_token)[@intFromEnum(current)];
            const field_name = ast.tokenSlice(main_token + 1);
            if (std.mem.eql(u8, field_name, "Thread")) return true;
            const data = ast.nodes.items(.data)[@intFromEnum(current)];
            current = data.node_and_token[0];
        } else {
            break;
        }
    }
    return false;
}

fn isZustInitCall(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    const unwrapped = unwrapNode(ast, node);
    return detectZustInit(ast, unwrapped) != null;
}

fn isStdResourceInit(ast: *const std.zig.Ast, init_expr: zig.Ast.Node.Index) bool {
    const unwrapped = unwrapNode(ast, init_expr);
    const tag = ast.nodes.items(.tag)[@intFromEnum(unwrapped)];
    if (tag != .call and tag != .call_one and tag != .call_comma and tag != .call_one_comma) return false;

    const callee = getCallee(ast, unwrapped);
    const method = getMethodName(ast, callee) orelse return false;

    const resource_methods = &[_][]const u8{
        "openFile", "createFile", "openDir", "connect", "accept", "socket", "open",
    };
    for (resource_methods) |m| {
        if (std.mem.eql(u8, method, m)) return true;
    }
    return false;
}

fn isRawCreateCall(ast: *const std.zig.Ast, init_expr: zig.Ast.Node.Index) bool {
    const unwrapped = unwrapNode(ast, init_expr);
    const tag = ast.nodes.items(.tag)[@intFromEnum(unwrapped)];
    if (tag != .call and tag != .call_one and tag != .call_comma and tag != .call_one_comma) return false;

    const callee = getCallee(ast, unwrapped);
    return isFieldAccess(ast, callee, "create");
}

fn getIntLiteralValue(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) ?u32 {
    const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
    if (tag == .number_literal) {
        const main_token = ast.nodes.items(.main_token)[@intFromEnum(node)];
        const slice = ast.tokenSlice(main_token);
        return std.fmt.parseInt(u32, slice, 0) catch null;
    }
    return null;
}

fn isNullLiteral(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
    if (tag == .identifier) {
        const main_token = ast.nodes.items(.main_token)[@intFromEnum(node)];
        return std.mem.eql(u8, ast.tokenSlice(main_token), "null");
    }
    return false;
}

fn isUndefinedLiteral(ast: *const std.zig.Ast, node: zig.Ast.Node.Index) bool {
    const tag = ast.nodes.items(.tag)[@intFromEnum(node)];
    if (tag == .identifier) {
        const main_token = ast.nodes.items(.main_token)[@intFromEnum(node)];
        return std.mem.eql(u8, ast.tokenSlice(main_token), "undefined");
    }
    return false;
}

// ─── New bug pattern tests ───

test "analyzer detects iterator invalidation" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testIteratorInvalidation() void {
        \\    var list = safe.ArrayList(i32).init();
        \\    for (list.iter()) |*item| {
        \\        _ = item;
        \\        _ = list.append(42);
        \\    }
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "Iterator invalidation") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "analyzer detects race condition on shared mutable state" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testRace() void {
        \\    var counter: i32 = 0;
        \\    counter = counter + 1;
        \\    const t1 = try std.Thread.spawn(.{}, run, .{});
        \\    const t2 = try std.Thread.spawn(.{}, run, .{});
        \\    _ = t1;
        \\    _ = t2;
        \\}
        \\fn run() void {}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "Possible race condition") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "analyzer detects resource leak in error path" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testLeak() !void {
        \\    var file = safe.FileGuard.init();
        \\    try somethingThatMayFail();
        \\    _ = file;
        \\}
        \\fn somethingThatMayFail() !void { return error.Oops; }
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "Resource leak") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "analyzer detects must-use return value discard" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testMustUse() void {
        \\    _ = safe.Box(i32).init(42);
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "Must-use return value") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "analyzer no false positive iterator invalidation on different collection" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testNoInvalidation() void {
        \\    var list = safe.ArrayList(i32).init();
        \\    var other = safe.ArrayList(i32).init();
        \\    for (list.iter()) |*item| {
        \\        _ = item;
        \\        _ = other.append(42);
        \\    }
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "Iterator invalidation") != null) {
            found = true;
        }
    }
    try std.testing.expect(!found);
}

test "analyzer no false positive race on const variable" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testNoRace() void {
        \\    const counter: i32 = 0;
        \\    const t1 = try std.Thread.spawn(.{}, run, .{});
        \\    _ = t1;
        \\}
        \\fn run() void {}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "Possible race condition") != null) {
            found = true;
        }
    }
    try std.testing.expect(!found);
}

test "analyzer no false positive leak when errdefer cleans up" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testNoLeak() !void {
        \\    var file = safe.FileGuard.init();
        \\    errdefer file.deinit();
        \\    try somethingThatMayFail();
        \\}
        \\fn somethingThatMayFail() !void { return error.Oops; }
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "Resource leak") != null) {
            found = true;
        }
    }
    try std.testing.expect(!found);
}

test "analyzer no false positive must-use when stored" {
    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();

    const source =
        \\fn testStored() void {
        \\    const box = safe.Box(i32).init(42);
        \\    _ = box;
        \\}
    ;

    try analyzer.analyzeFile("test.zig", source, .Medium);

    var found = false;
    for (analyzer.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "Must-use return value") != null) {
            found = true;
        }
    }
    try std.testing.expect(!found);
}
