//! Random program generation and differential testing.
//!
//! Programs are generated structurally (straight-line code, if/else
//! diamonds, early returns, counted loops with bounded trip counts and calls
//! to host functions of every arity), so they always terminate and never read
//! an undefined register. Each program is executed by the reference
//! interpreter, by the interpreter after optimization, and as native code
//! under several optimizer and register-pressure settings; all results must
//! agree. Code for the non-native target is generated as well so that both
//! back ends see every program.

const std = @import("std");
const ir = @import("ir.zig");
const analysis = @import("analysis.zig");
const interp = @import("interp.zig");
const opt = @import("opt.zig");
const compiler = @import("compiler.zig");
const exec_mem = @import("exec_mem.zig");

fn h0() callconv(.c) i64 {
    return 0x5DEECE66D;
}
fn h1(a: i64) callconv(.c) i64 {
    return a *% 3 +% 1;
}
fn h2(a: i64, b: i64) callconv(.c) i64 {
    return a ^ (b *% 31);
}
fn h3(a: i64, b: i64, c: i64) callconv(.c) i64 {
    return (a -% b) *% 7 +% c;
}
fn h4(a: i64, b: i64, c: i64, d: i64) callconv(.c) i64 {
    return a +% b *% 3 +% c *% 5 +% d *% 7;
}
fn h5(a: i64, b: i64, c: i64, d: i64, e: i64) callconv(.c) i64 {
    return (a ^ b) +% (c ^ d) *% e;
}
fn h6(a: i64, b: i64, c: i64, d: i64, e: i64, g: i64) callconv(.c) i64 {
    // Order-sensitive so that any argument mix-up changes the result.
    return a +% 2 *% b +% 4 *% c +% 8 *% d +% 16 *% e +% 32 *% g;
}

pub const test_hosts = [_]ir.HostFn{
    ir.HostFn.init("h0", h0),
    ir.HostFn.init("h1", h1),
    ir.HostFn.init("h2", h2),
    ir.HostFn.init("h3", h3),
    ir.HostFn.init("h4", h4),
    ir.HostFn.init("h5", h5),
    ir.HostFn.init("h6", h6),
};

pub const GenConfig = struct {
    num_vars: u32 = 10,
    max_stmts: u32 = 20,
    max_depth: u32 = 3,
    calls: bool = true,
};

