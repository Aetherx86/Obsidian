//! x86_64 (System V ABI) instruction encoder and code generator.
//!
//! Register roles:
//!   rax, r11  scratch registers (results, spill reloads, call target)
//!   rcx       scratch for variable shift counts (and the fourth argument)
//!   rbp       frame pointer, spill slots live at negative offsets
//!   rdx rsi rdi r8 r9 r10  allocatable, caller-saved
//!   rbx r12 r13 r14 r15    allocatable, callee-saved

const std = @import("std");
const ir = @import("ir.zig");
const regalloc = @import("regalloc.zig");
const moves = @import("moves.zig");
const Listing = @import("listing.zig").Listing;

const Loc = regalloc.Loc;

pub const Reg = enum(u4) {
    rax,
    rcx,
    rdx,
    rbx,
    rsp,
    rbp,
    rsi,
    rdi,
    r8,
    r9,
    r10,
    r11,
    r12,
    r13,
    r14,
    r15,

    fn low(r: Reg) u3 {
        return @truncate(@backingInt(r));
    }

    fn ext(r: Reg) u1 {
        return @intCast(@backingInt(r) >> 3);
    }

    fn name8(r: Reg) []const u8 {
        const names = [_][]const u8{ "al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil", "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b" };
        return names[@backingInt(r)];
    }

    fn name32(r: Reg) []const u8 {
        const names = [_][]const u8{ "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d" };
        return names[@backingInt(r)];
    }
};

fn reg(r: u8) Reg {
    return @fromBackingInt(@intCast(@as(u4, @intCast(r))));
}

pub const Cc = enum(u4) {
    o,
    no,
    b,
    ae,
    e,
    ne,
    be,
    a,
    s,
    ns,
    p,
    np,
    l,
    ge,
    le,
    g,

    pub fn fromCond(c: ir.Cond) Cc {
        return switch (c) {
            .eq => .e,
            .ne => .ne,
            .lt => .l,
            .le => .le,
            .gt => .g,
            .ge => .ge,
            .ult => .b,
            .ule => .be,
            .ugt => .a,
            .uge => .ae,
        };
    }
};

pub const Alu = enum(u8) {
    add = 0x00,
    @"or" = 0x08,
    @"and" = 0x20,
    sub = 0x28,
    xor = 0x30,
    cmp = 0x38,
};

pub const Shift = enum(u3) {
    shl = 4,
    shr = 5,
    sar = 7,
};

