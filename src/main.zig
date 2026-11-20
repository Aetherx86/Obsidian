const std = @import("std");
const builtin = @import("builtin");
pub const emitter = @import("emitter.zig");
pub const jit = @import("jit.zig");
pub const ir = @import("ir.zig");
pub const analysis = @import("analysis.zig");
pub const interp = @import("interp.zig");
pub const opt = @import("opt.zig");
pub const regalloc = @import("regalloc.zig");
pub const x86 = @import("x86.zig");
pub const a64 = @import("a64.zig");
pub const exec_mem = @import("exec_mem.zig");
pub const compiler = @import("compiler.zig");
pub const parse = @import("parse.zig");
pub const listing = @import("listing.zig");
pub const fuzz = @import("fuzz.zig");

pub const version = "0.2.0";

const Writer = std.Io.Writer;

const sum_squares_src =
    \\fn sum_squares(n) {
    \\    s = 0
    \\    i = 0
    \\loop:
    \\    br ge i, n, done
    \\    t = mul i, i
    \\    s = add s, t
    \\    i = add i, 1
    \\    jmp loop
    \\done:
    \\    ret s
    \\}
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [8192]u8 = undefined;
    var out_file = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    if (argv.len < 2) {
        printUsage();
        return;
    }
    const cmd: []const u8 = argv[1];
    const rest = argv[2..];

    const result = if (std.mem.eql(u8, cmd, "exec"))
        cmdExec(rest)
    else if (std.mem.eql(u8, cmd, "bench"))
        cmdBench(gpa, io, out, rest)
    else if (std.mem.eql(u8, cmd, "run"))
        cmdRun(gpa, io, out, rest)
    else if (std.mem.eql(u8, cmd, "dump"))
        cmdDump(gpa, io, out, rest)
    else if (std.mem.eql(u8, cmd, "fuzz"))
        cmdFuzz(gpa, io, out, rest)
    else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) blk: {
        out.print("obsidian {s}\n", .{version}) catch {};
        break :blk {};
    } else blk: {
        printUsage();
        break :blk {};
    };
    result catch |e| {
        out.flush() catch {};
        switch (e) {
            error.Reported => {},
            else => std.debug.print("error: {t}\n", .{e}),
        }
        std.process.exit(1);
    };
}

fn printUsage() void {
    std.debug.print(
        \\Obsidian {s}: Dual-Target (x86_64 / AArch64) Micro-JIT Engine
        \\Usage:
        \\  obsidian exec [add|sub|mul] [a] [b]
        \\  obsidian run <file.oir> [args...] [--no-opt] [--regs N] [--interp] [--check]
        \\  obsidian dump <file.oir> [--target x86_64|aarch64] [--no-opt] [--regs N]
        \\  obsidian fuzz [--seed S] [--count N] [--json]
        \\  obsidian bench [--json]
        \\  obsidian version
        \\  obsidian --help
        \\
    , .{version});
}

fn report(comptime fmt: []const u8, args: anytype) error{Reported} {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return error.Reported;
}

const CommonOpts = struct {
    file: ?[]const u8 = null,
    positional: std.ArrayList([]const u8) = .empty,
    optimize: bool = true,
    max_regs: ?usize = null,
    target: ?compiler.Arch = null,
    interp: bool = false,
    check: bool = false,
    json: bool = false,
    seed: u64 = 1,
    count: u64 = 1000,
};

fn parseOpts(gpa: std.mem.Allocator, args: []const [:0]const u8) !CommonOpts {
    var o: CommonOpts = .{};
    errdefer o.positional.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.startsWith(u8, a, "--")) {
            const needs_value = std.mem.eql(u8, a, "--regs") or std.mem.eql(u8, a, "--target") or
                std.mem.eql(u8, a, "--seed") or std.mem.eql(u8, a, "--count");
            var value: []const u8 = "";
            if (needs_value) {
                i += 1;
                if (i >= args.len) return report("{s} needs a value", .{a});
                value = args[i];
            }
            if (std.mem.eql(u8, a, "--no-opt")) {
                o.optimize = false;
            } else if (std.mem.eql(u8, a, "--interp")) {
                o.interp = true;
            } else if (std.mem.eql(u8, a, "--check")) {
                o.check = true;
            } else if (std.mem.eql(u8, a, "--json")) {
                o.json = true;
            } else if (std.mem.eql(u8, a, "--regs")) {
                o.max_regs = std.fmt.parseInt(usize, value, 10) catch return report("invalid --regs value '{s}'", .{value});
            } else if (std.mem.eql(u8, a, "--target")) {
                o.target = compiler.Arch.parse(value) orelse return report("unknown target '{s}' (use x86_64 or aarch64)", .{value});
            } else if (std.mem.eql(u8, a, "--seed")) {
                o.seed = std.fmt.parseInt(u64, value, 0) catch return report("invalid --seed value '{s}'", .{value});
            } else if (std.mem.eql(u8, a, "--count")) {
                o.count = std.fmt.parseInt(u64, value, 10) catch return report("invalid --count value '{s}'", .{value});
            } else {
                return report("unknown option '{s}'", .{a});
            }
        } else if (o.file == null) {
            o.file = a;
        } else {
            try o.positional.append(gpa, a);
        }
    }
    return o;
}

