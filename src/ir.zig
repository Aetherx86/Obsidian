//! A small register-based intermediate representation.
//!
//! Every value is a signed 64-bit integer held in a virtual register (`VReg`).
//! Virtual registers may be assigned more than once, which keeps loops easy to
//! express. Parameters arrive in virtual registers `0 .. num_params - 1`.
//! Control flow uses labels, unconditional jumps (`jmp`) and compare-and-branch
//! instructions (`br`) that fall through when the condition is false.
//!
//! Arithmetic wraps on overflow. Shift amounts are taken modulo 64, which
//! matches both the x86_64 (`shl r64, cl`) and AArch64 (`lslv`) hardware.

const std = @import("std");

pub const VReg = u32;
pub const Label = u32;

pub const max_params = 6;
pub const max_call_args = 6;
pub const max_vregs = 4096;
pub const max_labels = 4096;
pub const max_insts = 1 << 16;

pub const BinOp = enum {
    add,
    sub,
    mul,
    @"and",
    @"or",
    xor,
    shl,
    shr,
    sar,

    pub fn eval(op: BinOp, a: i64, b: i64) i64 {
        const ua: u64 = @bitCast(a);
        const sh: u6 = @intCast(b & 63);
        return switch (op) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
            .@"and" => a & b,
            .@"or" => a | b,
            .xor => a ^ b,
            .shl => @bitCast(ua << sh),
            .shr => @bitCast(ua >> sh),
            .sar => a >> sh,
        };
    }

    pub fn isCommutative(op: BinOp) bool {
        return switch (op) {
            .add, .mul, .@"and", .@"or", .xor => true,
            else => false,
        };
    }
};

pub const Cond = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    ult,
    ule,
    ugt,
    uge,

    pub fn eval(c: Cond, a: i64, b: i64) bool {
        const ua: u64 = @bitCast(a);
        const ub: u64 = @bitCast(b);
        return switch (c) {
            .eq => a == b,
            .ne => a != b,
            .lt => a < b,
            .le => a <= b,
            .gt => a > b,
            .ge => a >= b,
            .ult => ua < ub,
            .ule => ua <= ub,
            .ugt => ua > ub,
            .uge => ua >= ub,
        };
    }

    pub fn negate(c: Cond) Cond {
        return switch (c) {
            .eq => .ne,
            .ne => .eq,
            .lt => .ge,
            .ge => .lt,
            .le => .gt,
            .gt => .le,
            .ult => .uge,
            .uge => .ult,
            .ule => .ugt,
            .ugt => .ule,
        };
    }
};

/// A host function callable from JIT code. `func` must point to a C-ABI
/// function that takes exactly `arity` `i64` arguments and returns `i64`.
pub const HostFn = struct {
    name: []const u8,
    arity: u8,
    func: *const anyopaque,

    pub fn init(name: []const u8, comptime func: anytype) HostFn {
        const info = @typeInfo(@TypeOf(func)).@"fn";
        comptime {
            if (info.param_types.len > max_call_args) @compileError("too many host function parameters");
            for (info.param_types) |t| {
                if (t.? != i64) @compileError("host function parameters must be i64");
            }
            if (info.return_type.? != i64) @compileError("host functions must return i64");
        }
        return .{ .name = name, .arity = info.param_types.len, .func = @ptrCast(&func) };
    }

    /// Calls the host function directly. Used by the reference interpreter.
    pub fn invoke(self: HostFn, args: []const i64) i64 {
        std.debug.assert(args.len == self.arity);
        return callAddr(self.address(), args);
    }

    pub fn address(self: HostFn) usize {
        return @intFromPtr(self.func);
    }
};

