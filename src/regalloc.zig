//! Linear-scan register allocation (Poletto and Sarkar) with spilling.
//!
//! Instruction `i` reads its operands at position `2i` and writes its result
//! at position `2i + 1`, so a value whose last read is at instruction `i` can
//! share a location with the value that instruction `i` writes, while values
//! that are both read by the same instruction never share one.
//!
//! Live intervals come from block-level liveness, so a value that is live
//! around a loop back edge covers the whole loop. Each interval lives either
//! in one physical register or in one stack slot for its entire lifetime.
//! Intervals that are live across a call may only use callee-saved
//! registers. When registers run out, the interval with the furthest end
//! point is spilled. Stack slots are reused once their interval expires.

const std = @import("std");
const ir = @import("ir.zig");
const analysis = @import("analysis.zig");

pub const Loc = union(enum) {
    none,
    reg: u8,
    stack: u32,

    pub fn eql(a: Loc, b: Loc) bool {
        return switch (a) {
            .none => b == .none,
            .reg => |r| b == .reg and b.reg == r,
            .stack => |s| b == .stack and b.stack == s,
        };
    }
};

pub const RegisterSet = struct {
    /// Allocatable registers the callee may clobber, in preference order.
    caller_saved: []const u8,
    /// Allocatable registers preserved across calls, in preference order.
    callee_saved: []const u8,
};

pub const Interval = struct {
    vreg: ir.VReg,
    start: u32,
    end: u32,
    crosses_call: bool,
};

pub const Allocation = struct {
    /// Location of every virtual register (`.none` when it is never live).
    locs: []Loc,
    /// Live intervals sorted by start position.
    intervals: []Interval,
    num_slots: u32,
    num_spilled: u32,
    /// Callee-saved registers that the function body writes, ascending.
    callee_saved_used: []u8,
    /// Bit `p` is set when parameter `p` is live on entry and must be moved
    /// from its ABI argument register into its allocated location.
    entry_params: u8,

    pub fn deinit(self: *Allocation, gpa: std.mem.Allocator) void {
        gpa.free(self.locs);
        gpa.free(self.intervals);
        gpa.free(self.callee_saved_used);
        self.* = undefined;
    }
};

pub const Options = struct {
    /// Limits how many allocatable registers are used; `null` uses all of
    /// them. Small values force spilling and are used by the tests.
    max_regs: ?usize = null,
};

/// Computes conservative live intervals for every virtual register.
pub fn buildIntervals(gpa: std.mem.Allocator, f: *const ir.Function) !struct { intervals: []Interval, calls: []u32 } {
    var cfg = try analysis.Cfg.build(gpa, f);
    defer cfg.deinit(gpa);
    var live = try analysis.Liveness.compute(gpa, f, &cfg);
    defer live.deinit(gpa);
    try analysis.checkDefinedUses(f, &live, null);

    const nv = f.num_vregs;
    const lo = try gpa.alloc(u32, nv);
    defer gpa.free(lo);
    const hi = try gpa.alloc(u32, nv);
    defer gpa.free(hi);
    @memset(lo, std.math.maxInt(u32));
    @memset(hi, 0);
    const extend = struct {
        fn go(l: []u32, h: []u32, v: usize, pos: u32) void {
            l[v] = @min(l[v], pos);
            h[v] = @max(h[v], pos);
        }
    }.go;

    for (cfg.blocks, 0..) |b, bi| {
        var it_in = live.live_in[bi].iterator(.{});
        while (it_in.next()) |v| extend(lo, hi, v, usePos(b.start));
        var it_out = live.live_out[bi].iterator(.{});
        while (it_out.next()) |v| extend(lo, hi, v, defPos(b.end - 1));
    }
    var calls: std.ArrayList(u32) = .empty;
    errdefer calls.deinit(gpa);
    var buf: [ir.max_call_args]ir.VReg = undefined;
    for (f.insts.items, 0..) |*inst, i| {
        const idx: u32 = @intCast(i);
        if (inst.def()) |d| extend(lo, hi, d, defPos(idx));
        for (inst.uses(&buf)) |u| extend(lo, hi, u, usePos(idx));
        if (inst.* == .call) try calls.append(gpa, defPos(idx));
    }

    var list: std.ArrayList(Interval) = .empty;
    errdefer list.deinit(gpa);
    for (0..nv) |v| {
        if (lo[v] > hi[v]) continue;
        try list.append(gpa, .{
            .vreg = @intCast(v),
            .start = lo[v],
            .end = hi[v],
            .crosses_call = crossesCall(calls.items, lo[v], hi[v]),
        });
    }
    std.sort.pdq(Interval, list.items, {}, struct {
        fn lt(_: void, a: Interval, b: Interval) bool {
            if (a.start != b.start) return a.start < b.start;
            return a.vreg < b.vreg;
        }
    }.lt);
    return .{ .intervals = try list.toOwnedSlice(gpa), .calls = try calls.toOwnedSlice(gpa) };
}