fn loadProgram(gpa: std.mem.Allocator, io: std.Io, path: []const u8, source_out: *[]u8) !parse.Parsed {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e|
        return report("cannot read '{s}': {t}", .{ path, e });
    source_out.* = source;
    var diag: parse.Diagnostic = .{};
    return parse.parse(gpa, source, &compiler.builtin_hosts, &diag) catch |e| switch (e) {
        error.SyntaxError => {
            gpa.free(source);
            if (diag.line != 0) {
                std.debug.print("{s}:{d}: error: {s}", .{ path, diag.line, diag.message });
            } else {
                std.debug.print("{s}: error: {s}", .{ path, diag.message });
            }
            if (diag.name.len != 0) std.debug.print(" '{s}'", .{diag.name});
            std.debug.print("\n", .{});
            return error.Reported;
        },
        else => {
            gpa.free(source);
            return e;
        },
    };
}

fn cmdRun(gpa: std.mem.Allocator, io: std.Io, out: *Writer, args: []const [:0]const u8) !void {
    var o = try parseOpts(gpa, args);
    defer o.positional.deinit(gpa);
    const path = o.file orelse return report("run needs a program file", .{});
    var source: []u8 = &.{};
    var p = try loadProgram(gpa, io, path, &source);
    defer gpa.free(source);
    defer p.deinit(gpa);

    if (o.positional.items.len != p.func.num_params)
        return report("'{s}' takes {d} argument(s), got {d}", .{ p.name, p.func.num_params, o.positional.items.len });
    var values: [ir.max_params]i64 = undefined;
    for (o.positional.items, 0..) |s, i| {
        values[i] = std.fmt.parseInt(i64, s, 0) catch return report("invalid integer argument '{s}'", .{s});
    }
    const in = values[0..p.func.num_params];

    const fuel: u64 = 1_000_000_000;
    if (o.interp) {
        const r = interp.run(gpa, &p.func, in, fuel) catch |e| return report("interpreter: {t}", .{e});
        try out.print("{d}\n", .{r.value});
        return;
    }
    var jf = compiler.jit(gpa, &p.func, .{ .optimize = o.optimize, .max_regs = o.max_regs }) catch |e|
        return report("JIT compilation failed: {t}", .{e});
    defer jf.deinit();
    const value = try jf.call(in);
    try out.print("{d}\n", .{value});
    if (o.check) {
        const r = interp.run(gpa, &p.func, in, fuel) catch |e| return report("interpreter: {t}", .{e});
        if (r.value != value) return report("native result {d} differs from interpreter result {d}", .{ value, r.value });
        try out.print("check: native result matches the interpreter ({d} IR steps)\n", .{r.steps});
    }
}

fn locName(buf: []u8, arch: compiler.Arch, l: regalloc.Loc) []const u8 {
    return switch (l) {
        .none => "-",
        .stack => |s| std.fmt.bufPrint(buf, "[slot {d}]", .{s}) catch "?",
        .reg => |r| switch (arch) {
            .x86_64 => @tagName(@as(x86.Reg, @fromBackingInt(@intCast(@as(u4, @intCast(r)))))),
            .aarch64 => std.fmt.bufPrint(buf, "x{d}", .{r}) catch "?",
        },
    };
}