pub const Mem = struct {
    base: Reg,
    disp: i32,

    pub fn format(m: Mem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (m.disp < 0) {
            try w.print("[{t}-{d}]", .{ m.base, -@as(i64, m.disp) });
        } else if (m.disp > 0) {
            try w.print("[{t}+{d}]", .{ m.base, m.disp });
        } else {
            try w.print("[{t}]", .{m.base});
        }
    }
};

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

    fn bytes(self: *Assembler, b: []const u8) !void {
        try self.code.appendSlice(self.gpa, b);
    }

    fn byte(self: *Assembler, b: u8) !void {
        try self.code.append(self.gpa, b);
    }

    fn int32(self: *Assembler, v: i32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, v, .little);
        try self.bytes(&b);
    }

    fn note(self: *Assembler, start: usize, comptime fmt: []const u8, args: anytype) !void {
        if (self.listing) |l| try l.add(.insn, start, self.offset() - start, fmt, args);
    }

    fn rex(w: u1, r: u1, x: u1, b: u1) u8 {
        return 0x40 | (@as(u8, w) << 3) | (@as(u8, r) << 2) | (@as(u8, x) << 1) | b;
    }

    fn modrm(mod: u2, r: u3, rm: u3) u8 {
        return (@as(u8, mod) << 6) | (@as(u8, r) << 3) | rm;
    }

    /// ModRM (+SIB) (+displacement) for `[base + disp]` with `r` in the reg field.
    fn memOperand(self: *Assembler, r: u3, m: Mem) !void {
        const base = m.base.low();
        const needs_disp = m.disp != 0 or base == 5; // rbp/r13 have no disp-less form
        const mod: u2 = if (!needs_disp) 0 else if (m.disp >= -128 and m.disp <= 127) 1 else 2;
        try self.byte(modrm(mod, r, base));
        if (base == 4) try self.byte(0x24); // SIB: base only (rsp/r12)
        switch (mod) {
            1 => try self.byte(@bitCast(@as(i8, @intCast(m.disp)))),
            2 => try self.int32(m.disp),
            else => {},
        }
    }

    /// mov dst, src
    pub fn movRR(self: *Assembler, dst: Reg, src: Reg) !void {
        const s = self.offset();
        try self.bytes(&.{ rex(1, src.ext(), 0, dst.ext()), 0x89, modrm(3, src.low(), dst.low()) });
        try self.note(s, "mov {t}, {t}", .{ dst, src });
    }

    /// Loads a 64-bit constant using the shortest encoding.
    pub fn movRI(self: *Assembler, dst: Reg, imm: i64) !void {
        const s = self.offset();
        if (imm == 0) {
            // xor r32, r32 (zero-extends; clobbers flags)
            if (dst.ext() == 1) try self.byte(rex(0, 1, 0, 1));
            try self.bytes(&.{ 0x31, modrm(3, dst.low(), dst.low()) });
            try self.note(s, "xor {s}, {s}", .{ dst.name32(), dst.name32() });
        } else if (imm > 0 and imm <= std.math.maxInt(u32)) {
            // mov r32, imm32 (zero-extends)
            if (dst.ext() == 1) try self.byte(rex(0, 0, 0, 1));
            try self.byte(0xB8 + @as(u8, dst.low()));
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @intCast(imm), .little);
            try self.bytes(&b);
            try self.note(s, "mov {s}, 0x{x}", .{ dst.name32(), imm });
        } else if (imm >= std.math.minInt(i32) and imm <= std.math.maxInt(i32)) {
            // mov r/m64, imm32 (sign-extends)
            try self.bytes(&.{ rex(1, 0, 0, dst.ext()), 0xC7, modrm(3, 0, dst.low()) });
            try self.int32(@intCast(imm));
            try self.note(s, "mov {t}, {d}", .{ dst, imm });
        } else {
            try self.bytes(&.{ rex(1, 0, 0, dst.ext()), 0xB8 + @as(u8, dst.low()) });
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, imm, .little);
            try self.bytes(&b);
            try self.note(s, "movabs {t}, 0x{x}", .{ dst, @as(u64, @bitCast(imm)) });
        }
    }

    /// mov dst, qword [mem]
    pub fn load(self: *Assembler, dst: Reg, m: Mem) !void {
        const s = self.offset();
        try self.bytes(&.{ rex(1, dst.ext(), 0, m.base.ext()), 0x8B });
        try self.memOperand(dst.low(), m);
        try self.note(s, "mov {t}, qword {f}", .{ dst, m });
    }

    /// mov qword [mem], src
    pub fn store(self: *Assembler, m: Mem, src: Reg) !void {
        const s = self.offset();
        try self.bytes(&.{ rex(1, src.ext(), 0, m.base.ext()), 0x89 });
        try self.memOperand(src.low(), m);
        try self.note(s, "mov qword {f}, {t}", .{ m, src });
    }

    /// mov qword [mem], imm32 (sign-extended)
    pub fn storeImm(self: *Assembler, m: Mem, imm: i32) !void {
        const s = self.offset();
        try self.bytes(&.{ rex(1, 0, 0, m.base.ext()), 0xC7 });
        try self.memOperand(0, m);
        try self.int32(imm);
        try self.note(s, "mov qword {f}, {d}", .{ m, imm });
    }

    /// op dst, src  (add, or, and, sub, xor, cmp)
    pub fn aluRR(self: *Assembler, op: Alu, dst: Reg, src: Reg) !void {
        const s = self.offset();
        try self.bytes(&.{ rex(1, src.ext(), 0, dst.ext()), @backingInt(op) + 1, modrm(3, src.low(), dst.low()) });
        try self.note(s, "{t} {t}, {t}", .{ op, dst, src });
    }

    /// op dst, qword [mem]
    pub fn aluRM(self: *Assembler, op: Alu, dst: Reg, m: Mem) !void {
        const s = self.offset();
        try self.bytes(&.{ rex(1, dst.ext(), 0, m.base.ext()), @backingInt(op) + 3 });
        try self.memOperand(dst.low(), m);
        try self.note(s, "{t} {t}, qword {f}", .{ op, dst, m });
    }

    /// imul dst, src
    pub fn imulRR(self: *Assembler, dst: Reg, src: Reg) !void {
        const s = self.offset();
        try self.bytes(&.{ rex(1, dst.ext(), 0, src.ext()), 0x0F, 0xAF, modrm(3, dst.low(), src.low()) });
        try self.note(s, "imul {t}, {t}", .{ dst, src });
    }

    /// imul dst, qword [mem]
    pub fn imulRM(self: *Assembler, dst: Reg, m: Mem) !void {
        const s = self.offset();
        try self.bytes(&.{ rex(1, dst.ext(), 0, m.base.ext()), 0x0F, 0xAF });
        try self.memOperand(dst.low(), m);
        try self.note(s, "imul {t}, qword {f}", .{ dst, m });
    }

    /// shl/shr/sar dst, cl
    pub fn shiftCl(self: *Assembler, kind: Shift, dst: Reg) !void {
        const s = self.offset();
        try self.bytes(&.{ rex(1, 0, 0, dst.ext()), 0xD3, modrm(3, @backingInt(kind), dst.low()) });
        try self.note(s, "{t} {t}, cl", .{ kind, dst });
    }

    /// setcc dst8 followed by movzx dst32, dst8, producing 0 or 1.
    pub fn setccZx(self: *Assembler, cc: Cc, dst: Reg) !void {
        var s = self.offset();
        // A REX prefix selects spl/bpl/sil/dil instead of ah/ch/dh/bh.
        if (@backingInt(dst) >= 4) try self.byte(rex(0, 0, 0, dst.ext()));
        try self.bytes(&.{ 0x0F, 0x90 + @as(u8, @backingInt(cc)), modrm(3, 0, dst.low()) });
        try self.note(s, "set{t} {s}", .{ cc, dst.name8() });
        s = self.offset();
        if (@backingInt(dst) >= 4) try self.byte(rex(0, dst.ext(), 0, dst.ext()));
        try self.bytes(&.{ 0x0F, 0xB6, modrm(3, dst.low(), dst.low()) });
        try self.note(s, "movzx {s}, {s}", .{ dst.name32(), dst.name8() });
    }

    /// jmp rel32; returns the offset of the displacement to patch.
    pub fn jmp32(self: *Assembler, label: ir.Label) !usize {
        const s = self.offset();
        try self.byte(0xE9);
        try self.int32(0);
        try self.note(s, "jmp L{d}", .{label});
        return s + 1;
    }

    /// jcc rel32; returns the offset of the displacement to patch.
    pub fn jcc32(self: *Assembler, cc: Cc, label: ir.Label) !usize {
        const s = self.offset();
        try self.bytes(&.{ 0x0F, 0x80 + @as(u8, @backingInt(cc)) });
        try self.int32(0);
        try self.note(s, "j{t} L{d}", .{ cc, label });
        return s + 2;
    }

    pub fn patchRel32(self: *Assembler, at: usize, target: usize) void {
        const rel: i64 = @as(i64, @intCast(target)) - @as(i64, @intCast(at + 4));
        std.mem.writeInt(i32, self.code.items[at..][0..4], @intCast(rel), .little);
    }

    /// call reg
    pub fn callR(self: *Assembler, r: Reg) !void {
        const s = self.offset();
        if (r.ext() == 1) try self.byte(rex(0, 0, 0, 1));
        try self.bytes(&.{ 0xFF, modrm(3, 2, r.low()) });
        try self.note(s, "call {t}", .{r});
    }

    pub fn push(self: *Assembler, r: Reg) !void {
        const s = self.offset();
        if (r.ext() == 1) try self.byte(rex(0, 0, 0, 1));
        try self.byte(0x50 + @as(u8, r.low()));
        try self.note(s, "push {t}", .{r});
    }

    pub fn pop(self: *Assembler, r: Reg) !void {
        const s = self.offset();
        if (r.ext() == 1) try self.byte(rex(0, 0, 0, 1));
        try self.byte(0x58 + @as(u8, r.low()));
        try self.note(s, "pop {t}", .{r});
    }

    /// sub rsp, imm32
    pub fn subRsp(self: *Assembler, imm: i32) !void {
        const s = self.offset();
        if (imm >= -128 and imm <= 127) {
            try self.bytes(&.{ 0x48, 0x83, 0xEC, @bitCast(@as(i8, @intCast(imm))) });
        } else {
            try self.bytes(&.{ 0x48, 0x81, 0xEC });
            try self.int32(imm);
        }
        try self.note(s, "sub rsp, {d}", .{imm});
    }

    /// lea rsp, [rbp + disp]
    pub fn leaRspRbp(self: *Assembler, disp: i32) !void {
        const s = self.offset();
        try self.bytes(&.{ 0x48, 0x8D });
        try self.memOperand(Reg.rsp.low(), .{ .base = .rbp, .disp = disp });
        try self.note(s, "lea rsp, {f}", .{Mem{ .base = .rbp, .disp = disp }});
    }

    pub fn ret(self: *Assembler) !void {
        const s = self.offset();
        try self.byte(0xC3);
        try self.note(s, "ret", .{});
    }
};