const Gen = struct {
    gpa: std.mem.Allocator,
    rnd: std.Random,
    f: ir.Function,
    pool: std.ArrayList(ir.VReg) = .empty,
    cfg: GenConfig,
    loop_depth: u32 = 0,

    fn pick(g: *Gen) ir.VReg {
        return g.pool.items[g.rnd.uintLessThan(usize, g.pool.items.len)];
    }

    fn constant(g: *Gen) i64 {
        const interesting = [_]i64{ 0, 1, -1, 2, 3, 7, 63, 64, 65, 255, -256, 1 << 31, -(1 << 31), std.math.maxInt(i64), std.math.minInt(i64), 0x1234_5678_9ABC_DEF0 };
        return switch (g.rnd.uintLessThan(u8, 4)) {
            0 => interesting[g.rnd.uintLessThan(usize, interesting.len)],
            1 => g.rnd.int(i64),
            else => g.rnd.intRangeAtMost(i64, -100, 100),
        };
    }

    /// An operand: usually a pool variable, sometimes a fresh constant.
    fn operand(g: *Gen) !ir.VReg {
        if (g.rnd.uintLessThan(u8, 4) == 0) return g.f.iconst(g.gpa, g.constant());
        return g.pick();
    }

    fn emit(g: *Gen, inst: ir.Inst) !void {
        try g.f.append(g.gpa, inst);
    }

    fn cond(g: *Gen) ir.Cond {
        return std.enums.values(ir.Cond)[g.rnd.uintLessThan(usize, std.enums.values(ir.Cond).len)];
    }

    fn assign(g: *Gen) !void {
        const d = g.pick();
        switch (g.rnd.uintLessThan(u8, 10)) {
            0 => try g.emit(.{ .iconst = .{ .dst = d, .value = g.constant() } }),
            1 => try g.emit(.{ .mov = .{ .dst = d, .src = g.pick() } }),
            2 => try g.emit(.{ .cmp = .{ .cond = g.cond(), .dst = d, .lhs = try g.operand(), .rhs = try g.operand() } }),
            3 => if (g.cfg.calls) {
                const callee = g.rnd.uintLessThan(u32, test_hosts.len);
                var args: [ir.max_call_args]ir.VReg = @splat(0);
                const argc = test_hosts[callee].arity;
                for (args[0..argc]) |*a| a.* = try g.operand();
                try g.emit(.{ .call = .{ .dst = d, .callee = callee, .argc = argc, .args = args } });
            } else try g.binary(d),
            else => try g.binary(d),
        }
    }

    fn binary(g: *Gen, d: ir.VReg) !void {
        const ops = std.enums.values(ir.BinOp);
        const op = ops[g.rnd.uintLessThan(usize, ops.len)];
        try g.emit(.{ .bin = .{ .op = op, .dst = d, .lhs = try g.operand(), .rhs = try g.operand() } });
    }

    fn block(g: *Gen, depth: u32, max: u32) anyerror!void {
        const n = g.rnd.intRangeAtMost(u32, 1, max);
        for (0..n) |_| try g.stmt(depth);
    }

    fn stmt(g: *Gen, depth: u32) anyerror!void {
        const choice = g.rnd.uintLessThan(u8, 12);
        if (depth >= g.cfg.max_depth or choice < 7) return g.assign();
        switch (choice) {
            7, 8 => {
                // if (cond) { ... } else { ... }
                const else_l = g.f.newLabel();
                const end_l = g.f.newLabel();
                try g.emit(.{ .br = .{ .cond = g.cond(), .lhs = try g.operand(), .rhs = try g.operand(), .target = else_l } });
                try g.block(depth + 1, 4);
                if (g.rnd.uintLessThan(u8, 5) == 0) try g.emit(.{ .ret = g.pick() });
                try g.emit(.{ .jmp = end_l });
                try g.emit(.{ .label = else_l });
                try g.block(depth + 1, 4);
                try g.emit(.{ .label = end_l });
            },
            9 => {
                // if (cond) { ... }
                const skip = g.f.newLabel();
                try g.emit(.{ .br = .{ .cond = g.cond(), .lhs = try g.operand(), .rhs = try g.operand(), .target = skip } });
                try g.block(depth + 1, 4);
                try g.emit(.{ .label = skip });
            },
            else => {
                if (g.loop_depth >= 2) return g.assign();
                // Counted loop; the counter, bound and step are not in the
                // pool, so the body cannot change the trip count (<= 7).
                const c = try g.f.iconst(g.gpa, 0);
                const one = try g.f.iconst(g.gpa, 1);
                const mask = try g.f.iconst(g.gpa, 7);
                const n = g.f.newVReg();
                try g.emit(.{ .bin = .{ .op = .@"and", .dst = n, .lhs = g.pick(), .rhs = mask } });
                const head = g.f.newLabel();
                const exit = g.f.newLabel();
                try g.emit(.{ .label = head });
                try g.emit(.{ .br = .{ .cond = .ge, .lhs = c, .rhs = n, .target = exit } });
                g.loop_depth += 1;
                try g.block(depth + 1, 5);
                g.loop_depth -= 1;
                try g.emit(.{ .bin = .{ .op = .add, .dst = c, .lhs = c, .rhs = one } });
                try g.emit(.{ .jmp = head });
                try g.emit(.{ .label = exit });
            },
        }
    }
};

/// Generates a random terminating program with up to six parameters.
pub fn randomProgram(gpa: std.mem.Allocator, rnd: std.Random, cfg: GenConfig) !ir.Function {
    const np = rnd.uintAtMost(u8, ir.max_params);
    var g: Gen = .{ .gpa = gpa, .rnd = rnd, .f = ir.Function.init(np), .cfg = cfg };
    errdefer g.f.deinit(gpa);
    defer g.pool.deinit(gpa);
    g.f.hosts = &test_hosts;
    for (0..np) |p| try g.pool.append(gpa, @intCast(p));
    for (0..cfg.num_vars) |_| {
        const v = g.f.newVReg();
        if (np > 0 and rnd.boolean()) {
            const k = try g.f.iconst(gpa, g.constant());
            try g.emit(.{ .bin = .{ .op = .add, .dst = v, .lhs = g.pick(), .rhs = k } });
        } else {
            try g.emit(.{ .iconst = .{ .dst = v, .value = g.constant() } });
        }
        try g.pool.append(gpa, v);
    }
    try g.block(0, cfg.max_stmts);
    // Combine every variable so most of them stay live until the end.
    var acc = g.pool.items[0];
    for (g.pool.items[1..]) |v| {
        const t = g.f.newVReg();
        const op: ir.BinOp = if (rnd.boolean()) .xor else .add;
        try g.emit(.{ .bin = .{ .op = op, .dst = t, .lhs = acc, .rhs = v } });
        acc = t;
    }
    try g.emit(.{ .ret = acc });
    return g.f;
}

pub const Report = struct {
    programs: u64 = 0,
    executions: u64 = 0,
    native_runs: u64 = 0,
    cross_compiles: u64 = 0,
    mismatches: u64 = 0,
};

const variants = [_]compiler.Options{
    .{ .optimize = true },
    .{ .optimize = false },
    .{ .optimize = true, .max_regs = 0 },
    .{ .optimize = false, .max_regs = 1 },
    .{ .optimize = true, .max_regs = 3 },
    .{ .optimize = false, .max_regs = 5 },
};

