//! W^X-correct executable memory.
//!
//! Code pages are never writable and executable for the running thread at
//! the same time:
//!
//! * macOS on Apple Silicon maps the region with `MAP_JIT` and flips the
//!   calling thread between write and execute access with
//!   `pthread_jit_write_protect_np`, then invalidates the instruction cache
//!   with `sys_icache_invalidate`.
//! * Every other POSIX target maps the region read/write, copies the code,
//!   then switches it to read/execute with `mprotect` (checking the result).
//!   On AArch64 the instruction cache is synchronized with `__clear_cache`.

const std = @import("std");
const builtin = @import("builtin");

pub const Strategy = enum { map_jit, mprotect };

pub const strategy: Strategy = if (builtin.os.tag.isDarwin() and builtin.cpu.arch == .aarch64) .map_jit else .mprotect;

pub const supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn pthread_jit_write_protect_supported_np() c_int;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;
extern fn __clear_cache(start: *anyopaque, end: *anyopaque) callconv(.c) void;

pub const Error = error{ UnsupportedPlatform, ProtectionFailed, CodeTooLarge, EmptyCode } || std.posix.MMapError;

pub const ExecMemory = struct {
    region: []align(std.heap.page_size_min) u8,
    code_len: usize,
    /// True once the region has been switched to read/execute.
    executable: bool,

    /// Maps enough pages for `code`, copies it in and makes it executable.
    pub fn create(code: []const u8) Error!ExecMemory {
        if (code.len == 0) return error.EmptyCode;
        var self = try reserve(code.len);
        errdefer self.deinit();
        try self.update(code);
        return self;
    }

    /// Maps `capacity` bytes (rounded up to whole pages) without code yet.
    pub fn reserve(capacity: usize) Error!ExecMemory {
        if (!supported) return error.UnsupportedPlatform;
        const page = std.heap.pageSize();
        const size = std.mem.alignForward(usize, @max(capacity, 1), page);
        const region = switch (strategy) {
            .map_jit => try std.posix.mmap(null, size, .{ .READ = true, .WRITE = true, .EXEC = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true }, -1, 0),
            .mprotect => try std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0),
        };
        return .{ .region = region, .code_len = 0, .executable = false };
    }

    /// Replaces the region's contents with `code` and leaves it executable.
    pub fn update(self: *ExecMemory, code: []const u8) Error!void {
        if (code.len > self.region.len) return error.CodeTooLarge;
        switch (strategy) {
            .map_jit => {
                pthread_jit_write_protect_np(0);
                @memcpy(self.region[0..code.len], code);
                pthread_jit_write_protect_np(1);
                sys_icache_invalidate(self.region.ptr, code.len);
            },
            .mprotect => {
                if (self.executable) try protect(self.region, .{ .READ = true, .WRITE = true });
                @memcpy(self.region[0..code.len], code);
                try protect(self.region, .{ .READ = true, .EXEC = true });
                if (builtin.cpu.arch == .aarch64 and code.len > 0) {
                    __clear_cache(self.region.ptr, self.region.ptr + code.len);
                }
            },
        }
        self.code_len = code.len;
        self.executable = true;
    }

    pub fn deinit(self: *ExecMemory) void {
        std.posix.munmap(self.region);
        self.* = undefined;
    }

    pub fn entryAddress(self: *const ExecMemory) usize {
        return @intFromPtr(self.region.ptr);
    }

    pub fn bytes(self: *const ExecMemory) []const u8 {
        return self.region[0..self.code_len];
    }
};

fn protect(region: []align(std.heap.page_size_min) u8, prot: std.posix.PROT) Error!void {
    const rc = std.posix.system.mprotect(@ptrCast(region.ptr), region.len, prot);
    if (std.posix.errno(rc) != .SUCCESS) return error.ProtectionFailed;
}

pub const Protection = struct { read: bool, write: bool, exec: bool };