pub const caller_saved = [_]u8{ @backingInt(Reg.rdx), @backingInt(Reg.rsi), @backingInt(Reg.rdi), @backingInt(Reg.r8), @backingInt(Reg.r9), @backingInt(Reg.r10) };
pub const callee_saved = [_]u8{ @backingInt(Reg.rbx), @backingInt(Reg.r12), @backingInt(Reg.r13), @backingInt(Reg.r14), @backingInt(Reg.r15) };
pub const register_set: regalloc.RegisterSet = .{ .caller_saved = &caller_saved, .callee_saved = &callee_saved };
pub const arg_regs = [_]Reg{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

const scratch0: Reg = .rax;
const scratch1: Reg = .r11;

const Fixup = struct { at: usize, label: ir.Label };

const Gen = struct {
    as: Assembler,
    alloc: *const regalloc.Allocation,
    callee: []const u8,
    frame_size: i32,

    fn slotMem(self: *const Gen, slot: u32) Mem {
        const ncs: i32 = @intCast(self.callee.len);
        return .{ .base = .rbp, .disp = -8 * ncs - 8 * (@as(i32, @intCast(slot)) + 1) };
    }

    fn loc(self: *const Gen, v: ir.VReg) Loc {
        return self.alloc.locs[v];
    }

    /// Single move between any two locations (used by the move resolver).
    pub fn move(self: *Gen, dst: Loc, src: Loc) !void {
        switch (dst) {
            .none => {},
            .reg => |d| switch (src) {
                .none => {},
                .reg => |s| if (s != d) try self.as.movRR(reg(d), reg(s)),
                .stack => |s| try self.as.load(reg(d), self.slotMem(s)),
            },
            .stack => |d| switch (src) {
                .none => {},
                .reg => |s| try self.as.store(self.slotMem(d), reg(s)),
                .stack => |s| if (s != d) {
                    try self.as.load(scratch0, self.slotMem(s));
                    try self.as.store(self.slotMem(d), scratch0);
                },
            },
        }
    }

    /// Returns a register holding `v`, loading it into `fallback` if spilled.
    fn useReg(self: *Gen, v: ir.VReg, fallback: Reg) !Reg {
        return switch (self.loc(v)) {
            .reg => |r| reg(r),
            .stack => |s| blk: {
                try self.as.load(fallback, self.slotMem(s));
                break :blk fallback;
            },
            .none => unreachable,
        };
    }

    fn compare(self: *Gen, lhs: ir.VReg, rhs: ir.VReg) !void {
        const a = try self.useReg(lhs, scratch0);
        switch (self.loc(rhs)) {
            .reg => |r| try self.as.aluRR(.cmp, a, reg(r)),
            .stack => |s| try self.as.aluRM(.cmp, a, self.slotMem(s)),
            .none => unreachable,
        }
    }

    fn epilogue(self: *Gen) !void {
        const ncs: i32 = @intCast(self.callee.len);
        if (self.frame_size > 0) try self.as.leaRspRbp(-8 * ncs);
        var k = self.callee.len;
        while (k > 0) {
            k -= 1;
            try self.as.pop(reg(self.callee[k]));
        }
        try self.as.pop(.rbp);
        try self.as.ret();
    }
};

/// Generates x86_64 machine code for an allocated function.
pub fn generate(gpa: std.mem.Allocator, f: *const ir.Function, alloc: *const regalloc.Allocation, listing: ?*Listing) ![]u8 {
    const ncs = alloc.callee_saved_used.len;
    var frame: i32 = @intCast(8 * alloc.num_slots);
    // Keep rsp 16-byte aligned at call sites: return address + rbp + saves + frame.
    if (@mod(@as(i32, @intCast(8 * ncs)) + frame, 16) != 0) frame += 8;
    var g: Gen = .{
        .as = Assembler.init(gpa, listing),
        .alloc = alloc,
        .callee = alloc.callee_saved_used,
        .frame_size = frame,
    };
    errdefer g.as.deinit();
    const a = &g.as;

    if (listing) |l| try l.add(.ir, a.offset(), 0, "prologue (frame {d} bytes, {d} spill slots)", .{ frame, alloc.num_slots });
    try a.push(.rbp);
    try a.movRR(.rbp, .rsp);
    for (g.callee) |r| try a.push(reg(r));
    if (frame > 0) try a.subRsp(frame);

    var entry: [ir.max_params]moves.Move = undefined;
    var nentry: usize = 0;
    for (0..f.num_params) |p| {
        if (alloc.entry_params & (@as(u8, 1) << @intCast(p)) == 0) continue;
        entry[nentry] = .{ .dst = alloc.locs[p], .src = .{ .reg = @backingInt(arg_regs[p]) } };
        nentry += 1;
    }
    try moves.resolve(entry[0..nentry], @backingInt(scratch1), &g);

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
            .iconst => |i| switch (g.loc(i.dst)) {
                .reg => |r| try a.movRI(reg(r), i.value),
                .stack => |s| {
                    if (i.value >= std.math.minInt(i32) and i.value <= std.math.maxInt(i32)) {
                        try a.storeImm(g.slotMem(s), @intCast(i.value));
                    } else {
                        try a.movRI(scratch0, i.value);
                        try a.store(g.slotMem(s), scratch0);
                    }
                },
                .none => {},
            },
            .mov => |i| try g.move(g.loc(i.dst), g.loc(i.src)),
            .bin => |i| {
                const d = g.loc(i.dst);
                const b = g.loc(i.rhs);
                switch (i.op) {
                    .shl, .shr, .sar => {
                        try g.move(.{ .reg = @backingInt(Reg.rcx) }, b);
                        const t: Reg = if (d == .reg) reg(d.reg) else scratch0;
                        try g.move(.{ .reg = @backingInt(t) }, g.loc(i.lhs));
                        const kind: Shift = switch (i.op) {
                            .shl => .shl,
                            .shr => .shr,
                            else => .sar,
                        };
                        try a.shiftCl(kind, t);
                        try g.move(d, .{ .reg = @backingInt(t) });
                    },
                    else => {
                        // Two-address form: t = lhs; t op= rhs; dst = t.
                        const t: Reg = if (d == .reg and !(b == .reg and b.reg == d.reg)) reg(d.reg) else scratch0;
                        try g.move(.{ .reg = @backingInt(t) }, g.loc(i.lhs));
                        switch (b) {
                            .reg => |r| switch (i.op) {
                                .mul => try a.imulRR(t, reg(r)),
                                else => try a.aluRR(aluOf(i.op), t, reg(r)),
                            },
                            .stack => |s| switch (i.op) {
                                .mul => try a.imulRM(t, g.slotMem(s)),
                                else => try a.aluRM(aluOf(i.op), t, g.slotMem(s)),
                            },
                            .none => unreachable,
                        }
                        try g.move(d, .{ .reg = @backingInt(t) });
                    },
                }
            },
            .cmp => |i| {
                try g.compare(i.lhs, i.rhs);
                const d = g.loc(i.dst);
                const t: Reg = if (d == .reg) reg(d.reg) else scratch0;
                try a.setccZx(Cc.fromCond(i.cond), t);
                try g.move(d, .{ .reg = @backingInt(t) });
            },
            .br => |b| {
                try g.compare(b.lhs, b.rhs);
                try fixups.append(gpa, .{ .at = try a.jcc32(Cc.fromCond(b.cond), b.target), .label = b.target });
            },
            .jmp => |l| try fixups.append(gpa, .{ .at = try a.jmp32(l), .label = l }),
            .call => |c| {
                var mv: [ir.max_call_args]moves.Move = undefined;
                for (c.args[0..c.argc], 0..) |arg, k| {
                    mv[k] = .{ .dst = .{ .reg = @backingInt(arg_regs[k]) }, .src = g.loc(arg) };
                }
                try moves.resolve(mv[0..c.argc], @backingInt(scratch1), &g);
                try a.movRI(scratch1, @bitCast(@as(u64, f.hosts[c.callee].address())));
                try a.callR(scratch1);
                try g.move(g.loc(c.dst), .{ .reg = @backingInt(Reg.rax) });
            },
            .ret => |v| {
                try g.move(.{ .reg = @backingInt(Reg.rax) }, g.loc(v));
                try g.epilogue();
            },
        }
    }
    for (fixups.items) |fx| a.patchRel32(fx.at, label_off[fx.label]);
    return a.code.toOwnedSlice(gpa);
}

