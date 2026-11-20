const std = @import("std");
const builtin = @import("builtin");
const emitter = @import("emitter.zig");
const exec_mem = @import("exec_mem.zig");

pub const JitFn = *const fn (a: i64, b: i64) callconv(.c) i64;

/// Fixed-size code page for hand-assembled two-argument functions. Built on
/// `exec_mem.ExecMemory`, so the page is never writable and executable at the
/// same time, protection changes are checked, the instruction cache is
/// synchronized, and `loadCode` may be called repeatedly.
pub const JitEngine = struct {
    page: []align(std.heap.page_size_min) u8,
    is_executable: bool,
    mem: exec_mem.ExecMemory,

    pub fn init() !JitEngine {
        const mem = try exec_mem.ExecMemory.reserve(65536);
        return JitEngine{
            .page = mem.region,
            .is_executable = false,
            .mem = mem,
        };
    }

    pub fn deinit(self: *JitEngine) void {
        self.mem.deinit();
    }

    pub fn loadCode(self: *JitEngine, code: []const u8) !void {
        if (code.len > self.page.len) return error.CodeTooLarge;
        try self.mem.update(code);
        self.is_executable = true;
    }

    pub fn getFunction(self: *const JitEngine) ?JitFn {
        if (!self.is_executable) return null;
        return @ptrCast(@alignCast(self.page.ptr));
    }
};

fn emitBinary(buf: *emitter.Buffer, op: enum { add, sub }) bool {
    if (builtin.cpu.arch == .x86_64) {
        var asm_x86 = emitter.X86Assembler.init(buf);
        asm_x86.movRaxRdi();
        if (op == .add) asm_x86.addRaxRsi() else asm_x86.subRaxRsi();
        asm_x86.ret();
        return true;
    } else if (builtin.cpu.arch == .aarch64) {
        var asm_arm = emitter.Arm64Assembler.init(buf);
        if (op == .add) asm_arm.addX0X0X1() else asm_arm.subX0X0X1();
        asm_arm.ret();
        return true;
    }
    return false;
}

test "JIT Native Execution" {
    var buf = emitter.Buffer.init();
    if (!emitBinary(&buf, .add)) return;

    var jit = JitEngine.init() catch return;
    defer jit.deinit();

    jit.loadCode(buf.code[0..buf.len]) catch return;
    if (jit.getFunction()) |fun| {
        const res = fun(40, 2);
        try std.testing.expectEqual(@as(i64, 42), res);
    }
}

test "JitEngine reloads code in place" {
    if (!exec_mem.supported) return error.SkipZigTest;
    var add = emitter.Buffer.init();
    var sub = emitter.Buffer.init();
    if (!emitBinary(&add, .add) or !emitBinary(&sub, .sub)) return error.SkipZigTest;

    var jit = try JitEngine.init();
    defer jit.deinit();
    try std.testing.expect(jit.getFunction() == null);
    try jit.loadCode(add.code[0..add.len]);
    try std.testing.expectEqual(@as(i64, 42), jit.getFunction().?(40, 2));
    // The page was executable; reloading must make it writable first and
    // flush the instruction cache afterwards.
    try jit.loadCode(sub.code[0..sub.len]);
    try std.testing.expectEqual(@as(i64, 38), jit.getFunction().?(40, 2));
}