/// Calls a C-ABI function at `addr` that takes `args.len` i64 arguments.
pub fn callAddr(addr: usize, args: []const i64) i64 {
    const a = args;
    switch (a.len) {
        0 => return @as(*const fn () callconv(.c) i64, @ptrFromInt(addr))(),
        1 => return @as(*const fn (i64) callconv(.c) i64, @ptrFromInt(addr))(a[0]),
        2 => return @as(*const fn (i64, i64) callconv(.c) i64, @ptrFromInt(addr))(a[0], a[1]),
        3 => return @as(*const fn (i64, i64, i64) callconv(.c) i64, @ptrFromInt(addr))(a[0], a[1], a[2]),
        4 => return @as(*const fn (i64, i64, i64, i64) callconv(.c) i64, @ptrFromInt(addr))(a[0], a[1], a[2], a[3]),
        5 => return @as(*const fn (i64, i64, i64, i64, i64) callconv(.c) i64, @ptrFromInt(addr))(a[0], a[1], a[2], a[3], a[4]),
        6 => return @as(*const fn (i64, i64, i64, i64, i64, i64) callconv(.c) i64, @ptrFromInt(addr))(a[0], a[1], a[2], a[3], a[4], a[5]),
        else => unreachable,
    }
}

pub const Inst = union(enum) {
    iconst: struct { dst: VReg, value: i64 },
    mov: struct { dst: VReg, src: VReg },
    bin: struct { op: BinOp, dst: VReg, lhs: VReg, rhs: VReg },
    cmp: struct { cond: Cond, dst: VReg, lhs: VReg, rhs: VReg },
    call: struct { dst: VReg, callee: u32, argc: u8, args: [max_call_args]VReg },
    label: Label,
    jmp: Label,
    br: struct { cond: Cond, lhs: VReg, rhs: VReg, target: Label },
    ret: VReg,

    /// The virtual register written by this instruction, if any.
    pub fn def(self: Inst) ?VReg {
        return switch (self) {
            .iconst => |i| i.dst,
            .mov => |i| i.dst,
            .bin => |i| i.dst,
            .cmp => |i| i.dst,
            .call => |i| i.dst,
            .label, .jmp, .br, .ret => null,
        };
    }

    /// The virtual registers read by this instruction, stored in `buf`.
    pub fn uses(self: *const Inst, buf: *[max_call_args]VReg) []const VReg {
        switch (self.*) {
            .iconst, .label, .jmp => return buf[0..0],
            .mov => |i| {
                buf[0] = i.src;
                return buf[0..1];
            },
            .bin => |i| {
                buf[0] = i.lhs;
                buf[1] = i.rhs;
                return buf[0..2];
            },
            .cmp => |i| {
                buf[0] = i.lhs;
                buf[1] = i.rhs;
                return buf[0..2];
            },
            .br => |i| {
                buf[0] = i.lhs;
                buf[1] = i.rhs;
                return buf[0..2];
            },
            .ret => |v| {
                buf[0] = v;
                return buf[0..1];
            },
            .call => |*i| return i.args[0..i.argc],
        }
    }

    /// Rewrites every read of a virtual register through `map`.
    pub fn mapUses(self: *Inst, ctx: anytype, comptime map: fn (@TypeOf(ctx), VReg) VReg) void {
        switch (self.*) {
            .iconst, .label, .jmp => {},
            .mov => |*i| i.src = map(ctx, i.src),
            .bin => |*i| {
                i.lhs = map(ctx, i.lhs);
                i.rhs = map(ctx, i.rhs);
            },
            .cmp => |*i| {
                i.lhs = map(ctx, i.lhs);
                i.rhs = map(ctx, i.rhs);
            },
            .br => |*i| {
                i.lhs = map(ctx, i.lhs);
                i.rhs = map(ctx, i.rhs);
            },
            .ret => |*v| v.* = map(ctx, v.*),
            .call => |*i| for (i.args[0..i.argc]) |*a| {
                a.* = map(ctx, a.*);
            },
        }
    }

    /// True when control never falls through to the next instruction.
    pub fn isTerminator(self: Inst) bool {
        return switch (self) {
            .jmp, .ret => true,
            else => false,
        };
    }

    /// True when the instruction can be deleted if its result is unused.
    pub fn isPure(self: Inst) bool {
        return switch (self) {
            .iconst, .mov, .bin, .cmp => true,
            else => false,
        };
    }

    pub fn write(self: Inst, w: *std.Io.Writer, hosts: []const HostFn) std.Io.Writer.Error!void {
        switch (self) {
            .iconst => |i| try w.print("%{d} = const {d}", .{ i.dst, i.value }),
            .mov => |i| try w.print("%{d} = mov %{d}", .{ i.dst, i.src }),
            .bin => |i| try w.print("%{d} = {s} %{d}, %{d}", .{ i.dst, @tagName(i.op), i.lhs, i.rhs }),
            .cmp => |i| try w.print("%{d} = {s} %{d}, %{d}", .{ i.dst, @tagName(i.cond), i.lhs, i.rhs }),
            .call => |i| {
                const name = if (i.callee < hosts.len) hosts[i.callee].name else "?";
                try w.print("%{d} = call {s}(", .{ i.dst, name });
                for (i.args[0..i.argc], 0..) |a, k| {
                    if (k != 0) try w.writeAll(", ");
                    try w.print("%{d}", .{a});
                }
                try w.writeAll(")");
            },
            .label => |l| try w.print("L{d}:", .{l}),
            .jmp => |l| try w.print("jmp L{d}", .{l}),
            .br => |i| try w.print("br {s} %{d}, %{d}, L{d}", .{ @tagName(i.cond), i.lhs, i.rhs, i.target }),
            .ret => |v| try w.print("ret %{d}", .{v}),
        }
    }
};

