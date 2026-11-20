//! Reference interpreter for the IR. It defines the semantics that the
//! optimizer and both native back ends are tested against.

const std = @import("std");
const ir = @import("ir.zig");

pub const Error = error{
    FuelExhausted,
    UndefinedRegister,
    ArgumentCountMismatch,
    InvalidProgram,
    OutOfMemory,
};

pub const Result = struct {
    value: i64,
    /// Number of IR instructions executed.
    steps: u64,
};

/// Runs `f` on `args`. Execution stops with `error.FuelExhausted` after
/// `fuel` instructions so that non-terminating programs cannot hang a caller.
pub fn run(gpa: std.mem.Allocator, f: *const ir.Function, args: []const i64, fuel: u64) Error!Result {
    if (args.len != f.num_params) return error.ArgumentCountMismatch;
    f.validate() catch return error.InvalidProgram;

    const regs = try gpa.alloc(i64, f.num_vregs);
    defer gpa.free(regs);
    var defined = try std.bit_set.Dynamic.initEmpty(gpa, f.num_vregs);
    defer defined.deinit(gpa);
    const label_pos = try gpa.alloc(u32, f.num_labels);
    defer gpa.free(label_pos);

    for (f.insts.items, 0..) |inst, i| {
        if (inst == .label) label_pos[inst.label] = @intCast(i);
    }
    for (args, 0..) |a, i| {
        regs[i] = a;
        defined.set(i);
    }

    const insts = f.insts.items;
    var pc: usize = 0;
    var steps: u64 = 0;
    while (true) {
        if (pc >= insts.len) return error.InvalidProgram;
        if (steps >= fuel) return error.FuelExhausted;
        steps += 1;
        const read = struct {
            fn get(r: []const i64, d: *const std.bit_set.Dynamic, v: ir.VReg) Error!i64 {
                if (!d.isSet(v)) return error.UndefinedRegister;
                return r[v];
            }
        }.get;
        switch (insts[pc]) {
            .iconst => |i| {
                regs[i.dst] = i.value;
                defined.set(i.dst);
            },
            .mov => |i| {
                regs[i.dst] = try read(regs, &defined, i.src);
                defined.set(i.dst);
            },
            .bin => |i| {
                const a = try read(regs, &defined, i.lhs);
                const b = try read(regs, &defined, i.rhs);
                regs[i.dst] = i.op.eval(a, b);
                defined.set(i.dst);
            },
            .cmp => |i| {
                const a = try read(regs, &defined, i.lhs);
                const b = try read(regs, &defined, i.rhs);
                regs[i.dst] = @intFromBool(i.cond.eval(a, b));
                defined.set(i.dst);
            },
            .call => |i| {
                var vals: [ir.max_call_args]i64 = undefined;
                for (i.args[0..i.argc], 0..) |a, k| vals[k] = try read(regs, &defined, a);
                regs[i.dst] = f.hosts[i.callee].invoke(vals[0..i.argc]);
                defined.set(i.dst);
            },
            .label => {},
            .jmp => |l| {
                pc = label_pos[l];
                continue;
            },
            .br => |b| {
                const x = try read(regs, &defined, b.lhs);
                const y = try read(regs, &defined, b.rhs);
                if (b.cond.eval(x, y)) {
                    pc = label_pos[b.target];
                    continue;
                }
            },
            .ret => |v| return .{ .value = try read(regs, &defined, v), .steps = steps },
        }
        pc += 1;
    }
}

fn hostTwice(x: i64) callconv(.c) i64 {
    return x *% 2;
}

test "interpreter runs a counted loop and calls a host" {
    const gpa = std.testing.allocator;
    const hosts = [_]ir.HostFn{ir.HostFn.init("twice", hostTwice)};
    var f = ir.Function.init(1);
    f.hosts = &hosts;
    defer f.deinit(gpa);
    // s = 0; i = 0; while (i < n) { s += i; i += 1 } return twice(s)
    const s = try f.iconst(gpa, 0);
    const i = try f.iconst(gpa, 0);
    const one = try f.iconst(gpa, 1);
    const head = f.newLabel();
    const exit = f.newLabel();
    try f.append(gpa, .{ .label = head });
    try f.append(gpa, .{ .br = .{ .cond = .ge, .lhs = i, .rhs = 0, .target = exit } });
    try f.append(gpa, .{ .bin = .{ .op = .add, .dst = s, .lhs = s, .rhs = i } });
    try f.append(gpa, .{ .bin = .{ .op = .add, .dst = i, .lhs = i, .rhs = one } });
    try f.append(gpa, .{ .jmp = head });
    try f.append(gpa, .{ .label = exit });
    const r = f.newVReg();
    var args: [ir.max_call_args]ir.VReg = @splat(0);
    args[0] = s;
    try f.append(gpa, .{ .call = .{ .dst = r, .callee = 0, .argc = 1, .args = args } });
    try f.append(gpa, .{ .ret = r });

    const res = try run(gpa, &f, &.{10}, 1000);
    try std.testing.expectEqual(@as(i64, 90), res.value);
    try std.testing.expectError(error.FuelExhausted, run(gpa, &f, &.{1_000_000}, 1000));
    try std.testing.expectError(error.ArgumentCountMismatch, run(gpa, &f, &.{}, 1000));
}
