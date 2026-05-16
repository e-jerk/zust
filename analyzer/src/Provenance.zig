const std = @import("std");

/// Represents the origin of a pointer value.
pub const Provenance = union(enum) {
    /// Local variable on the stack
    Stack: struct {
        decl_name: []const u8,
        func_name: []const u8,
        loc: SourceLocation,
    },
    /// Heap allocation (e.g., allocator.create())
    Heap: struct {
        alloc_site: SourceLocation,
        allocator_name: []const u8,
    },
    /// A borrow from another provenance
    Borrow: struct {
        source: *Provenance,
        kind: BorrowKind,
        scope: ScopeId,
    },
    /// Derived from another pointer (field access, slice, cast)
    Derived: struct {
        base: *Provenance,
        kind: DerivationKind,
        loc: SourceLocation,
    },
    /// Unknown origin (C API, @ptrFromInt, etc.)
    Unknown: struct {
        reason: []const u8,
        loc: SourceLocation,
    },

    pub const BorrowKind = enum { Immutable, Mutable };
    pub const DerivationKind = enum {
        FieldAccess,
        Slice,
        Deref,
        ArrayIndex,
        PtrCast,
        IntToPtr,
    };
};

pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: u32,

    pub fn format(
        self: SourceLocation,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}:{d}:{d}", .{ self.file, self.line, self.column });
    }
};

pub const ScopeId = u32;

/// A tracked pointer value in the program.
pub const PointerValue = struct {
    id: u32,
    prov: Provenance,
    ty: []const u8, // Type string representation
    is_live: bool,
};

/// Lifetime constraint: pointer must not outlive owner.
pub const LifetimeConstraint = struct {
    ptr_id: u32,
    owner_prov: *Provenance,
    owner_lifetime_end: SourceLocation,
};

/// Function summary for interprocedural analysis.
pub const FunctionSummary = struct {
    name: []const u8,
    params: []ParamSummary,
    return_prov: ?*Provenance,
    may_free: bool, // Whether this function may deallocate memory
    may_store_ptr: bool, // Whether this function may store a pointer argument
};

pub const ParamSummary = struct {
    name: []const u8,
    prov: *Provenance,
    escapes: bool,
    is_mutable: bool,
};
