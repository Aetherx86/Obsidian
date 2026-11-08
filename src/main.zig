const std = @import("std");
const builtin = @import("builtin");
pub const emitter = @import("emitter.zig");
pub const jit = @import("jit.zig");

pub fn main(init: std.process.Init) !void {
    _ = init.arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.next(); // skip prog name

    const cmd = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "exec")) {
        const op = args.next() orelse "add";
        const a_str = args.next() orelse "40";
        const b_str = args.next() orelse "2";

        const a = std.fmt.parseInt(i64, a_str, 10) catch 40;
        const b = std.fmt.parseInt(i64, b_str, 10) catch 2;

        std.debug.print("Obsidian Micro-JIT: Assembling machine code for '{s}({d}, {d})' on {s}...\n", .{
            op, a, b, @tagName(builtin.cpu.arch),
        });

        var buf = emitter.Buffer.init();
        if (builtin.cpu.arch == .x86_64) {
            var asm_x86 = emitter.X86Assembler.init(&buf);
            asm_x86.movRaxRdi();
            if (std.mem.eql(u8, op, "sub")) {
                asm_x86.subRaxRsi();
            } else if (std.mem.eql(u8, op, "mul")) {
                asm_x86.imulRaxRsi();
            } else {
                asm_x86.addRaxRsi();
            }
            asm_x86.ret();
        } else if (builtin.cpu.arch == .aarch64) {
            var asm_arm = emitter.Arm64Assembler.init(&buf);
            if (std.mem.eql(u8, op, "sub")) {
                asm_arm.subX0X0X1();
            } else if (std.mem.eql(u8, op, "mul")) {
                asm_arm.mulX0X0X1();
            } else {
                asm_arm.addX0X0X1();
            }
            asm_arm.ret();
        } else {
            std.debug.print("Unsupported architecture for native JIT execution.\n", .{});
            return;
        }

        std.debug.print("Emitted {d} bytes of native machine code: ", .{buf.len});
        for (buf.code[0..buf.len]) |byte| {
            std.debug.print("{x:0>2} ", .{byte});
        }
        std.debug.print("\n", .{});

        var engine = try jit.JitEngine.init();
        defer engine.deinit();

        try engine.loadCode(buf.code[0..buf.len]);
        if (engine.getFunction()) |fun| {
            const res = fun(a, b);
            std.debug.print("Result of JIT-compiled execution: {d}\n", .{res});
        }
    } else if (std.mem.eql(u8, cmd, "bench")) {
        std.debug.print("Benchmarking JIT call overhead vs native loop (1,000,000 iterations)...\n", .{});
        var buf = emitter.Buffer.init();
        if (builtin.cpu.arch == .x86_64) {
            var asm_x86 = emitter.X86Assembler.init(&buf);
            asm_x86.movRaxRdi();
            asm_x86.addRaxRsi();
            asm_x86.ret();
        } else if (builtin.cpu.arch == .aarch64) {
            var asm_arm = emitter.Arm64Assembler.init(&buf);
            asm_arm.addX0X0X1();
            asm_arm.ret();
        }

        var engine = try jit.JitEngine.init();
        defer engine.deinit();
        try engine.loadCode(buf.code[0..buf.len]);

        const fun = engine.getFunction().?;
        var sum: i64 = 0;
        const count: usize = 1_000_000;

        const t0 = std.Io.Clock.Timestamp.now(init.io, .awake);
        for (0..count) |i| {
            sum += fun(@intCast(i), 1);
        }
        const t1 = std.Io.Clock.Timestamp.now(init.io, .awake);
        const duration_ns = t0.durationTo(t1).raw.nanoseconds;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
        const ns_per_call = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(count));

        std.debug.print("Executed {d} JIT calls in {d:.2} ms ({d:.2} ns/call)\n", .{
            count, duration_ms, ns_per_call,
        });
    } else {
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Obsidian: Dual-Target (x86_64 / AArch64) Micro-JIT Engine
        \\Usage:
        \\  obsidian exec [add|sub|mul] [a] [b]
        \\  obsidian bench
        \\  obsidian --help
        \\
    , .{});
}

test {
    _ = @import("emitter.zig");
    _ = @import("jit.zig");
}