fn aluOf(op: ir.BinOp) Alu {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .@"and" => .@"and",
        .@"or" => .@"or",
        .xor => .xor,
        else => unreachable,
    };
}

fn expectBytes(expected: []const u8, comptime emit: anytype) !void {
    var as = Assembler.init(std.testing.allocator, null);
    defer as.deinit();
    try emit(&as);
    try std.testing.expectEqualSlices(u8, expected, as.code.items);
}

// Golden encodings below were cross-checked against `llvm-mc -triple=x86_64 -show-encoding`.
test "x86_64 golden encodings: moves and immediates" {
    try expectBytes(&.{ 0x48, 0x89, 0xF8 }, struct {
        fn e(a: *Assembler) !void {
            try a.movRR(.rax, .rdi);
        }
    }.e);
    try expectBytes(&.{ 0x4D, 0x89, 0xC8 }, struct {
        fn e(a: *Assembler) !void {
            try a.movRR(.r8, .r9);
        }
    }.e);
    try expectBytes(&.{ 0x45, 0x31, 0xDB, 0xB8, 0x2A, 0x00, 0x00, 0x00, 0x48, 0xC7, 0xC1, 0xFF, 0xFF, 0xFF, 0xFF, 0x49, 0xBB, 0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01 }, struct {
        fn e(a: *Assembler) !void {
            try a.movRI(.r11, 0); // xor r11d, r11d
            try a.movRI(.rax, 42); // mov eax, 42
            try a.movRI(.rcx, -1); // mov rcx, -1
            try a.movRI(.r11, 0x0123456789ABCDEF); // movabs r11, imm64
        }
    }.e);
    try expectBytes(&.{ 0x41, 0xBA, 0x00, 0x00, 0x00, 0x80 }, struct {
        fn e(a: *Assembler) !void {
            try a.movRI(.r10, 0x80000000); // mov r10d, 0x80000000
        }
    }.e);
}

