//! Compilation pipeline: verify, optimize, allocate registers, generate
//! machine code for either target, and load native code into W^X memory.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const analysis = @import("analysis.zig");
const opt = @import("opt.zig");
const regalloc = @import("regalloc.zig");
const x86 = @import("x86.zig");
const a64 = @import("a64.zig");
const exec_mem = @import("exec_mem.zig");
const Listing = @import("listing.zig").Listing;

pub const Arch = enum {
    x86_64,
    aarch64,

    /// The architecture this binary runs on, if the JIT can execute there.
    pub fn native() ?Arch {
        return switch (builtin.cpu.arch) {
            .x86_64 => if (builtin.os.tag == .windows) null else .x86_64,
            .aarch64 => .aarch64,
            else => null,
        };
    }

    pub fn registerSet(a: Arch) regalloc.RegisterSet {
        return switch (a) {
            .x86_64 => x86.register_set,
            .aarch64 => a64.register_set,
        };
    }

    pub fn parse(name: []const u8) ?Arch {
        if (std.mem.eql(u8, name, "x86_64") or std.mem.eql(u8, name, "x64")) return .x86_64;
        if (std.mem.eql(u8, name, "aarch64") or std.mem.eql(u8, name, "arm64")) return .aarch64;
        return null;
    }
};

pub const Options = struct {
    arch: Arch = .x86_64,
    optimize: bool = true,
    /// Restricts the register pool (forces spilling); `null` uses all.
    max_regs: ?usize = null,
    listing: ?*Listing = null,
};

pub const Compiled = struct {
    arch: Arch,
    code: []u8,
    /// The IR that was lowered (after optimization when enabled).
    func: ir.Function,
    opt_stats: opt.Stats,
    num_intervals: usize,
    num_slots: u32,
    num_spilled: u32,
    callee_saved_used: usize,

    pub fn deinit(self: *Compiled, gpa: std.mem.Allocator) void {
        gpa.free(self.code);
        self.func.deinit(gpa);
        self.* = undefined;
    }
};

pub fn compile(gpa: std.mem.Allocator, f: *const ir.Function, opts: Options) !Compiled {
    var work = try f.clone(gpa);
    errdefer work.deinit(gpa);
    try analysis.verify(gpa, &work);
    const stats: opt.Stats = if (opts.optimize) try opt.optimize(gpa, &work) else .{};
    var alloc = try regalloc.allocate(gpa, &work, opts.arch.registerSet(), .{ .max_regs = opts.max_regs });
    defer alloc.deinit(gpa);
    try regalloc.verifyAllocation(&work, &alloc, opts.arch.registerSet());
    const code = switch (opts.arch) {
        .x86_64 => try x86.generate(gpa, &work, &alloc, opts.listing),
        .aarch64 => try a64.generate(gpa, &work, &alloc, opts.listing),
    };
    return .{
        .arch = opts.arch,
        .code = code,
        .func = work,
        .opt_stats = stats,
        .num_intervals = alloc.intervals.len,
        .num_slots = alloc.num_slots,
        .num_spilled = alloc.num_spilled,
        .callee_saved_used = alloc.callee_saved_used.len,
    };
}

/// A compiled function loaded into executable memory.
pub const JitFunction = struct {
    mem: exec_mem.ExecMemory,
    num_params: u8,

    pub fn fromCode(code: []const u8, num_params: u8) !JitFunction {
        return .{ .mem = try exec_mem.ExecMemory.create(code), .num_params = num_params };
    }

    pub fn call(self: *const JitFunction, args: []const i64) error{ArgumentCountMismatch}!i64 {
        if (args.len != self.num_params) return error.ArgumentCountMismatch;
        return ir.callAddr(self.mem.entryAddress(), args);
    }

    pub fn deinit(self: *JitFunction) void {
        self.mem.deinit();
        self.* = undefined;
    }
};

/// Compiles `f` for the host architecture and loads it.
pub fn jit(gpa: std.mem.Allocator, f: *const ir.Function, opts: Options) !JitFunction {
    const arch = Arch.native() orelse return error.UnsupportedArchitecture;
    var o = opts;
    o.arch = arch;
    var c = try compile(gpa, f, o);
    defer c.deinit(gpa);
    return JitFunction.fromCode(c.code, f.num_params);
}