pub fn usePos(inst_index: u32) u32 {
    return 2 * inst_index;
}

pub fn defPos(inst_index: u32) u32 {
    return 2 * inst_index + 1;
}

/// `calls` holds the result positions of call instructions. A value is live
/// across a call when it is live both when the call reads its arguments and
/// when it writes its result.
fn crossesCall(calls: []const u32, start: u32, end: u32) bool {
    // First call position strictly greater than `start`.
    var lo: usize = 0;
    var hi: usize = calls.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (calls[mid] <= start) lo = mid + 1 else hi = mid;
    }
    return lo < calls.len and calls[lo] <= end;
}

pub fn allocate(gpa: std.mem.Allocator, f: *const ir.Function, regs: RegisterSet, opts: Options) !Allocation {
    const built = try buildIntervals(gpa, f);
    errdefer gpa.free(built.intervals);
    defer gpa.free(built.calls);

    // Build the register pool. With a limit, alternate between the two
    // classes so that both caller- and callee-saved paths are exercised.
    var pool_buf: [64]u8 = undefined;
    var is_callee: [64]bool = undefined;
    var pool_len: usize = 0;
    const limit = @min(opts.max_regs orelse 64, regs.caller_saved.len + regs.callee_saved.len);
    if (opts.max_regs == null) {
        for (regs.caller_saved) |r| {
            pool_buf[pool_len] = r;
            is_callee[pool_len] = false;
            pool_len += 1;
        }
        for (regs.callee_saved) |r| {
            pool_buf[pool_len] = r;
            is_callee[pool_len] = true;
            pool_len += 1;
        }
    } else {
        var ci: usize = 0;
        var ei: usize = 0;
        while (pool_len < limit) {
            if (ci < regs.caller_saved.len and (pool_len % 2 == 0 or ei >= regs.callee_saved.len)) {
                pool_buf[pool_len] = regs.caller_saved[ci];
                is_callee[pool_len] = false;
                ci += 1;
            } else {
                pool_buf[pool_len] = regs.callee_saved[ei];
                is_callee[pool_len] = true;
                ei += 1;
            }
            pool_len += 1;
        }
    }
    const pool = pool_buf[0..pool_len];

    const locs = try gpa.alloc(Loc, f.num_vregs);
    errdefer gpa.free(locs);
    @memset(locs, .none);

    var reg_owner: [64]?usize = @splat(null); // pool index -> interval index
    var active: std.ArrayList(usize) = .empty; // intervals holding a register
    defer active.deinit(gpa);
    var active_spilled: std.ArrayList(usize) = .empty;
    defer active_spilled.deinit(gpa);
    var free_slots: std.ArrayList(FreeSlot) = .empty;
    defer free_slots.deinit(gpa);
    var num_slots: u32 = 0;
    var num_spilled: u32 = 0;
    var callee_used = std.bit_set.StaticBitSet(64).empty;

    const ivs = built.intervals;
    for (ivs, 0..) |cur, ci| {
        // Expire intervals that end before this start point.
        var k: usize = 0;
        while (k < active.items.len) {
            const a = active.items[k];
            if (ivs[a].end < cur.start) {
                const pi = poolIndex(pool, locs[ivs[a].vreg].reg);
                reg_owner[pi] = null;
                _ = active.swapRemove(k);
            } else k += 1;
        }
        k = 0;
        while (k < active_spilled.items.len) {
            const a = active_spilled.items[k];
            if (ivs[a].end < cur.start) {
                try free_slots.append(gpa, .{ .slot = locs[ivs[a].vreg].stack, .last_end = ivs[a].end });
                _ = active_spilled.swapRemove(k);
            } else k += 1;
        }

        var chosen: ?usize = null;
        for (pool, 0..) |_, pi| {
            if (reg_owner[pi] != null) continue;
            if (cur.crosses_call and !is_callee[pi]) continue;
            chosen = pi;
            break;
        }
        if (chosen == null) {
            // Spill the interval that ends furthest away.
            var victim: ?usize = null;
            for (active.items, 0..) |a, idx| {
                const pi = poolIndex(pool, locs[ivs[a].vreg].reg);
                if (cur.crosses_call and !is_callee[pi]) continue;
                if (victim == null or ivs[a].end > ivs[active.items[victim.?]].end) victim = idx;
            }
            if (victim) |vidx| {
                const a = active.items[vidx];
                if (ivs[a].end > cur.end) {
                    const pi = poolIndex(pool, locs[ivs[a].vreg].reg);
                    locs[ivs[a].vreg] = .{ .stack = takeSlot(&free_slots, &num_slots, ivs[a].start) };
                    num_spilled += 1;
                    _ = active.swapRemove(vidx);
                    try active_spilled.append(gpa, a);
                    reg_owner[pi] = null;
                    chosen = pi;
                }
            }
        }
        if (chosen) |pi| {
            reg_owner[pi] = ci;
            locs[cur.vreg] = .{ .reg = pool[pi] };
            if (is_callee[pi]) callee_used.set(pool[pi]);
            try active.append(gpa, ci);
        } else {
            locs[cur.vreg] = .{ .stack = takeSlot(&free_slots, &num_slots, cur.start) };
            num_spilled += 1;
            try active_spilled.append(gpa, ci);
        }
    }

    var entry_params: u8 = 0;
    for (ivs) |iv| {
        if (iv.vreg < f.num_params and iv.start == usePos(0)) entry_params |= @as(u8, 1) << @intCast(iv.vreg);
    }

    var used: std.ArrayList(u8) = .empty;
    errdefer used.deinit(gpa);
    var it = callee_used.iterator(.{});
    while (it.next()) |r| try used.append(gpa, @intCast(r));

    return .{
        .locs = locs,
        .intervals = ivs,
        .num_slots = num_slots,
        .num_spilled = num_spilled,
        .callee_saved_used = try used.toOwnedSlice(gpa),
        .entry_params = entry_params,
    };
}