test "x86_64 golden encodings: memory operands" {
    try expectBytes(&.{ 0x48, 0x8B, 0x45, 0xF0, 0x4C, 0x89, 0x5D, 0xE8, 0x48, 0x8B, 0x85, 0x00, 0xFF, 0xFF, 0xFF, 0x4C, 0x8B, 0x04, 0x24, 0x49, 0x8B, 0x45, 0x00 }, struct {
        fn e(a: *Assembler) !void {
            try a.load(.rax, .{ .base = .rbp, .disp = -16 }); // mov rax, [rbp-16]
            try a.store(.{ .base = .rbp, .disp = -24 }, .r11); // mov [rbp-24], r11
            try a.load(.rax, .{ .base = .rbp, .disp = -256 }); // disp32 form
            try a.load(.r8, .{ .base = .rsp, .disp = 0 }); // SIB form
            try a.load(.rax, .{ .base = .r13, .disp = 0 }); // r13 needs disp8
        }
    }.e);
    try expectBytes(&.{ 0x48, 0xC7, 0x45, 0xF8, 0x07, 0x00, 0x00, 0x00 }, struct {
        fn e(a: *Assembler) !void {
            try a.storeImm(.{ .base = .rbp, .disp = -8 }, 7); // mov qword [rbp-8], 7
        }
    }.e);
}

