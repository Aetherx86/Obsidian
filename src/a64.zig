//! AArch64 (AAPCS64) instruction encoder and code generator.
//!
//! Register roles:
//!   x16, x17      scratch registers (spill reloads, call target, cycle breaks)
//!   x18           platform register, never touched
//!   x29, x30      frame pointer and link register
//!   x0-x15        allocatable, caller-saved
//!   x19-x28       allocatable, callee-saved
//! Spill slots and callee-saved spills live above `sp`, which stays fixed
//! for the whole function body.

const std = @import("std");
const ir = @import("ir.zig");
const regalloc = @import("regalloc.zig");
const moves = @import("moves.zig");
const Listing = @import("listing.zig").Listing;

const Loc = regalloc.Loc;

/// General-purpose register number 0..30. Encoding 31 means `sp` or `xzr`
/// depending on the instruction and is spelled out explicitly where used.
pub const Reg = u5;
pub const sp: Reg = 31;
pub const xzr: Reg = 31;
pub const fp: Reg = 29;
pub const lr: Reg = 30;

pub const Cond = enum(u4) {
    eq = 0,
    ne = 1,
    hs = 2,
    lo = 3,
    mi = 4,
    pl = 5,
    vs = 6,
    vc = 7,
    hi = 8,
    ls = 9,
    ge = 10,
    lt = 11,
    gt = 12,
    le = 13,

    pub fn fromCond(c: ir.Cond) Cond {
        return switch (c) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            .ult => .lo,
            .ule => .ls,
            .ugt => .hi,
            .uge => .hs,
        };
    }

    pub fn invert(c: Cond) Cond {
        return @fromBackingInt(@intCast(@backingInt(c) ^ 1));
    }
};

pub const RegOp = enum(u32) {
    add = 0x8B000000,
    sub = 0xCB000000,
    @"and" = 0x8A000000,
    orr = 0xAA000000,
    eor = 0xCA000000,
    mul = 0x9B007C00, // madd xd, xn, xm, xzr
    lslv = 0x9AC02000,
    lsrv = 0x9AC02400,
    asrv = 0x9AC02800,

    fn mnemonic(op: RegOp) []const u8 {
        return switch (op) {
            .lslv => "lsl",
            .lsrv => "lsr",
            .asrv => "asr",
            else => @tagName(op),
        };
    }
};

