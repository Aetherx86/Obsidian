const std = @import("std");
const builtin = @import("builtin");
const emitter = @import("emitter.zig");

pub const JitFn = *const fn (a: i64, b: i64) callconv(.c) i64;

pub const JitEngine = struct {
    page: []align(std.heap.page_size_min) u8,
    is_executable: bool,

    pub fn init() !JitEngine {
        const size = 65536;
        const ptr = try std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        return JitEngine{
            .page = ptr,
            .is_executable = false,
        };
    }

    pub fn deinit(self: *JitEngine) void {
        std.posix.munmap(self.page);
    }

    pub fn loadCode(self: *JitEngine, code: []const u8) !void {
        if (code.len > self.page.len) return error.CodeTooLarge;
        @memcpy(self.page[0..code.len], code);

        _ = std.posix.system.mprotect(
            @ptrCast(@alignCast(self.page.ptr)), self.page.len, .{ .READ = true, .EXEC = true }
        );
        self.is_executable = true;
    }

    pub fn getFunction(self: *const JitEngine) ?JitFn {
        if (!self.is_executable) return null;
        return @ptrCast(@alignCast(self.page.ptr));
    }
};

test "JIT Native Execution" {
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
    } else {
        return;
    }

    var jit = JitEngine.init() catch return;
    defer jit.deinit();

    jit.loadCode(buf.code[0..buf.len]) catch return;
    if (jit.getFunction()) |fun| {
        const res = fun(40, 2);
        try std.testing.expectEqual(@as(i64, 42), res);
    }
}