test "x86_64 golden encodings: arithmetic, compares and control flow" {
    try expectBytes(&.{
        0x48, 0x01, 0xF0, // add rax, rsi
        0x4C, 0x29, 0xC2, // sub rdx, r8
        0x49, 0x21, 0xDF, // and r15, rbx
        0x48, 0x09, 0xC8, // or rax, rcx
        0x4D, 0x31, 0xD2, // xor r10, r10
        0x48, 0x39, 0xF7, // cmp rdi, rsi
        0x48, 0x0F, 0xAF, 0xC6, // imul rax, rsi
        0x4C, 0x0F, 0xAF, 0x45, 0xF0, // imul r8, [rbp-16]
        0x48, 0x03, 0x45, 0xF8, // add rax, [rbp-8]
        0x48, 0xD3, 0xE0, // shl rax, cl
        0x49, 0xD3, 0xE9, // shr r9, cl
        0x48, 0xD3, 0xFA, // sar rdx, cl
    }, struct {
        fn e(a: *Assembler) !void {
            try a.aluRR(.add, .rax, .rsi);
            try a.aluRR(.sub, .rdx, .r8);
            try a.aluRR(.@"and", .r15, .rbx);
            try a.aluRR(.@"or", .rax, .rcx);
            try a.aluRR(.xor, .r10, .r10);
            try a.aluRR(.cmp, .rdi, .rsi);
            try a.imulRR(.rax, .rsi);
            try a.imulRM(.r8, .{ .base = .rbp, .disp = -16 });
            try a.aluRM(.add, .rax, .{ .base = .rbp, .disp = -8 });
            try a.shiftCl(.shl, .rax);
            try a.shiftCl(.shr, .r9);
            try a.shiftCl(.sar, .rdx);
        }
    }.e);
    try expectBytes(&.{
        0x0F, 0x9C, 0xC0, 0x0F, 0xB6, 0xC0, // setl al; movzx eax, al
        0x40, 0x0F, 0x94, 0xC6, 0x40, 0x0F, 0xB6, 0xF6, // sete sil; movzx esi, sil
        0x41, 0x0F, 0x97, 0xC1, 0x45, 0x0F, 0xB6, 0xC9, // seta r9b; movzx r9d, r9b
        0x41, 0xFF, 0xD3, // call r11
        0x55, 0x41, 0x54, 0x41, 0x5C, 0x5D, // push rbp; push r12; pop r12; pop rbp
        0x48, 0x83, 0xEC, 0x10, // sub rsp, 16
        0x48, 0x81, 0xEC, 0x00, 0x01, 0x00, 0x00, // sub rsp, 256
        0x48, 0x8D, 0x65, 0xE8, // lea rsp, [rbp-24]
        0xC3,
    }, struct {
        fn e(a: *Assembler) !void {
            try a.setccZx(.l, .rax);
            try a.setccZx(.e, .rsi);
            try a.setccZx(.a, .r9);
            try a.callR(.r11);
            try a.push(.rbp);
            try a.push(.r12);
            try a.pop(.r12);
            try a.pop(.rbp);
            try a.subRsp(16);
            try a.subRsp(256);
            try a.leaRspRbp(-24);
            try a.ret();
        }
    }.e);
}

test "x86_64 branch displacements are patched" {
    var as = Assembler.init(std.testing.allocator, null);
    defer as.deinit();
    const j = try as.jmp32(0); // forward over the jcc
    const c = try as.jcc32(.ne, 0); // backward to offset 0
    as.patchRel32(j, as.offset());
    as.patchRel32(c, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0xE9, 0x06, 0x00, 0x00, 0x00, 0x0F, 0x85, 0xF5, 0xFF, 0xFF, 0xFF }, as.code.items);
}

test "legacy emitter encodings agree with the new assembler" {
    const emitter = @import("emitter.zig");
    var buf = emitter.Buffer.init();
    var old = emitter.X86Assembler.init(&buf);
    old.movRaxRdi();
    old.addRaxRsi();
    old.subRaxRsi();
    old.imulRaxRsi();
    old.ret();
    var as = Assembler.init(std.testing.allocator, null);
    defer as.deinit();
    try as.movRR(.rax, .rdi);
    try as.aluRR(.add, .rax, .rsi);
    try as.aluRR(.sub, .rax, .rsi);
    try as.imulRR(.rax, .rsi);
    try as.ret();
    try std.testing.expectEqualSlices(u8, buf.code[0..buf.len], as.code.items);
}