fn cmdDump(gpa: std.mem.Allocator, io: std.Io, out: *Writer, args: []const [:0]const u8) !void {
    var o = try parseOpts(gpa, args);
    defer o.positional.deinit(gpa);
    const path = o.file orelse return report("dump needs a program file", .{});
    const arch = o.target orelse compiler.Arch.native() orelse .x86_64;
    var source: []u8 = &.{};
    var p = try loadProgram(gpa, io, path, &source);
    defer gpa.free(source);
    defer p.deinit(gpa);

    var lst = listing.Listing.init(gpa);
    defer lst.deinit();
    var c = try compiler.compile(gpa, &p.func, .{ .arch = arch, .optimize = o.optimize, .max_regs = o.max_regs, .listing = &lst });
    defer c.deinit(gpa);

    try out.print("function {s}: {d} parameter(s), target {t}\n", .{ p.name, p.func.num_params, arch });
    const s = c.opt_stats;
    if (o.optimize) {
        try out.print("optimizer: {d} -> {d} IR instructions ({d} folded, {d} copies propagated, {d} branches folded, {d} unreachable, {d} jumps/labels, {d} dead)\n", .{
            p.func.insts.items.len, c.func.insts.items.len, s.folded,        s.copies_propagated,
            s.branches_folded,      s.unreachable_removed,  s.jumps_removed, s.dead_removed,
        });
    } else {
        try out.print("optimizer: disabled ({d} IR instructions)\n", .{c.func.insts.items.len});
    }

    // Recompute the allocation for display (the compiled one is internal).
    var alloc = try regalloc.allocate(gpa, &c.func, arch.registerSet(), .{ .max_regs = o.max_regs });
    defer alloc.deinit(gpa);
    try out.print("registers: {d} live intervals, {d} spilled, {d} stack slots, {d} callee-saved\n", .{
        c.num_intervals, c.num_spilled, c.num_slots, c.callee_saved_used,
    });
    for (alloc.intervals) |iv| {
        var buf: [32]u8 = undefined;
        const name = if (iv.vreg < p.vreg_names.len) p.vreg_names[iv.vreg] else "";
        try out.print("  %{d:<4} {s:<12} {s:<10} live {d}..{d}{s}\n", .{
            iv.vreg,                                  if (name.len == 0) "(temp)" else name,
            locName(&buf, arch, alloc.locs[iv.vreg]), iv.start / 2,
            iv.end / 2,                               if (iv.crosses_call) "  (across call)" else "",
        });
    }
    try out.print("code: {d} bytes\n", .{c.code.len});
    try lst.render(c.code, out);
}

fn cmdFuzz(gpa: std.mem.Allocator, io: std.Io, out: *Writer, args: []const [:0]const u8) !void {
    var o = try parseOpts(gpa, args);
    defer o.positional.deinit(gpa);
    if (o.file != null) return report("fuzz takes no positional arguments", .{});
    var err_buf: [4096]u8 = undefined;
    var err_file = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const r = try fuzz.differential(gpa, o.seed, o.count, &err_file.interface);
    err_file.interface.flush() catch {};
    if (o.json) {
        try out.print("{{\"seed\":{d},\"programs\":{d},\"executions\":{d},\"native_runs\":{d},\"cross_compiles\":{d},\"mismatches\":{d}}}\n", .{
            o.seed, r.programs, r.executions, r.native_runs, r.cross_compiles, r.mismatches,
        });
    } else {
        try out.print("fuzz: {d} programs, {d} input vectors, {d} native runs, {d} cross-target compiles, {d} mismatches\n", .{
            r.programs, r.executions, r.native_runs, r.cross_compiles, r.mismatches,
        });
    }
    if (r.mismatches != 0) return error.Reported;
}

fn cmdExec(args: []const [:0]const u8) !void {
    const op: []const u8 = if (args.len > 0) args[0] else "add";
    const a = if (args.len > 1) std.fmt.parseInt(i64, args[1], 10) catch 40 else 40;
    const b = if (args.len > 2) std.fmt.parseInt(i64, args[2], 10) catch 2 else 2;

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
}

fn elapsedNs(io: std.Io, t0: std.Io.Clock.Timestamp) u64 {
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    return @intCast(@max(0, t0.durationTo(t1).raw.nanoseconds));
}