pub const ValidationError = error{
    TooManyParams,
    TooManyRegisters,
    TooManyLabels,
    TooManyInstructions,
    RegisterOutOfRange,
    LabelOutOfRange,
    DuplicateLabel,
    UndefinedLabel,
    UnknownCallee,
    ArityMismatch,
    MissingTerminator,
};

pub const Function = struct {
    num_params: u8,
    num_vregs: u32,
    num_labels: u32 = 0,
    insts: std.ArrayList(Inst) = .empty,
    hosts: []const HostFn = &.{},

    pub fn init(num_params: u8) Function {
        return .{ .num_params = num_params, .num_vregs = num_params };
    }

    pub fn deinit(self: *Function, gpa: std.mem.Allocator) void {
        self.insts.deinit(gpa);
        self.* = undefined;
    }

    pub fn clone(self: *const Function, gpa: std.mem.Allocator) !Function {
        var copy = self.*;
        copy.insts = .empty;
        try copy.insts.appendSlice(gpa, self.insts.items);
        return copy;
    }

    pub fn newVReg(self: *Function) VReg {
        const v = self.num_vregs;
        self.num_vregs += 1;
        return v;
    }

    pub fn newLabel(self: *Function) Label {
        const l = self.num_labels;
        self.num_labels += 1;
        return l;
    }

    pub fn param(self: *const Function, index: u8) VReg {
        std.debug.assert(index < self.num_params);
        return index;
    }

    pub fn append(self: *Function, gpa: std.mem.Allocator, inst: Inst) !void {
        try self.insts.append(gpa, inst);
    }

    // Small builder helpers used by tests and the CLI.
    pub fn iconst(self: *Function, gpa: std.mem.Allocator, value: i64) !VReg {
        const d = self.newVReg();
        try self.append(gpa, .{ .iconst = .{ .dst = d, .value = value } });
        return d;
    }

    pub fn binop(self: *Function, gpa: std.mem.Allocator, op: BinOp, a: VReg, b: VReg) !VReg {
        const d = self.newVReg();
        try self.append(gpa, .{ .bin = .{ .op = op, .dst = d, .lhs = a, .rhs = b } });
        return d;
    }

    /// Checks structural well-formedness: register and label ranges, unique
    /// labels, call arity and that execution cannot run off the end.
    /// Use-before-definition along some path is checked by `analysis.checkDefinedUses`.
    pub fn validate(self: *const Function) ValidationError!void {
        if (self.num_params > max_params) return error.TooManyParams;
        if (self.num_vregs > max_vregs or self.num_params > self.num_vregs) return error.TooManyRegisters;
        if (self.num_labels > max_labels) return error.TooManyLabels;
        if (self.insts.items.len > max_insts) return error.TooManyInstructions;
        var seen = std.bit_set.StaticBitSet(max_labels).empty;
        var buf: [max_call_args]VReg = undefined;
        for (self.insts.items) |*inst| {
            if (inst.def()) |d| if (d >= self.num_vregs) return error.RegisterOutOfRange;
            for (inst.uses(&buf)) |u| if (u >= self.num_vregs) return error.RegisterOutOfRange;
            switch (inst.*) {
                .label => |l| {
                    if (l >= self.num_labels) return error.LabelOutOfRange;
                    if (seen.isSet(l)) return error.DuplicateLabel;
                    seen.set(l);
                },
                .jmp => |l| if (l >= self.num_labels) return error.LabelOutOfRange,
                .br => |b| if (b.target >= self.num_labels) return error.LabelOutOfRange,
                .call => |c| {
                    if (c.callee >= self.hosts.len) return error.UnknownCallee;
                    if (c.argc > max_call_args or c.argc != self.hosts[c.callee].arity) return error.ArityMismatch;
                },
                else => {},
            }
        }
        for (self.insts.items) |inst| switch (inst) {
            .jmp => |l| if (!seen.isSet(l)) return error.UndefinedLabel,
            .br => |b| if (!seen.isSet(b.target)) return error.UndefinedLabel,
            else => {},
        };
        const items = self.insts.items;
        if (items.len == 0 or !items[items.len - 1].isTerminator()) return error.MissingTerminator;
    }

    pub fn write(self: *const Function, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("fn(params={d}, vregs={d}) {{\n", .{ self.num_params, self.num_vregs });
        for (self.insts.items) |inst| {
            if (inst == .label) {
                try inst.write(w, self.hosts);
            } else {
                try w.writeAll("    ");
                try inst.write(w, self.hosts);
            }
            try w.writeAll("\n");
        }
        try w.writeAll("}\n");
    }
};