fn poolIndex(pool: []const u8, reg: u8) usize {
    return std.mem.indexOfScalar(u8, pool, reg).?;
}

const FreeSlot = struct { slot: u32, last_end: u32 };

/// Returns a stack slot whose previous owner ended before `start`. A spilled
/// victim started before the current position, so a slot freed recently may
/// still overlap its interval; such slots are skipped.
fn takeSlot(free_slots: *std.ArrayList(FreeSlot), num_slots: *u32, start: u32) u32 {
    for (free_slots.items, 0..) |fs, i| {
        if (fs.last_end < start) {
            _ = free_slots.swapRemove(i);
            return fs.slot;
        }
    }
    const s = num_slots.*;
    num_slots.* += 1;
    return s;
}

/// Checks that no two simultaneously live values share a location and that
/// values live across calls avoid caller-saved registers.
pub fn verifyAllocation(f: *const ir.Function, a: *const Allocation, regs: RegisterSet) !void {
    _ = f;
    for (a.intervals, 0..) |x, i| {
        const lx = a.locs[x.vreg];
        if (lx == .none) return error.UnallocatedInterval;
        if (x.crosses_call and lx == .reg and std.mem.indexOfScalar(u8, regs.caller_saved, lx.reg) != null)
            return error.CallerSavedAcrossCall;
        for (a.intervals[i + 1 ..]) |y| {
            if (y.start > x.end) break;
            if (lx.eql(a.locs[y.vreg])) return error.LocationConflict;
        }
    }
}

test "intervals extend across loop back edges" {
    const gpa = std.testing.allocator;
    var f = ir.Function.init(1);
    defer f.deinit(gpa);
    const s = try f.iconst(gpa, 0); // 0
    const one = try f.iconst(gpa, 1); // 1
    const head = f.newLabel();
    const exit = f.newLabel();
    try f.append(gpa, .{ .label = head }); // 2
    try f.append(gpa, .{ .br = .{ .cond = .le, .lhs = 0, .rhs = s, .target = exit } }); // 3
    try f.append(gpa, .{ .bin = .{ .op = .add, .dst = s, .lhs = s, .rhs = one } }); // 4
    try f.append(gpa, .{ .jmp = head }); // 5
    try f.append(gpa, .{ .label = exit }); // 6
    try f.append(gpa, .{ .ret = s }); // 7
    const built = try buildIntervals(gpa, &f);
    defer gpa.free(built.intervals);
    defer gpa.free(built.calls);
    for (built.intervals) |iv| {
        if (iv.vreg == one) {
            try std.testing.expectEqual(defPos(1), iv.start);
            try std.testing.expectEqual(defPos(5), iv.end);
        }
        if (iv.vreg == 0) {
            try std.testing.expectEqual(usePos(0), iv.start);
            try std.testing.expectEqual(defPos(5), iv.end);
        }
    }
}

test "spilling under register pressure stays conflict free" {
    const gpa = std.testing.allocator;
    var f = ir.Function.init(2);
    defer f.deinit(gpa);
    var vals: [12]ir.VReg = undefined;
    for (&vals, 0..) |*v, i| v.* = try f.iconst(gpa, @intCast(i));
    var acc = try f.binop(gpa, .add, 0, 1);
    for (vals) |v| acc = try f.binop(gpa, .add, acc, v);
    try f.append(gpa, .{ .ret = acc });
    const regs: RegisterSet = .{ .caller_saved = &.{ 1, 2, 3 }, .callee_saved = &.{ 4, 5 } };
    for ([_]?usize{ null, 0, 1, 2, 3 }) |limit| {
        var a = try allocate(gpa, &f, regs, .{ .max_regs = limit });
        defer a.deinit(gpa);
        try verifyAllocation(&f, &a, regs);
        if (limit != null and limit.? < 3) try std.testing.expect(a.num_spilled > 0);
    }
}
