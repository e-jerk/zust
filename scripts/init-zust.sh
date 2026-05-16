#!/bin/bash
# init-zust.sh — One-command zust integration for Zig projects
set -euo pipefail

ZUST_ROOT="/Users/barrett/github.com/e-jerk/zust"
PROJECT_ROOT="$(pwd)"
BUILD_ZIG="${PROJECT_ROOT}/build.zig"
BUILD_ZON="${PROJECT_ROOT}/build.zig.zon"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_error() {
    echo -e "${RED}Error:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_info() {
    echo -e "${BLUE}→${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Step 1: Check for build.zig
if [[ ! -f "$BUILD_ZIG" ]]; then
    print_error "No build.zig found in current directory."
    echo ""
    echo "Run this script from the root of a Zig project (where build.zig lives)."
    echo "To create a new Zig project:"
    echo "  mkdir myproject && cd myproject"
    echo "  zig init"
    echo "  ${ZUST_ROOT}/scripts/init-zust.sh"
    exit 1
fi

# Step 2: Check if zust is already integrated
if grep -q "zust\|safe_module" "$BUILD_ZIG" 2>/dev/null; then
    print_warn "zust appears to already be integrated in build.zig"
    echo "Skipping integration snippet. If you want to re-add it, edit build.zig manually."
    exit 0
fi

# Step 3: Backup build.zig
cp "$BUILD_ZIG" "${BUILD_ZIG}.bak"
print_success "Backed up build.zig → build.zig.bak"

# Step 4: Detect project structure
has_executable=false
has_multiple=false
if grep -q "addExecutable" "$BUILD_ZIG" 2>/dev/null; then
    exe_count=$(grep -c "addExecutable" "$BUILD_ZIG" || true)
    if [[ "$exe_count" -eq 1 ]]; then
        has_executable=true
    else
        has_multiple=true
    fi
fi

# Step 5: Print integration snippet
echo ""
echo "============================================================"
echo "  Add this to your build.zig (copy-paste the snippet below)"
echo "============================================================"
echo ""
echo "// --- zust integration ---"
echo "const safe_module = b.addModule(\"safe\", .{"
echo "    .root_source_file = b.path(\"lib/safe.zig\"),"
echo "});"
echo ""

if $has_executable; then
    echo "// Add this AFTER your .addExecutable(...) call:"
    echo "exe.root_module.addImport(\"safe\", safe_module);"
    echo ""
    print_info "Detected a single executable. Would you like me to append this automatically?"
    echo "  Run: ${ZUST_ROOT}/scripts/init-zust.sh --apply"
    echo ""
fi

if $has_multiple; then
    echo "// You have multiple executables/tests. Add this after EACH one:"
    echo "//    exe.root_module.addImport(\"safe\", safe_module);"
    echo "//    test.root_module.addImport(\"safe\", safe_module);"
    echo ""
fi

echo "============================================================"

# Step 6: Check if safe.zig exists or needs to be copied
if [[ ! -f "${PROJECT_ROOT}/lib/safe.zig" ]]; then
    if [[ -f "${ZUST_ROOT}/lib/safe.zig" ]]; then
        echo ""
        print_info "lib/safe.zig not found in your project."
        echo "Copy zust library into your project:"
        echo ""
        echo "  mkdir -p ${PROJECT_ROOT}/lib"
        echo "  cp -r ${ZUST_ROOT}/lib/*.zig ${PROJECT_ROOT}/lib/"
        echo ""
        echo "Or add zust as a git submodule:"
        echo "  git submodule add https://github.com/e-jerk/zust.git lib/zust"
        echo "  ln -s lib/zust/lib/safe.zig lib/safe.zig"
    else
        print_warn "zust library not found at ${ZUST_ROOT}/lib/safe.zig"
        echo "Clone zust first:"
        echo "  git clone https://github.com/e-jerk/zust.git ${ZUST_ROOT}"
    fi
fi

# Step 7: Print success message
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "zust integration ready!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "  1. Copy the snippet above into your build.zig"
echo "  2. Copy lib/safe.zig (or link to zust/lib/)"
echo "  3. Add 'const safe = @import(\"safe\");' to your .zig files"
echo "  4. Replace unsafe types (see MIGRATING.md)"
echo ""
echo "Quick test:"
echo "  const safe = @import(\"safe\");"
echo "  const Box = safe.Box;"
echo "  const box = try Box(u32, 0, 0, 0).init(allocator, 42);"
echo "  const dead = box.deinit();"
echo "  _ = dead;"
echo ""

# Optional: --apply flag auto-modifies build.zig for simple cases
if [[ "${1:-}" == "--apply" ]] && $has_executable; then
    # Find the line with addExecutable and append after the next semicolon or closing paren
    # This is a best-effort heuristic for simple build.zig files
    print_info "Attempting automatic integration..."
    
    # Check if the file is simple enough to modify safely
    if grep -q "addExecutable.*root_module\|addExecutable.*root_source_file" "$BUILD_ZIG"; then
        print_error "build.zig uses modern .root_module syntax; manual integration is safer."
        exit 1
    fi
    
    # Insert safe_module before the first addExecutable
    if grep -q "const exe = b.addExecutable" "$BUILD_ZIG"; then
        sed -i.bak2 '/const exe = b.addExecutable/i \
    // --- zust integration ---\
    const safe_module = b.addModule("safe", .{\
        .root_source_file = b.path("lib/safe.zig"),\
    });\
' "$BUILD_ZIG"
        
        # Append import after exe declaration
        sed -i.bak3 '/const exe = b.addExecutable/a \
    exe.root_module.addImport("safe", safe_module);' "$BUILD_ZIG"
        
        print_success "Modified build.zig automatically. Review changes with: git diff"
    else
        print_error "Could not find 'const exe = b.addExecutable' pattern. Manual integration needed."
    fi
fi