// Host functions available to programs by name.
fn hostAbs(x: i64) callconv(.c) i64 {
    return if (x < 0) 0 -% x else x;
}
fn hostMin(a: i64, b: i64) callconv(.c) i64 {
    return @min(a, b);
}
fn hostMax(a: i64, b: i64) callconv(.c) i64 {
    return @max(a, b);
}
fn hostGcd(a: i64, b: i64) callconv(.c) i64 {
    var x: u64 = @abs(a);
    var y: u64 = @abs(b);
    while (y != 0) {
        const t = x % y;
        x = y;
        y = t;
    }
    return @bitCast(x);
}
fn hostClamp(x: i64, lo: i64, hi: i64) callconv(.c) i64 {
    return @min(@max(x, lo), hi);
}

pub const builtin_hosts = [_]ir.HostFn{
    ir.HostFn.init("abs", hostAbs),
    ir.HostFn.init("min", hostMin),
    ir.HostFn.init("max", hostMax),
    ir.HostFn.init("gcd", hostGcd),
    ir.HostFn.init("clamp", hostClamp),
};

const interp = @import("interp.zig");

fn buildSumTo(gpa: std.mem.Allocator) !ir.Function {
    // fn(n): s = 0; i = 0; while (i < n) { s += i * i; i += 1 } return max(s, 1)
    var f = ir.Function.init(1);
    f.hosts = &builtin_hosts;
    const s = try f.iconst(gpa, 0);
    const i = try f.iconst(gpa, 0);
    const one = try f.iconst(gpa, 1);
    const head = f.newLabel();
    const exit = f.newLabel();
    try f.append(gpa, .{ .label = head });
    try f.append(gpa, .{ .br = .{ .cond = .ge, .lhs = i, .rhs = 0, .target = exit } });
    const sq = try f.binop(gpa, .mul, i, i);
    try f.append(gpa, .{ .bin = .{ .op = .add, .dst = s, .lhs = s, .rhs = sq } });
    try f.append(gpa, .{ .bin = .{ .op = .add, .dst = i, .lhs = i, .rhs = one } });
    try f.append(gpa, .{ .jmp = head });
    try f.append(gpa, .{ .label = exit });
    const r = f.newVReg();
    var args: [ir.max_call_args]ir.VReg = @splat(0);
    args[0] = s;
    args[1] = one;
    try f.append(gpa, .{ .call = .{ .dst = r, .callee = 2, .argc = 2, .args = args } });
    try f.append(gpa, .{ .ret = r });
    return f;
}

test "pipeline compiles a loop for both targets and runs it natively" {
    const gpa = std.testing.allocator;
    var f = try buildSumTo(gpa);
    defer f.deinit(gpa);
    for ([_]Arch{ .x86_64, .aarch64 }) |arch| {
        for ([_]?usize{ null, 0, 1, 2 }) |limit| {
            var c = try compile(gpa, &f, .{ .arch = arch, .max_regs = limit });
            defer c.deinit(gpa);
            try std.testing.expect(c.code.len > 0);
            if (limit != null and limit.? == 0) try std.testing.expect(c.num_spilled > 0);
            if (Arch.native() == arch and exec_mem.supported) {
                var j = try JitFunction.fromCode(c.code, 1);
                defer j.deinit();
                for ([_]i64{ 0, 1, 2, 10, 1000 }) |n| {
                    const want = (try interp.run(gpa, &f, &.{n}, 1 << 20)).value;
                    try std.testing.expectEqual(want, try j.call(&.{n}));
                }
                try std.testing.expectError(error.ArgumentCountMismatch, j.call(&.{}));
            }
        }
    }
}

test "builtin host functions" {
    try std.testing.expectEqual(@as(i64, 5), hostAbs(-5));
    try std.testing.expectEqual(std.math.minInt(i64), hostAbs(std.math.minInt(i64)));
    try std.testing.expectEqual(@as(i64, 6), hostGcd(-12, 18));
    try std.testing.expectEqual(@as(i64, 0), hostGcd(0, 0));
    try std.testing.expectEqual(@as(i64, 3), hostClamp(9, -3, 3));
}

test "listing records every machine instruction" {
    const gpa = std.testing.allocator;
    var f = try buildSumTo(gpa);
    defer f.deinit(gpa);
    for ([_]Arch{ .x86_64, .aarch64 }) |arch| {
        var listing = Listing.init(gpa);
        defer listing.deinit();
        var c = try compile(gpa, &f, .{ .arch = arch, .listing = &listing });
        defer c.deinit(gpa);
        var covered: usize = 0;
        for (listing.lines.items) |line| {
            if (line.kind != .insn) continue;
            try std.testing.expectEqual(covered, line.offset);
            covered += line.len;
        }
        try std.testing.expectEqual(c.code.len, covered);
    }
}