fn cmdBench(gpa: std.mem.Allocator, io: std.Io, out: *Writer, args: []const [:0]const u8) !void {
    var o = try parseOpts(gpa, args);
    defer o.positional.deinit(gpa);
    if (o.file != null) return report("bench takes no positional arguments", .{});
    if (compiler.Arch.native() == null) return report("no native JIT back end for {t}", .{builtin.cpu.arch});

    // 1. Call overhead of a hand-assembled add function.
    var buf = emitter.Buffer.init();
    if (builtin.cpu.arch == .x86_64) {
        var asm_x86 = emitter.X86Assembler.init(&buf);
        asm_x86.movRaxRdi();
        asm_x86.addRaxRsi();
        asm_x86.ret();
    } else {
        var asm_arm = emitter.Arm64Assembler.init(&buf);
        asm_arm.addX0X0X1();
        asm_arm.ret();
    }
    var engine = try jit.JitEngine.init();
    defer engine.deinit();
    try engine.loadCode(buf.code[0..buf.len]);
    const fun = engine.getFunction().?;
    const calls: u64 = 1_000_000;
    var sum: i64 = 0;
    var t0 = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..calls) |i| sum +%= fun(@intCast(i), 1);
    const call_ns = elapsedNs(io, t0);
    std.mem.doNotOptimizeAway(sum);

    // 2. Full pipeline: parse result -> optimize -> allocate -> encode -> load.
    var diag: parse.Diagnostic = .{};
    var p = try parse.parse(gpa, sum_squares_src, &compiler.builtin_hosts, &diag);
    defer p.deinit(gpa);
    const compiles: u64 = 2000;
    var code_bytes: usize = 0;
    t0 = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..compiles) |_| {
        var c = try compiler.compile(gpa, &p.func, .{ .arch = compiler.Arch.native().? });
        code_bytes = c.code.len;
        var jf = try compiler.JitFunction.fromCode(c.code, 1);
        jf.deinit();
        c.deinit(gpa);
    }
    const compile_ns = elapsedNs(io, t0);

    // 3. Loop throughput: JIT-compiled code versus the reference interpreter.
    var jf = try compiler.jit(gpa, &p.func, .{});
    defer jf.deinit();
    const jit_n: i64 = 10_000_000;
    t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const jit_result = try jf.call(&.{jit_n});
    const jit_ns = elapsedNs(io, t0);
    std.mem.doNotOptimizeAway(jit_result);
    const interp_n: i64 = 200_000;
    t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const ir_result = try interp.run(gpa, &p.func, &.{interp_n}, 1 << 40);
    const interp_ns = elapsedNs(io, t0);
    std.mem.doNotOptimizeAway(ir_result.value);
    const check = try jf.call(&.{interp_n});
    if (check != ir_result.value) return report("benchmark self-check failed: {d} != {d}", .{ check, ir_result.value });

    const f = struct {
        fn div(a: u64, b: u64) f64 {
            return @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(@max(b, 1)));
        }
    }.div;
    const call_overhead = f(call_ns, calls);
    const compile_us = f(compile_ns, compiles) / 1000.0;
    const jit_iter = f(jit_ns, @intCast(jit_n));
    const interp_iter = f(interp_ns, @intCast(interp_n));
    const speedup = interp_iter / @max(jit_iter, 1e-9);

    if (o.json) {
        try out.print("{{\"version\":\"{s}\",\"arch\":\"{t}\",\"os\":\"{t}\",\"wx_strategy\":\"{t}\",\"mode\":\"{t}\"," ++
            "\"call_iterations\":{d},\"call_overhead_ns\":{d:.3}," ++
            "\"compile_iterations\":{d},\"compile_us\":{d:.3},\"code_bytes\":{d}," ++
            "\"jit_loop_iterations\":{d},\"jit_ns_per_iter\":{d:.3}," ++
            "\"interp_loop_iterations\":{d},\"interp_ns_per_iter\":{d:.3},\"speedup\":{d:.1}}}\n", .{
            version, builtin.cpu.arch, builtin.os.tag, exec_mem.strategy, builtin.mode,
            calls,   call_overhead,    compiles,       compile_us,        code_bytes,
            jit_n,   jit_iter,         interp_n,       interp_iter,       speedup,
        });
    } else {
        try out.print("Obsidian {s} on {t}-{t} ({t} build, W^X via {t})\n", .{ version, builtin.cpu.arch, builtin.os.tag, builtin.mode, exec_mem.strategy });
        try out.print("  call overhead:     {d:.2} ns/call over {d} calls\n", .{ call_overhead, calls });
        try out.print("  compile + load:    {d:.2} us per function ({d} bytes, {d} runs)\n", .{ compile_us, code_bytes, compiles });
        try out.print("  JIT loop:          {d:.3} ns/iteration (sum_squares, n = {d})\n", .{ jit_iter, jit_n });
        try out.print("  interpreter loop:  {d:.3} ns/iteration (n = {d})\n", .{ interp_iter, interp_n });
        try out.print("  JIT speedup:       {d:.1}x\n", .{speedup});
    }
}

test {
    _ = @import("emitter.zig");
    _ = @import("jit.zig");
    _ = @import("ir.zig");
    _ = @import("analysis.zig");
    _ = @import("interp.zig");
    _ = @import("opt.zig");
    _ = @import("regalloc.zig");
    _ = @import("moves.zig");
    _ = @import("x86.zig");
    _ = @import("a64.zig");
    _ = @import("exec_mem.zig");
    _ = @import("compiler.zig");
    _ = @import("parse.zig");
    _ = @import("listing.zig");
    _ = @import("fuzz.zig");
}
