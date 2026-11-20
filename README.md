# Obsidian

Obsidian is a dual-target (x86_64 / AArch64) micro-JIT machine code assembler and dynamic execution engine written in pure Zig.

## Overview

Obsidian provides a zero-dependency, bare-metal intermediate representation lowering layer. It emits valid machine code bytes directly into memory buffers, switches memory protection flags from writable to executable, and dispatches native function pointers with sub-3 nanosecond calling overhead.

## Architecture

- **Dual-Architecture Emitter**: Encodes native machine instructions for both x86_64 (Intel/AMD) and AArch64 (Apple Silicon / ARMv8+).
- **Executable Page Manager**: Keeps code pages W^X. On macOS/AArch64 pages are mapped with `MAP_JIT`, writes happen between `pthread_jit_write_protect_np(0)` and `(1)`, and `sys_icache_invalidate` flushes the instruction cache. Elsewhere pages are mapped read/write, switched to read/execute with a checked `mprotect`, and AArch64 targets synchronize the instruction cache with `__clear_cache`.
- **Zero Runtime Dependencies**: Completely self-contained without LLVM, Dynasm, or C-compiler toolchain dependencies.

## Performance

- **Invocation Latency**: about 0.7 to 1.2 ns per JIT call on an Apple Silicon Mac and about 1.1 ns on the GitHub ubuntu x86_64 runner (`obsidian bench --json`, `call_overhead_ns`).
- **Compile Speed**: about 19 microseconds to optimize, allocate and emit the benchmark program (`compile_us`), and JIT code runs the benchmark loop about 30 times faster than the IR interpreter.

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

## Compiler pipeline (0.2.0)

Version 0.2.0 adds a complete compile path from a small IR to native code for both targets:

```
text IR -> parser -> verifier -> optimizer -> linear-scan allocator -> x86_64 / AArch64 encoder -> W^X memory
```

- **IR** (`src/ir.zig`): 64-bit integer values in virtual registers; `const`, `mov`, `add sub mul and or xor shl shr sar`, comparisons `eq ne lt le gt ge ult ule ugt uge` (producing 0 or 1), labels, `jmp`, compare-and-branch `br`, `ret`, and `call` to host functions with up to six arguments. Arithmetic wraps; shift counts are taken modulo 64. Functions take up to six parameters.
- **Verifier** (`src/analysis.zig`): CFG construction and backward liveness. Programs that could read a register before it is assigned on some path are rejected.
- **Optimizer** (`src/opt.zig`): constant folding with algebraic identities (`x+0`, `x*1`, `x*0`, `x-x`, `x^x`, shifts by 0, ...), copy propagation, branch folding, unreachable block removal, removal of jumps to the next label and unused labels, and liveness-based dead-code elimination, iterated to a fixed point.
- **Register allocation** (`src/regalloc.zig`): linear scan over liveness-derived intervals, with separate read and write positions per instruction. Values live across a call only receive callee-saved registers; under pressure the interval with the furthest end is spilled to a stack slot, and slots are reused. Every allocation is checked for conflicts before code generation.
- **Back ends** (`src/x86.zig`, `src/a64.zig`): System V x86_64 and AAPCS64 code generation with frames, callee-saved register saving, spill slots, forward and backward branches, and parallel-move resolution (`src/moves.zig`) for parameters and call arguments. Encodings are covered by golden byte tests that were cross-checked against `llvm-mc`.
- **Reference interpreter** (`src/interp.zig`) with a fuel limit, used as the oracle for testing.

### Program files

```
# examples/collatz.oir
fn collatz(n) {
    steps = 0
loop:
    br le n, 1, done
    odd = and n, 1
    br eq odd, 0, even
    t = mul n, 3
    n = add t, 1
    jmp next
even:
    n = sar n, 1
next:
    steps = add steps, 1
    jmp loop
done:
    ret steps
}
```

Operands may be variables or integer literals (decimal or `0x` hex, optionally negative). Comments start with `#` or `//`. Host functions available to `call`: `abs(x)`, `min(a, b)`, `max(a, b)`, `gcd(a, b)`, `clamp(x, lo, hi)`. Parse errors report the line and the offending name.

### Commands

```bash
# Compile with the JIT and run; --check also runs the interpreter and compares
./zig-out/bin/obsidian run examples/collatz.oir 27 --check
./zig-out/bin/obsidian run examples/fib.oir 90 --interp

# Force heavy spilling (registers available to the allocator) and verify
./zig-out/bin/obsidian run examples/mix.oir 12 18 -500 7 9 -33 --regs 0 --check

# Disassembly-style listing: optimizer stats, register assignment per value,
# then offset / bytes / mnemonic interleaved with the IR. Works for either target.
./zig-out/bin/obsidian dump examples/fib.oir --target x86_64
./zig-out/bin/obsidian dump examples/mix.oir --target aarch64 --regs 2

# Differential fuzzing: random terminating programs (loops, branches, early
# returns, calls of every arity) run by the interpreter, by the interpreter
# after optimization, and natively under six optimizer/register-limit settings
./zig-out/bin/obsidian fuzz --seed 7 --count 20000
./zig-out/bin/obsidian fuzz --count 200 --json

# Benchmarks: call overhead, compile+load time, JIT vs interpreter loop speed
./zig-out/bin/obsidian bench --json

./zig-out/bin/obsidian version
```

Example `dump` excerpt (x86_64):

```
                                   ; br ge %3, %0, L1
  0011:  49 39 d0                       cmp r8, rdx
  0014:  0f 8d 1a 00 00 00              jge L1
                                   ; %9 = add %1, %2
  001a:  49 89 f1                       mov r9, rsi
  001d:  49 01 f9                       add r9, rdi
```

`bench --json` prints one JSON object with the fields `version`, `arch`, `os`, `wx_strategy`, `mode`, `call_iterations`, `call_overhead_ns`, `compile_iterations`, `compile_us`, `code_bytes`, `jit_loop_iterations`, `jit_ns_per_iter`, `interp_loop_iterations`, `interp_ns_per_iter` and `speedup`.

### Testing

`zig build test` runs unit tests for every module, including golden encodings for both instruction sets, W^X checks that query the live page protection (`mach_vm_region` on macOS, `/proc/self/maps` on Linux), parser diagnostics and random-input robustness, allocator verification under every register limit, and a differential test over 300 random programs. On Apple Silicon the x86_64 back end can also be executed under Rosetta:

```bash
zig build test -Dtarget=x86_64-macos -frosetta
```

## License

MIT License. Copyright (c) 2026 Jeong Hoon Kim.
