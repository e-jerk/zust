# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-05-23

### Added
- **Call graph analysis** (`tools/call_graph.zig`) — Interprocedural reasoning for targeted `safe` import insertion and conversion scope
- **Intra-function variable tracking** — Detects variable reassignments from raw pointer to `safe.Box` to avoid redundant conversions
- **Conditional defer destroy** — Converts `allocator.free(x)` inside `if` blocks to conditional `defer` patterns
- **AST-based `@ptrCast` analysis** — Detects guaranteed-aligned sources (`.address_of`, `.field_access .ptr`) to avoid false warnings
- **Same-size primitive `@bitCast` detection** — Uses AST nodes instead of regex to verify safe primitive bit casts
- **`*T` → `safe.Box(T)` parameter conversion** — Automatically converts raw pointer parameters to owned Box types
- **Scoped import skip** — Won't duplicate `const safe = @import("safe");` if file already has one
- **Bulk Bun codebase support** — Tested on 1288+ files with 98.6% conversion rate
- **Tuple literal fix** — Preserves tuple syntax during transpilation
- **Pool disable** — Disables `safe.Pool` generation (type needs redesign)

### Fixed
- Docker verify step now uses correct image tag (`sha-short` from metadata-action instead of full `github.sha`)
- Transpiler `allocator.free()` replacement now emits `_ = undefined;` no-op instead of bare comment, preventing next statement from becoming loop/if body
- Transpiler now changes unused `for`/`while` captures to `|_|` when body is just `allocator.free(capture)`
- Preserve `errdefer` prefix when converting `allocator.destroy` to `Box.deinit`
- Phase 1 explicit pointer check to avoid converting already-safe patterns
- 15 transpiler bug fixes for maximum coverage on real-world codebases

## [0.1.0] - 2026-05-20

### Added
- Self-hosted transpiler that rewrites unsafe Zig into zust-safe equivalents
- 36 regression tests covering all transpiler patterns
- Release workflow building binaries for macOS (arm64, x86_64), Linux (amd64, arm64), Windows (x86_64)
- Multi-arch Docker images (linux/amd64, linux/arm64) with SBOM and provenance attestation
- zust-analyze static analyzer with 30+ detections
- zust-transpile CLI tool
- Memory-safe types: Box, ArrayList, HashMap, String, GuardedSlice, Arena, Mutex, Pool, Arc, BTreeSet, CheckedInt, SimdUtils, RingBuffer
- Documentation site with Rust↔zust comparison and API reference

### Changed
- Docker base images upgraded from Alpine 3.19 to 3.21 for statx(2) compatibility
- CI switched to `mlugg/setup-zig@v2` for reliable Zig installation
- Single-allocator consistency enforced across all types

### Fixed
- Transpiler: defer/errdefer stripping, optional unwraps, array/C-struct zero-init, `*bool` derefs, `for (slice) |*item|` loops, fn proto warnings, `@ptrCast`/`@bitCast`/`@memcpy` preservation
- Analyzer: while_cont crash, analyzeFor AST union access, formatting issues
- 11 new transpiler regression tests added

[0.2.0]: https://github.com/e-jerk/zust/releases/tag/v0.2.0
[0.1.0]: https://github.com/e-jerk/zust/releases/tag/v0.1.0
