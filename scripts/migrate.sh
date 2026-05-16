#!/bin/bash
# migrate.sh — Auto-migrate a Zig project to zust
set -euo pipefail

ZUST_ROOT="/Users/barrett/github.com/e-jerk/zust"
PROJECT_ROOT="$(pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

print_header() {
    echo -e "${CYAN}$1${NC}"
}

# Check prerequisites
if [[ ! -f "${ZUST_ROOT}/zig-out/bin/zust-transpile" ]]; then
    print_error "zust-transpile not found. Build it first:"
    echo "  cd ${ZUST_ROOT}"
    echo "  zig build transpile"
    exit 1
fi

if [[ ! -f "${ZUST_ROOT}/zig-out/bin/zust-analyze" ]]; then
    print_error "zust-analyze not found. Build it first:"
    echo "  cd ${ZUST_ROOT}"
    echo "  zig build"
    exit 1
fi

# Find all .zig files
print_info "Scanning for .zig files..."
mapfile -t zig_files < <(find "$PROJECT_ROOT" -type f -name "*.zig" \
    ! -path "*/zig-cache/*" \
    ! -path "*/zig-out/*" \
    ! -path "*/.git/*" \
    ! -path "*/lib/zust/*" \
    ! -path "*/lib/safe.zig" \
    | sort)

total_files=${#zig_files[@]}

if [[ $total_files -eq 0 ]]; then
    print_error "No .zig files found in ${PROJECT_ROOT}"
    exit 1
fi

print_success "Found ${total_files} .zig files"

# Create output directory
OUTPUT_DIR="${PROJECT_ROOT}/.zust-migrate"
mkdir -p "$OUTPUT_DIR"

# Run analysis on all files
print_info "Running zust-analyze on all files..."
DIAG_FILE="${OUTPUT_DIR}/diagnostics.txt"
"${ZUST_ROOT}/zig-out/bin/zust-analyze" "$PROJECT_ROOT" > "$DIAG_FILE" 2>&1 || true

# Count diagnostics
total_warnings=$(grep -c "warning:" "$DIAG_FILE" 2>/dev/null || true)
total_errors=$(grep -c "error:" "$DIAG_FILE" 2>/dev/null || true)

# Transpile each file
print_info "Transpiling files..."
transpiled_count=0
skipped_count=0
failed_count=0

for file in "${zig_files[@]}"; do
    rel_path="${file#$PROJECT_ROOT/}"
    out_file="${OUTPUT_DIR}/${rel_path}"
    out_dir=$(dirname "$out_file")
    mkdir -p "$out_dir"
    
    print_info "Transpiling: ${rel_path}"
    
    if "${ZUST_ROOT}/zig-out/bin/zust-transpile" "$file" "$out_file" 2>/dev/null; then
        ((transpiled_count++)) || true
        print_success "  → ${rel_path}.zust"
    else
        print_warn "  → Failed to transpile (copying original for reference)"
        cp "$file" "$out_file"
        ((failed_count++)) || true
    fi
done

# Generate report
REPORT_FILE="${OUTPUT_DIR}/REPORT.md"
cat > "$REPORT_FILE" <<EOF
# Zust Migration Report

Generated: $(date)
Project: ${PROJECT_ROOT}

## Summary

| Metric | Count |
|--------|-------|
| Total .zig files scanned | ${total_files} |
| Files transpiled | ${transpiled_count} |
| Transpilation failures | ${failed_count} |
| Analyzer warnings | ${total_warnings} |
| Analyzer errors | ${total_errors} |

## File List

EOF

for file in "${zig_files[@]}"; do
    rel_path="${file#$PROJECT_ROOT/}"
    out_file="${OUTPUT_DIR}/${rel_path}"
    if [[ -f "${out_file}" ]] && ! cmp -s "$file" "$out_file"; then
        echo "- ✅ ${rel_path} → .zust-migrate/${rel_path}" >> "$REPORT_FILE"
    else
        echo "- ⚠️  ${rel_path} (no changes or failed)" >> "$REPORT_FILE"
    fi
done

cat >> "$REPORT_FILE" <<EOF

## Unsafe Patterns Found

See full diagnostics: \`.zust-migrate/diagnostics.txt\`

Top patterns:
EOF

# Extract top patterns from diagnostics
grep -oE "(allocator\.create|allocator\.destroy|std\.ArrayList|std\.StringHashMap|std\.Thread\.Mutex|\.\?\b|var [a-z_]+: [a-z0-9_]+;)" "$DIAG_FILE" 2>/dev/null | sort | uniq -c | sort -rn | head -10 >> "$REPORT_FILE" || true

cat >> "$REPORT_FILE" <<EOF

## Next Steps

1. Review transpiled files in \`.zust-migrate/\`
2. Replace originals manually or with:
   \`\`\`bash
   for f in \$(find .zust-migrate -name "*.zig"); do
       orig="\${f#.zust-migrate/}"
       cp "\$f" "\$orig"
   done
   \`\`\`
3. Fix remaining issues flagged in diagnostics.txt
4. Run \`zig build test\` to verify

## Common Fixes

| Pattern | Fix |
|---------|-----|
| \`defer list.deinit()\` | \`defer list.deinit(allocator)\` (zust collections need allocator) |
| \`list.append(x)\` | \`list.append(allocator, x)\` |
| \`box.ptr.*\` | \`box.withImm(ctx, callback)\` or \`box.borrowImm()\` |
| \`mutex.lock()\` then \`mutex.unlock()\` | Use \`guard = mutex.acquire(); guard.deinit();\` |

EOF

# Print summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "Migration complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_header "Summary"
echo "  Total files:       ${total_files}"
echo "  Transpiled:        ${transpiled_count}"
echo "  Failed:            ${failed_count}"
echo "  Warnings:          ${total_warnings}"
echo "  Errors:            ${total_errors}"
echo ""
print_info "Review the report:   cat .zust-migrate/REPORT.md"
print_info "Full diagnostics:    cat .zust-migrate/diagnostics.txt"
print_info "Transpiled files:    ls .zust-migrate/"
echo ""
print_warn "Transpiled files are in .zust-migrate/ — NOT yet applied to your project."
echo ""
echo "To apply changes (review first!):"
echo "  find .zust-migrate -name '*.zig' | while read f; do"
echo "    orig=\"\${f#.zust-migrate/}\""
echo "    cp \"\$f\" \"\$orig\""
echo "  done"
echo ""
echo "Or use rsync for directories:"
echo "  rsync -av .zust-migrate/src/ src/"
echo ""
