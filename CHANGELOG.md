# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-11-20

### Added
- Integer IR with labels, jumps, compare-and-branch, comparisons, shifts, bitwise operations and calls to host functions (up to six arguments), plus a structural verifier and a liveness-based use-before-definition check.
- Optimizer: constant folding with algebraic simplification, copy propagation, branch folding, unreachable code removal, jump and label cleanup, and dead-code elimination, iterated to a fixed point.
- Linear-scan register allocator with separate read/write positions, call-aware register classes (callee-saved registers for values live across calls), spilling of the furthest-ending interval, stack slot reuse and an allocation verifier.
- x86_64 (System V) and AArch64 (AAPCS64) code generators with stack frames, spill slots, callee-saved register handling, branch patching and parallel-move resolution for parameters and call arguments. Either target can be generated on any host.
- W^X executable memory: `MAP_JIT` with `pthread_jit_write_protect_np` and `sys_icache_invalidate` on macOS/AArch64; checked `mprotect` RW to RX elsewhere, with `__clear_cache` on AArch64.
- Reference interpreter with a fuel limit.
- Text IR parser with line-numbered diagnostics and literal operands.
- CLI subcommands: `run` (with `--check`, `--interp`, `--no-opt`, `--regs`), `dump` (disassembly-style listing for either target with register assignments), `fuzz` (differential testing, `--json`), `bench --json`, and `version`.
- Example programs in `examples/`.
- Tests: golden encodings for both instruction sets (cross-checked against `llvm-mc`), live page-protection checks, parser hostile-input tests, allocator verification under every register limit, and a differential test comparing interpreter, optimized interpreter and native code on random programs.

### Changed
- `JitEngine` now uses the W^X executable memory layer: protection changes are checked, the instruction cache is synchronized, and `loadCode` can be called more than once.
- `bench` reports compile-and-load time and JIT versus interpreter loop throughput in addition to call overhead.

### Fixed
- CI now pins `mlugg/setup-zig` to an existing commit (v2.2.1) and also runs ReleaseSafe tests, the example programs, the fuzzer and an aarch64-linux cross build.

## [0.1.0] - 2026-11-08

### Added
- Initial release of Obsidian: Dual-Target (x86_64 / AArch64) Micro-JIT Engine in Zig.
- Machine code emitter supporting arithmetic, immediate loads, and register operations for x86_64 and AArch64.
- Portable executable memory allocator using mmap and page-aligned mprotect.
- Native invocation harness achieving ~2.31 nanoseconds per JIT call.
- Comprehensive unit test suite covering instruction encoding and native function invocation.
