# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-08

### Added
- Initial release of Obsidian: Dual-Target (x86_64 / AArch64) Micro-JIT Engine in Zig.
- Machine code emitter supporting arithmetic, immediate loads, and register operations for x86_64 and AArch64.
- Portable executable memory allocator using mmap and page-aligned mprotect.
- Native invocation harness achieving ~2.31 nanoseconds per JIT call.
- Comprehensive unit test suite covering instruction encoding and native function invocation.