/// Reports the current protection of the page containing `addr`, or null
/// when the platform offers no way to query it.
pub fn queryProtection(io: std.Io, gpa: std.mem.Allocator, addr: usize) !?Protection {
    switch (builtin.os.tag) {
        .macos => {
            const c = std.c;
            var address: c.mach_vm_address_t = addr;
            var size: c.mach_vm_size_t = 0;
            var info: c.vm_region_basic_info_64 = undefined;
            var count: c.mach_msg_type_number_t = c.VM.REGION.BASIC_INFO_COUNT;
            var object: c.mach_port_t = 0;
            const kr = c.mach_vm_region(c.mach_task_self(), &address, &size, c.VM.REGION.BASIC_INFO_64, @ptrCast(&info), &count, &object);
            if (kr != 0 or address > addr) return null;
            return .{ .read = info.protection.READ, .write = info.protection.WRITE, .exec = info.protection.EXEC };
        },
        .linux => {
            const maps = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/maps", gpa, .limited(16 << 20)) catch return null;
            defer gpa.free(maps);
            var lines = std.mem.splitScalar(u8, maps, '\n');
            while (lines.next()) |line| {
                var fields = std.mem.tokenizeScalar(u8, line, ' ');
                const range = fields.next() orelse continue;
                const perms = fields.next() orelse continue;
                const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
                const lo = std.fmt.parseInt(usize, range[0..dash], 16) catch continue;
                const hi = std.fmt.parseInt(usize, range[dash + 1 ..], 16) catch continue;
                if (addr >= lo and addr < hi and perms.len >= 3) {
                    return .{ .read = perms[0] == 'r', .write = perms[1] == 'w', .exec = perms[2] == 'x' };
                }
            }
            return null;
        },
        else => return null,
    }
}

/// Whether the running thread can toggle MAP_JIT write protection.
pub fn jitWriteProtectSupported() bool {
    return strategy == .map_jit and pthread_jit_write_protect_supported_np() != 0;
}

fn nativeReturn42() []const u8 {
    return switch (builtin.cpu.arch) {
        // mov eax, 42; ret
        .x86_64 => &.{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 },
        // movz x0, #42; ret
        .aarch64 => &.{ 0x40, 0x05, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6 },
        else => &.{},
    };
}

fn nativeReturn7() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => &.{ 0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3 },
        .aarch64 => &.{ 0xE0, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6 },
        else => &.{},
    };
}

test "executable memory runs code and can be rewritten" {
    if (!supported or nativeReturn42().len == 0) return error.SkipZigTest;
    var mem = try ExecMemory.create(nativeReturn42());
    defer mem.deinit();
    const f: *const fn () callconv(.c) i64 = @ptrFromInt(mem.entryAddress());
    try std.testing.expectEqual(@as(i64, 42), f());
    // Rewriting must flush the instruction cache so the new code runs.
    try mem.update(nativeReturn7());
    try std.testing.expectEqual(@as(i64, 7), f());
    try std.testing.expectEqualSlices(u8, nativeReturn7(), mem.bytes());
}

test "sealed code pages are not writable" {
    if (!supported or nativeReturn42().len == 0) return error.SkipZigTest;
    var mem = try ExecMemory.create(nativeReturn42());
    defer mem.deinit();
    const prot = (try queryProtection(std.testing.io, std.testing.allocator, mem.entryAddress())) orelse return error.SkipZigTest;
    try std.testing.expect(prot.exec);
    switch (strategy) {
        // The page itself is RWX; the hardware enforces W^X per thread.
        .map_jit => try std.testing.expect(jitWriteProtectSupported()),
        .mprotect => try std.testing.expect(!prot.write),
    }
}

test "empty and oversized code is rejected" {
    if (!supported) return error.SkipZigTest;
    try std.testing.expectError(error.EmptyCode, ExecMemory.create(&.{}));
    var mem = try ExecMemory.reserve(16);
    defer mem.deinit();
    const big = try std.testing.allocator.alloc(u8, mem.region.len + 1);
    defer std.testing.allocator.free(big);
    try std.testing.expectError(error.CodeTooLarge, mem.update(big));
}