fn rn(r: Reg) []const u8 {
    const names = [_][]const u8{ "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "x30", "xzr" };
    return names[r];
}

pub const Assembler = struct {
    gpa: std.mem.Allocator,
    code: std.ArrayList(u8) = .empty,
    listing: ?*Listing = null,

    pub fn init(gpa: std.mem.Allocator, listing: ?*Listing) Assembler {
        return .{ .gpa = gpa, .listing = listing };
    }

    pub fn deinit(self: *Assembler) void {
        self.code.deinit(self.gpa);
    }

    pub fn offset(self: *const Assembler) usize {
        return self.code.items.len;
    }

    fn word(self: *Assembler, w: u32, comptime fmt: []const u8, args: anytype) !void {
        const s = self.offset();
        var raw: [4]u8 = undefined;
        std.mem.writeInt(u32, &raw, w, .little);
        try self.code.appendSlice(self.gpa, &raw);
        if (self.listing) |l| try l.add(.insn, s, 4, fmt, args);
    }

    /// op xd, xn, xm
    pub fn regOp(self: *Assembler, op: RegOp, d: Reg, n: Reg, m: Reg) !void {
        try self.word(@backingInt(op) | @as(u32, m) << 16 | @as(u32, n) << 5 | d, "{s} {s}, {s}, {s}", .{ op.mnemonic(), rn(d), rn(n), rn(m) });
    }

    /// mov xd, xm  (orr xd, xzr, xm)
    pub fn movRR(self: *Assembler, d: Reg, m: Reg) !void {
        try self.word(0xAA0003E0 | @as(u32, m) << 16 | d, "mov {s}, {s}", .{ rn(d), rn(m) });
    }

    pub fn movz(self: *Assembler, d: Reg, imm: u16, hw: u2) !void {
        try self.word(0xD2800000 | @as(u32, hw) << 21 | @as(u32, imm) << 5 | d, "movz {s}, #0x{x}, lsl #{d}", .{ rn(d), imm, @as(u32, hw) * 16 });
    }

    pub fn movk(self: *Assembler, d: Reg, imm: u16, hw: u2) !void {
        try self.word(0xF2800000 | @as(u32, hw) << 21 | @as(u32, imm) << 5 | d, "movk {s}, #0x{x}, lsl #{d}", .{ rn(d), imm, @as(u32, hw) * 16 });
    }

    pub fn movn(self: *Assembler, d: Reg, imm: u16, hw: u2) !void {
        try self.word(0x92800000 | @as(u32, hw) << 21 | @as(u32, imm) << 5 | d, "movn {s}, #0x{x}, lsl #{d}", .{ rn(d), imm, @as(u32, hw) * 16 });
    }

    /// Materializes a 64-bit constant with the fewest movz/movn/movk.
    pub fn movImm(self: *Assembler, d: Reg, value: i64) !void {
        const v: u64 = @bitCast(value);
        var zeros: u32 = 0;
        var ones: u32 = 0;
        for (0..4) |k| {
            const chunk: u16 = @truncate(v >> @intCast(16 * k));
            if (chunk == 0) zeros += 1;
            if (chunk == 0xFFFF) ones += 1;
        }
        const use_movn = ones > zeros;
        const skip: u16 = if (use_movn) 0xFFFF else 0;
        var first = true;
        for (0..4) |k| {
            const chunk: u16 = @truncate(v >> @intCast(16 * k));
            if (chunk == skip) continue;
            const hw: u2 = @intCast(k);
            if (first) {
                if (use_movn) try self.movn(d, ~chunk, hw) else try self.movz(d, chunk, hw);
                first = false;
            } else {
                try self.movk(d, chunk, hw);
            }
        }
        if (first) {
            // Every chunk equals the skipped pattern: 0 or -1.
            if (use_movn) try self.movn(d, 0, 0) else try self.movz(d, 0, 0);
        }
    }

    /// ldr xt, [xn, #off]  (unsigned, 8-byte scaled offset)
    pub fn ldr(self: *Assembler, t: Reg, n: Reg, off: u32) !void {
        std.debug.assert(off % 8 == 0 and off / 8 < 4096);
        try self.word(0xF9400000 | (off / 8) << 10 | @as(u32, n) << 5 | t, "ldr {s}, [{s}, #{d}]", .{ rn(t), if (n == sp) "sp" else rn(n), off });
    }

    /// str xt, [xn, #off]
    pub fn str(self: *Assembler, t: Reg, n: Reg, off: u32) !void {
        std.debug.assert(off % 8 == 0 and off / 8 < 4096);
        try self.word(0xF9000000 | (off / 8) << 10 | @as(u32, n) << 5 | t, "str {s}, [{s}, #{d}]", .{ rn(t), if (n == sp) "sp" else rn(n), off });
    }

    /// cmp xn, xm  (subs xzr, xn, xm)
    pub fn cmp(self: *Assembler, n: Reg, m: Reg) !void {
        try self.word(0xEB00001F | @as(u32, m) << 16 | @as(u32, n) << 5, "cmp {s}, {s}", .{ rn(n), rn(m) });
    }

    /// cset xd, cond  (csinc xd, xzr, xzr, !cond)
    pub fn cset(self: *Assembler, d: Reg, c: Cond) !void {
        try self.word(0x9A9F07E0 | @as(u32, @backingInt(c.invert())) << 12 | d, "cset {s}, {t}", .{ rn(d), c });
    }

    /// b label; returns the offset of the instruction to patch.
    pub fn b(self: *Assembler, label: ir.Label) !usize {
        const s = self.offset();
        try self.word(0x14000000, "b L{d}", .{label});
        return s;
    }

    /// b.cond label; returns the offset of the instruction to patch.
    pub fn bcond(self: *Assembler, c: Cond, label: ir.Label) !usize {
        const s = self.offset();
        try self.word(0x54000000 | @as(u32, @backingInt(c)), "b.{t} L{d}", .{ c, label });
        return s;
    }

    pub fn patchBranch(self: *Assembler, at: usize, target: usize) !void {
        const delta: i64 = @divExact(@as(i64, @intCast(target)) - @as(i64, @intCast(at)), 4);
        const slot = self.code.items[at..][0..4];
        var w = std.mem.readInt(u32, slot, .little);
        if (w & 0xFC000000 == 0x14000000) {
            if (delta < -(1 << 25) or delta >= (1 << 25)) return error.BranchOutOfRange;
            w |= @as(u32, @bitCast(@as(i32, @intCast(delta)))) & 0x03FFFFFF;
        } else {
            if (delta < -(1 << 18) or delta >= (1 << 18)) return error.BranchOutOfRange;
            w |= (@as(u32, @bitCast(@as(i32, @intCast(delta)))) & 0x7FFFF) << 5;
        }
        std.mem.writeInt(u32, slot, w, .little);
    }

    pub fn blr(self: *Assembler, n: Reg) !void {
        try self.word(0xD63F0000 | @as(u32, n) << 5, "blr {s}", .{rn(n)});
    }

    pub fn ret(self: *Assembler) !void {
        try self.word(0xD65F03C0, "ret", .{});
    }

    /// stp x29, x30, [sp, #-16]!
    pub fn pushFrame(self: *Assembler) !void {
        try self.word(0xA9BF7BFD, "stp x29, x30, [sp, #-16]!", .{});
    }

    /// ldp x29, x30, [sp], #16
    pub fn popFrame(self: *Assembler) !void {
        try self.word(0xA8C17BFD, "ldp x29, x30, [sp], #16", .{});
    }

    /// mov x29, sp
    pub fn movFpSp(self: *Assembler) !void {
        try self.word(0x910003FD, "mov x29, sp", .{});
    }

    /// mov sp, x29
    pub fn movSpFp(self: *Assembler) !void {
        try self.word(0x910003BF, "mov sp, x29", .{});
    }

    /// sub sp, sp, #imm (imm < 2^24, split into a shifted and an unshifted part)
    pub fn subSp(self: *Assembler, imm: u32) !void {
        std.debug.assert(imm < (1 << 24));
        const hi = imm >> 12;
        const lo = imm & 0xFFF;
        if (hi != 0) try self.word(0xD1400000 | hi << 10 | @as(u32, sp) << 5 | sp, "sub sp, sp, #0x{x}, lsl #12", .{hi});
        if (lo != 0) try self.word(0xD1000000 | lo << 10 | @as(u32, sp) << 5 | sp, "sub sp, sp, #{d}", .{lo});
    }
};

pub const caller_saved = [_]u8{ 9, 10, 11, 12, 13, 14, 15, 8, 7, 6, 5, 4, 3, 2, 1, 0 };
pub const callee_saved = [_]u8{ 19, 20, 21, 22, 23, 24, 25, 26, 27, 28 };
pub const register_set: regalloc.RegisterSet = .{ .caller_saved = &caller_saved, .callee_saved = &callee_saved };

const scratch0: Reg = 16;
const scratch1: Reg = 17;

const Fixup = struct { at: usize, label: ir.Label };

const Gen = struct {
    as: Assembler,
    alloc: *const regalloc.Allocation,
    callee: []const u8,
    num_slots: u32,

    fn slotOff(self: *const Gen, slot: u32) u32 {
        _ = self;
        return 8 * slot;
    }

    fn loc(self: *const Gen, v: ir.VReg) Loc {
        return self.alloc.locs[v];
    }

    pub fn move(self: *Gen, dst: Loc, src: Loc) !void {
        switch (dst) {
            .none => {},
            .reg => |d| switch (src) {
                .none => {},
                .reg => |s| if (s != d) try self.as.movRR(@intCast(d), @intCast(s)),
                .stack => |s| try self.as.ldr(@intCast(d), sp, self.slotOff(s)),
            },
            .stack => |d| switch (src) {
                .none => {},
                .reg => |s| try self.as.str(@intCast(s), sp, self.slotOff(d)),
                .stack => |s| if (s != d) {
                    try self.as.ldr(scratch0, sp, self.slotOff(s));
                    try self.as.str(scratch0, sp, self.slotOff(d));
                },
            },
        }
    }

    fn useReg(self: *Gen, v: ir.VReg, fallback: Reg) !Reg {
        return switch (self.loc(v)) {
            .reg => |r| @intCast(r),
            .stack => |s| blk: {
                try self.as.ldr(fallback, sp, self.slotOff(s));
                break :blk fallback;
            },
            .none => unreachable,
        };
    }

    fn defReg(self: *const Gen, v: ir.VReg) Reg {
        return switch (self.loc(v)) {
            .reg => |r| @intCast(r),
            else => scratch0,
        };
    }

    fn finishDef(self: *Gen, v: ir.VReg, r: Reg) !void {
        try self.move(self.loc(v), .{ .reg = r });
    }

    fn calleeOff(self: *const Gen, k: usize) u32 {
        return 8 * (self.num_slots + @as(u32, @intCast(k)));
    }

    fn epilogue(self: *Gen) !void {
        for (self.callee, 0..) |r, k| try self.as.ldr(@intCast(r), sp, self.calleeOff(k));
        try self.as.movSpFp();
        try self.as.popFrame();
        try self.as.ret();
    }
};

/// Generates AArch64 machine code for an allocated function.
pub fn generate(gpa: std.mem.Allocator, f: *const ir.Function, alloc: *const regalloc.Allocation, listing: ?*Listing) ![]u8 {
    const ncs: u32 = @intCast(alloc.callee_saved_used.len);
    if (alloc.num_slots + ncs >= 4096) return error.FrameTooLarge;
    const frame: u32 = std.mem.alignForward(u32, 8 * (alloc.num_slots + ncs), 16);
    var g: Gen = .{
        .as = Assembler.init(gpa, listing),
        .alloc = alloc,
        .callee = alloc.callee_saved_used,
        .num_slots = alloc.num_slots,
    };
    errdefer g.as.deinit();
    const a = &g.as;

    if (listing) |l| try l.add(.ir, a.offset(), 0, "prologue (frame {d} bytes, {d} spill slots)", .{ frame, alloc.num_slots });
    try a.pushFrame();
    try a.movFpSp();
    if (frame > 0) try a.subSp(frame);
    for (g.callee, 0..) |r, k| try a.str(@intCast(r), sp, g.calleeOff(k));

    var entry: [ir.max_params]moves.Move = undefined;
    var nentry: usize = 0;
    for (0..f.num_params) |p| {
        if (alloc.entry_params & (@as(u8, 1) << @intCast(p)) == 0) continue;
        entry[nentry] = .{ .dst = alloc.locs[p], .src = .{ .reg = @intCast(p) } };
        nentry += 1;
    }
    try moves.resolve(entry[0..nentry], scratch1, &g);

    const label_off = try gpa.alloc(usize, f.num_labels);
    defer gpa.free(label_off);
    var fixups: std.ArrayList(Fixup) = .empty;
    defer fixups.deinit(gpa);

    for (f.insts.items) |inst| {
        if (listing) |l| {
            var buf: [160]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            inst.write(&w, f.hosts) catch {};
            try l.add(.ir, a.offset(), 0, "{s}", .{w.buffered()});
        }
        switch (inst) {
            .label => |l| label_off[l] = a.offset(),
            .iconst => |i| {
                if (g.loc(i.dst) == .none) continue;
                const d = g.defReg(i.dst);
                try a.movImm(d, i.value);
                try g.finishDef(i.dst, d);
            },
            .mov => |i| try g.move(g.loc(i.dst), g.loc(i.src)),
            .bin => |i| {
                const x = try g.useReg(i.lhs, scratch0);
                const y = try g.useReg(i.rhs, scratch1);
                const d = g.defReg(i.dst);
                const op: RegOp = switch (i.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .@"and" => .@"and",
                    .@"or" => .orr,
                    .xor => .eor,
                    .shl => .lslv,
                    .shr => .lsrv,
                    .sar => .asrv,
                };
                try a.regOp(op, d, x, y);
                try g.finishDef(i.dst, d);
            },
            .cmp => |i| {
                const x = try g.useReg(i.lhs, scratch0);
                const y = try g.useReg(i.rhs, scratch1);
                try a.cmp(x, y);
                const d = g.defReg(i.dst);
                try a.cset(d, Cond.fromCond(i.cond));
                try g.finishDef(i.dst, d);
            },
            .br => |br| {
                const x = try g.useReg(br.lhs, scratch0);
                const y = try g.useReg(br.rhs, scratch1);
                try a.cmp(x, y);
                try fixups.append(gpa, .{ .at = try a.bcond(Cond.fromCond(br.cond), br.target), .label = br.target });
            },
            .jmp => |l| try fixups.append(gpa, .{ .at = try a.b(l), .label = l }),
            .call => |c| {
                var mv: [ir.max_call_args]moves.Move = undefined;
                for (c.args[0..c.argc], 0..) |arg, k| {
                    mv[k] = .{ .dst = .{ .reg = @intCast(k) }, .src = g.loc(arg) };
                }
                try moves.resolve(mv[0..c.argc], scratch1, &g);
                try a.movImm(scratch0, @bitCast(@as(u64, f.hosts[c.callee].address())));
                try a.blr(scratch0);
                try g.move(g.loc(c.dst), .{ .reg = 0 });
            },
            .ret => |v| {
                try g.move(.{ .reg = 0 }, g.loc(v));
                try g.epilogue();
            },
        }
    }
    for (fixups.items) |fx| try a.patchBranch(fx.at, label_off[fx.label]);
    return a.code.toOwnedSlice(gpa);
}

fn expectWords(expected: []const u32, comptime emit: anytype) !void {
    var as = Assembler.init(std.testing.allocator, null);
    defer as.deinit();
    try emit(&as);
    try std.testing.expectEqual(expected.len * 4, as.code.items.len);
    for (expected, 0..) |w, k| {
        try std.testing.expectEqual(w, std.mem.readInt(u32, as.code.items[4 * k ..][0..4], .little));
    }
}

// Golden encodings below were cross-checked against `llvm-mc -triple=aarch64 -show-encoding`.
test "aarch64 golden encodings: data processing" {
    try expectWords(&.{
        0x8B010000, // add x0, x0, x1
        0xCB0201A9, // sub x9, x13, x2
        0x9B037C40, // mul x0, x2, x3
        0x8A1C0373, // and x19, x27, x28
        0xAA0B0151, // orr x17, x10, x11
        0xCA100210, // eor x16, x16, x16
        0x9AC22020, // lsl x0, x1, x2
        0x9AC22420, // lsr x0, x1, x2
        0x9AC22820, // asr x0, x1, x2
        0xAA0103E0, // mov x0, x1
        0xEB01001F, // cmp x0, x1
        0x9A9FA7E0, // cset x0, lt
        0x9A9F97E9, // cset x9, hi
    }, struct {
        fn e(a: *Assembler) !void {
            try a.regOp(.add, 0, 0, 1);
            try a.regOp(.sub, 9, 13, 2);
            try a.regOp(.mul, 0, 2, 3);
            try a.regOp(.@"and", 19, 27, 28);
            try a.regOp(.orr, 17, 10, 11);
            try a.regOp(.eor, 16, 16, 16);
            try a.regOp(.lslv, 0, 1, 2);
            try a.regOp(.lsrv, 0, 1, 2);
            try a.regOp(.asrv, 0, 1, 2);
            try a.movRR(0, 1);
            try a.cmp(0, 1);
            try a.cset(0, .lt);
            try a.cset(9, .hi);
        }
    }.e);
}

test "aarch64 golden encodings: immediates" {
    try expectWords(&.{
        0xD2800000, // movz x0, #0
        0x92800000, // movn x0, #0  (-1)
        0xD2800540, // movz x0, #42
        0x92800520, // movn x0, #41 (-42)
        0xD2BFFFE0, // movz x0, #0xffff, lsl #16
        0xD29BDE20, // movz x0, #0xdef1
        0xF2B13560, // movk x0, #0x89ab, lsl #16
        0xF2CACF00, // movk x0, #0x5678, lsl #32
        0xF2E24680, // movk x0, #0x1234, lsl #48
    }, struct {
        fn e(a: *Assembler) !void {
            try a.movImm(0, 0);
            try a.movImm(0, -1);
            try a.movImm(0, 42);
            try a.movImm(0, -42);
            try a.movImm(0, 0xFFFF0000);
            try a.movImm(0, 0x1234567889ABDEF1);
        }
    }.e);
}

test "aarch64 golden encodings: memory, frame and control flow" {
    try expectWords(&.{
        0xA9BF7BFD, // stp x29, x30, [sp, #-16]!
        0x910003FD, // mov x29, sp
        0xD10043FF, // sub sp, sp, #16
        0xD14007FF, // sub sp, sp, #1, lsl #12
        0xF90007F3, // str x19, [sp, #8]
        0xF94007F3, // ldr x19, [sp, #8]
        0xF97FFFF0, // ldr x16, [sp, #32760]
        0xD63F0200, // blr x16
        0x910003BF, // mov sp, x29
        0xA8C17BFD, // ldp x29, x30, [sp], #16
        0xD65F03C0, // ret
    }, struct {
        fn e(a: *Assembler) !void {
            try a.pushFrame();
            try a.movFpSp();
            try a.subSp(16);
            try a.subSp(4096);
            try a.str(19, sp, 8);
            try a.ldr(19, sp, 8);
            try a.ldr(16, sp, 32760);
            try a.blr(16);
            try a.movSpFp();
            try a.popFrame();
            try a.ret();
        }
    }.e);
}

test "aarch64 branch displacements are patched" {
    var as = Assembler.init(std.testing.allocator, null);
    defer as.deinit();
    const fwd = try as.b(0);
    const back = try as.bcond(.ne, 0);
    try as.patchBranch(fwd, 8);
    try as.patchBranch(back, 0);
    try std.testing.expectEqual(@as(u32, 0x14000002), std.mem.readInt(u32, as.code.items[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x54FFFFE1), std.mem.readInt(u32, as.code.items[4..8], .little));
}

test "legacy emitter encodings agree with the new assembler" {
    const emitter = @import("emitter.zig");
    var buf = emitter.Buffer.init();
    var old = emitter.Arm64Assembler.init(&buf);
    old.movzX0(42);
    old.addX0X0X1();
    old.subX0X0X1();
    old.mulX0X0X1();
    old.ret();
    var as = Assembler.init(std.testing.allocator, null);
    defer as.deinit();
    try as.movz(0, 42, 0);
    try as.regOp(.add, 0, 0, 1);
    try as.regOp(.sub, 0, 0, 1);
    try as.regOp(.mul, 0, 0, 1);
    try as.ret();
    try std.testing.expectEqualSlices(u8, buf.code[0..buf.len], as.code.items);
}
