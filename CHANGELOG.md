# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Docker verify step now uses correct image tag (`sha-short` from metadata-action instead of full `github.sha`)
- Transpiler `allocator.free()` replacement now emits `_ = undefined;` no-op instead of bare comment, preventing next statement from becoming loop/if body
- Transpiler now changes unused `for`/`while` captures to `|_|` when body is just `allocator.free(capture)`

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

[0.1.0]: https://github.com/e-jerk/zust/releases/tag/v0.1.0