test "binop semantics wrap and mask shifts" {
    const min = std.math.minInt(i64);
    try std.testing.expectEqual(@as(i64, min), BinOp.add.eval(std.math.maxInt(i64), 1));
    try std.testing.expectEqual(@as(i64, 0), BinOp.mul.eval(min, 2));
    try std.testing.expectEqual(@as(i64, 2), BinOp.shl.eval(1, 65));
    try std.testing.expectEqual(@as(i64, 1), BinOp.shr.eval(-1, 63));
    try std.testing.expectEqual(@as(i64, -1), BinOp.sar.eval(-1, 63));
    try std.testing.expectEqual(@as(i64, -4), BinOp.sar.eval(-8, 1));
    try std.testing.expect(Cond.ult.eval(1, -1));
    try std.testing.expect(!Cond.lt.eval(1, -1));
    for (std.enums.values(Cond)) |c| {
        try std.testing.expectEqual(!c.eval(3, -7), c.negate().eval(3, -7));
        try std.testing.expectEqual(!c.eval(5, 5), c.negate().eval(5, 5));
    }
}

test "validation rejects malformed functions" {
    const gpa = std.testing.allocator;
    var f = Function.init(1);
    defer f.deinit(gpa);
    try std.testing.expectError(error.MissingTerminator, f.validate());
    const l = f.newLabel();
    try f.append(gpa, .{ .jmp = l });
    try std.testing.expectError(error.UndefinedLabel, f.validate());
    try f.append(gpa, .{ .label = l });
    try f.append(gpa, .{ .label = l });
    try f.append(gpa, .{ .ret = 0 });
    try std.testing.expectError(error.DuplicateLabel, f.validate());
    f.insts.items[2] = .{ .ret = 7 };
    try std.testing.expectError(error.RegisterOutOfRange, f.validate());
    f.insts.items[2] = .{ .ret = 0 };
    try f.validate();
}
