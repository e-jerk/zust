const std = @import("std");

/// Parse ownership contract annotations from doc comments.
///
/// Functions can declare their ownership contract via doc comments:
/// ```zig
/// /// @safe(takes: *u32 as borrowed, returns: *u32 as owned)
/// fn foo(ptr: *u32) *u32 { ... }
/// ```
///
/// Supported annotations:
/// - `@safe(takes: <param> as <ownership>)` - how a parameter is used
/// - `@safe(returns: <type> as <ownership>)` - what the return value means
/// - `@safe(pure)` - function has no side effects
/// - `@safe(nocapture)` - function doesn't capture/store pointers
///
/// Ownership levels:
/// - `owned` - function takes ownership (will free)
/// - `borrowed` - function borrows temporarily (will not free)
/// - `raw` - function uses raw pointers (unsafe)
pub const Ownership = enum {
    owned, // Takes ownership, caller must not use after call
    borrowed, // Borrows temporarily, caller retains ownership
    raw, // Raw pointer, no guarantees
    unknown, // No annotation provided
};

pub const ParamContract = struct {
    param_name: []const u8,
    ownership: Ownership,
};

pub const FunctionContract = struct {
    name: []const u8,
    params: []ParamContract,
    return_ownership: Ownership,
    nocapture: bool,
    pure: bool,
};

/// Parse a doc comment string for @safe annotations.
/// Uses a fixed-size buffer for params (max 8 parameters).
pub fn parseContract(text: []const u8, buf: *[8]ParamContract) ?FunctionContract {
    // Look for @safe(
    const prefix = "@safe(";
    const start = std.mem.indexOf(u8, text, prefix) orelse return null;
    const after_prefix = start + prefix.len;

    // Find closing )
    const end = std.mem.indexOfScalarPos(u8, text, after_prefix, ')') orelse return null;
    const inner = text[after_prefix..end];

    var contract: FunctionContract = .{
        .name = "",
        .params = &.{},
        .return_ownership = .unknown,
        .nocapture = false,
        .pure = false,
    };

    // Check for nocapture
    if (std.mem.indexOf(u8, inner, "nocapture") != null) {
        contract.nocapture = true;
    }

    // Check for pure
    if (std.mem.indexOf(u8, inner, "pure") != null) {
        contract.pure = true;
    }

    // Parse takes: param as ownership
    var param_count: usize = 0;
    var search_start: usize = 0;
    while (search_start < inner.len) {
        const takes_prefix = "takes:";
        if (std.mem.indexOfPos(u8, inner, search_start, takes_prefix)) |takes_start| {
            const after_takes = takes_start + takes_prefix.len;
            // Find the param name (before "as")
            if (std.mem.indexOfPos(u8, inner, after_takes, " as ")) |as_pos| {
                const param_name = std.mem.trim(u8, inner[after_takes..as_pos], " \t");
                const ownership_text = std.mem.trim(u8, inner[as_pos + 4 ..], " \t,)");
                if (param_count < buf.len) {
                    buf[param_count] = .{
                        .param_name = param_name,
                        .ownership = parseOwnership(ownership_text),
                    };
                    param_count += 1;
                }
                search_start = after_takes + as_pos + 4;
            } else {
                break;
            }
        } else {
            break;
        }
    }
    if (param_count > 0) {
        contract.params = buf[0..param_count];
    }

    // Parse returns: type as ownership
    const returns_prefix = "returns:";
    if (std.mem.indexOf(u8, inner, returns_prefix)) |returns_start| {
        const after_returns = returns_start + returns_prefix.len;
        if (std.mem.indexOf(u8, inner[after_returns..], " as ")) |as_pos| {
            const ownership_text = std.mem.trim(u8, inner[after_returns + as_pos + 4 ..], " \t,)");
            contract.return_ownership = parseOwnership(ownership_text);
        }
    }

    return contract;
}

fn parseOwnership(text: []const u8) Ownership {
    if (std.mem.eql(u8, text, "owned")) return .owned;
    if (std.mem.eql(u8, text, "borrowed")) return .borrowed;
    if (std.mem.eql(u8, text, "raw")) return .raw;
    return .unknown;
}
