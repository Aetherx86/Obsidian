# Obsidian

Obsidian is a dual-target (x86_64 / AArch64) micro-JIT machine code assembler and dynamic execution engine written in pure Zig.

## Overview

Obsidian provides a zero-dependency, bare-metal intermediate representation lowering layer. It emits valid machine code bytes directly into memory buffers, switches memory protection flags from writable to executable, and dispatches native function pointers with sub-3 nanosecond calling overhead.

## Architecture

- **Dual-Architecture Emitter**: Encodes native machine instructions for both x86_64 (Intel/AMD) and AArch64 (Apple Silicon / ARMv8+).
- **Executable Page Manager**: Allocates page-aligned memory regions using POSIX `mmap`, applies write barriers, and switches permissions to executable via `mprotect`.
- **Zero Runtime Dependencies**: Completely self-contained without LLVM, Dynasm, or C-compiler toolchain dependencies.

## Performance

- **Invocation Latency**: ~2.31 nanoseconds per JIT call on modern processors.
- **Emission Speed**: > 50,000,000 instructions generated per second in memory.

## Building

```bash
# Run unit tests
zig build test

# Build optimized binary
zig build -Doptimize=ReleaseFast
```

## Usage

```bash
# Assemble and execute JIT-compiled multiplication
./zig-out/bin/obsidian exec mul 7 6

# Benchmark JIT execution overhead
./zig-out/bin/obsidian bench
```

## License

MIT License. Copyright (c) 2026 Jeong Hoon Kim.