/// Runs `count` random programs starting at `seed`. Mismatches are printed
/// to `log` (when given) together with the offending program.
pub fn differential(backing: std.mem.Allocator, seed: u64, count: u64, log: ?*std.Io.Writer) !Report {
    var report: Report = .{};
    // One arena per program keeps allocation cheap; it is reset each round.
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const gpa = arena.allocator();
    const native = compiler.Arch.native();
    const can_run = native != null and exec_mem.supported;
    for (0..count) |k| {
        _ = arena.reset(.retain_capacity);
        const program_seed = seed +% k;
        var prng = std.Random.DefaultPrng.init(program_seed);
        const rnd = prng.random();
        var f = try randomProgram(gpa, rnd, .{});
        defer f.deinit(gpa);
        try analysis.verify(gpa, &f);
        report.programs += 1;

        var optimized = try f.clone(gpa);
        defer optimized.deinit(gpa);
        _ = try opt.optimize(gpa, &optimized);

        var jits: [variants.len]?compiler.JitFunction = @splat(null);
        defer for (&jits) |*j| if (j.*) |*x| x.deinit();
        for (variants, 0..) |v, vi| {
            for ([_]compiler.Arch{ .x86_64, .aarch64 }) |arch| {
                var o = v;
                o.arch = arch;
                var c = try compiler.compile(gpa, &f, o);
                defer c.deinit(gpa);
                if (can_run and arch == native.?) {
                    jits[vi] = try compiler.JitFunction.fromCode(c.code, f.num_params);
                } else {
                    report.cross_compiles += 1;
                }
            }
        }

        for (0..4) |_| {
            var args: [ir.max_params]i64 = undefined;
            for (args[0..f.num_params]) |*a| a.* = switch (rnd.uintLessThan(u8, 3)) {
                0 => rnd.int(i64),
                else => rnd.intRangeAtMost(i64, -50, 50),
            };
            const in = args[0..f.num_params];
            const want = (try interp.run(gpa, &f, in, 1 << 24)).value;
            const got_opt = (try interp.run(gpa, &optimized, in, 1 << 24)).value;
            report.executions += 1;
            var bad = got_opt != want;
            if (bad) try mismatch(log, &f, program_seed, "optimized interpreter", want, got_opt);
            for (jits, 0..) |j, vi| {
                const jf = j orelse continue;
                const got = try jf.call(in);
                report.native_runs += 1;
                if (got != want) {
                    bad = true;
                    try mismatch(log, &f, program_seed, @tagName(variantName(vi)), want, got);
                }
            }
            if (bad) report.mismatches += 1;
        }
    }
    return report;
}

const VariantName = enum { opt_all_regs, noopt_all_regs, opt_0_regs, noopt_1_reg, opt_3_regs, noopt_5_regs };

fn variantName(i: usize) VariantName {
    return @fromBackingInt(@intCast(i));
}

fn mismatch(log: ?*std.Io.Writer, f: *const ir.Function, seed: u64, what: []const u8, want: i64, got: i64) !void {
    const w = log orelse return;
    try w.print("mismatch (seed {d}, {s}): expected {d}, got {d}\n", .{ seed, what, want, got });
    try f.write(w);
}

test "random programs verify and terminate" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(1);
    for (0..200) |_| {
        var f = try randomProgram(gpa, prng.random(), .{});
        defer f.deinit(gpa);
        try analysis.verify(gpa, &f);
        var args: [ir.max_params]i64 = @splat(3);
        _ = try interp.run(gpa, &f, args[0..f.num_params], 1 << 24);
    }
}

test "differential: interpreter, optimizer and native code agree" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(std.testing.io, &buf);
    const report = try differential(gpa, 0xC0FFEE, 300, &stderr.interface);
    stderr.interface.flush() catch {};
    try std.testing.expectEqual(@as(u64, 0), report.mismatches);
    try std.testing.expectEqual(@as(u64, 300), report.programs);
    if (compiler.Arch.native() != null and exec_mem.supported) {
        try std.testing.expect(report.native_runs == report.executions * variants.len);
    }
}

test "allocations verify under every register limit on both targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var prng = std.Random.DefaultPrng.init(77);
    for (0..120) |_| {
        _ = arena.reset(.retain_capacity);
        var f = try randomProgram(gpa, prng.random(), .{ .num_vars = 16 });
        for ([_]compiler.Arch{ .x86_64, .aarch64 }) |arch| {
            var limit: usize = 0;
            while (limit <= 12) : (limit += 1) {
                // compile() runs regalloc.verifyAllocation on every result.
                var c = try compiler.compile(gpa, &f, .{ .arch = arch, .max_regs = limit, .optimize = limit % 2 == 0 });
                c.deinit(gpa);
            }
        }
        f.deinit(gpa);
    }
}
