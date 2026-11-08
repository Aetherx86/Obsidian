const std = @import("std");
const builtin = @import("builtin");

pub const Arch = enum {
    x86_64,
    aarch64,
};

pub const Buffer = struct {
    code: [4096]u8,
    len: usize,

    pub fn init() Buffer {
        return .{
            .code = @splat(0),
            .len = 0,
        };
    }

    pub fn emitByte(self: *Buffer, b: u8) void {
        if (self.len < self.code.len) {
            self.code[self.len] = b;
            self.len += 1;
        }
    }

    pub fn emitBytes(self: *Buffer, bytes: []const u8) void {
        for (bytes) |b| self.emitByte(b);
    }

    pub fn emitU32(self: *Buffer, val: u32) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, val, .little);
        self.emitBytes(&bytes);
    }

    pub fn emitU64(self: *Buffer, val: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, val, .little);
        self.emitBytes(&bytes);
    }
};

pub const X86Assembler = struct {
    buf: *Buffer,

    pub fn init(buf: *Buffer) X86Assembler {
        return .{ .buf = buf };
    }

    pub fn movRaxImm64(self: *X86Assembler, val: u64) void {
        self.buf.emitBytes(&[_]u8{ 0x48, 0xB8 });
        self.buf.emitU64(val);
    }

    pub fn movRaxRdi(self: *X86Assembler) void {
        // MOV RAX, RDI
        self.buf.emitBytes(&[_]u8{ 0x48, 0x89, 0xF8 });
    }

    pub fn addRaxRsi(self: *X86Assembler) void {
        // ADD RAX, RSI
        self.buf.emitBytes(&[_]u8{ 0x48, 0x01, 0xF0 });
    }

    pub fn subRaxRsi(self: *X86Assembler) void {
        // SUB RAX, RSI
        self.buf.emitBytes(&[_]u8{ 0x48, 0x29, 0xF0 });
    }

    pub fn imulRaxRsi(self: *X86Assembler) void {
        // IMUL RAX, RSI
        self.buf.emitBytes(&[_]u8{ 0x48, 0x0F, 0xAF, 0xC6 });
    }

    pub fn ret(self: *X86Assembler) void {
        self.buf.emitByte(0xC3);
    }
};

pub const Arm64Assembler = struct {
    buf: *Buffer,

    pub fn init(buf: *Buffer) Arm64Assembler {
        return .{ .buf = buf };
    }

    pub fn movzX0(self: *Arm64Assembler, imm16: u16) void {
        // MOVZ X0, #imm16
        // Opcode: 1101 0010 100 [hw=00] [imm16] [Rd=00000]
        const instr: u32 = 0xD2800000 | (@as(u32, imm16) << 5);
        self.buf.emitU32(instr);
    }

    pub fn addX0X0X1(self: *Arm64Assembler) void {
        // ADD X0, X0, X1
        self.buf.emitU32(0x8B010000);
    }

    pub fn subX0X0X1(self: *Arm64Assembler) void {
        // SUB X0, X0, X1
        self.buf.emitU32(0xCB010000);
    }

    pub fn mulX0X0X1(self: *Arm64Assembler) void {
        // MUL X0, X0, X1 -> MADD X0, X0, X1, XZR
        self.buf.emitU32(0x9B017C00);
    }

    pub fn ret(self: *Arm64Assembler) void {
        // RET (X30)
        self.buf.emitU32(0xD65F03C0);
    }
};

test "x86_64 Machine Code Encoding" {
    var buf = Buffer.init();
    var asm_x86 = X86Assembler.init(&buf);

    asm_x86.movRaxRdi();
    asm_x86.addRaxRsi();
    asm_x86.ret();

    const expected = [_]u8{ 0x48, 0x89, 0xF8, 0x48, 0x01, 0xF0, 0xC3 };
    try std.testing.expectEqualSlices(u8, &expected, buf.code[0..buf.len]);
}

test "AArch64 Machine Code Encoding" {
    var buf = Buffer.init();
    var asm_arm = Arm64Assembler.init(&buf);

    asm_arm.addX0X0X1();
    asm_arm.ret();

    try std.testing.expectEqual(@as(usize, 8), buf.len);
    // 0x8B010000 in little endian = 00 00 01 8B
    try std.testing.expectEqual(@as(u8, 0x00), buf.code[0]);
    try std.testing.expectEqual(@as(u8, 0x8B), buf.code[3]);
    // 0xD65F03C0 in little endian = C0 03 5F D6
    try std.testing.expectEqual(@as(u8, 0xC0), buf.code[4]);
    try std.testing.expectEqual(@as(u8, 0xD6), buf.code[7]);
}
