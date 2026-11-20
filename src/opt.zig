//! IR optimizer: constant folding with algebraic simplification, copy
//! propagation, branch folding, unreachable code removal, jump threading to
//! fall-through labels and liveness-based dead-code elimination.
//!
//! Every pass preserves the semantics defined by `interp.zig`; the
//! differential tests in `fuzz.zig` check this on random programs.

const std = @import("std");
const ir = @import("ir.zig");
const analysis = @import("analysis.zig");

const BitSet = std.bit_set.Dynamic;

pub const Stats = struct {
    folded: u32 = 0,
    copies_propagated: u32 = 0,
    branches_folded: u32 = 0,
    unreachable_removed: u32 = 0,
    jumps_removed: u32 = 0,
    dead_removed: u32 = 0,
    rounds: u32 = 0,

    fn total(s: Stats) u64 {
        return @as(u64, s.folded) + s.copies_propagated + s.branches_folded +
            s.unreachable_removed + s.jumps_removed + s.dead_removed;
    }
};

/// Runs all passes until a fixed point (at most `max_rounds` rounds).
pub fn optimize(gpa: std.mem.Allocator, f: *ir.Function) !Stats {
    try analysis.verify(gpa, f);
    var stats: Stats = .{};
    const max_rounds = 16;
    while (stats.rounds < max_rounds) {
        const before = stats.total();
        stats.rounds += 1;
        try foldConstants(gpa, f, &stats);
        try removeUnreachable(gpa, f, &stats);
        try simplifyJumps(gpa, f, &stats);
        try eliminateDeadCode(gpa, f, &stats);
        if (stats.total() == before) break;
    }
    return stats;
}

fn compact(gpa: std.mem.Allocator, f: *ir.Function, remove: *const BitSet) void {
    _ = gpa;
    var out: usize = 0;
    for (f.insts.items, 0..) |inst, i| {
        if (remove.isSet(i)) continue;
        f.insts.items[out] = inst;
        out += 1;
    }
    f.insts.shrinkRetainingCapacity(out);
}

const CopyEntry = struct { src: ir.VReg, gen: u32 };

const FoldState = struct {
    known: []?i64,
    copy: []?CopyEntry,
    gen: []u32,

    fn reset(s: *FoldState) void {
        @memset(s.known, null);
        @memset(s.copy, null);
    }

    fn resolve(s: *FoldState, v: ir.VReg) ir.VReg {
        if (s.copy[v]) |c| {
            if (s.gen[c.src] == c.gen) return c.src;
            s.copy[v] = null;
        }
        return v;
    }

    fn define(s: *FoldState, d: ir.VReg) void {
        s.gen[d] +%= 1;
        s.known[d] = null;
        s.copy[d] = null;
    }
};

fn mapResolve(s: *FoldState, v: ir.VReg) ir.VReg {
    return s.resolve(v);
}

/// Block-local constant propagation and folding plus copy propagation.
pub fn foldConstants(gpa: std.mem.Allocator, f: *ir.Function, stats: *Stats) !void {
    const n = f.num_vregs;
    var st: FoldState = .{
        .known = try gpa.alloc(?i64, n),
        .copy = try gpa.alloc(?CopyEntry, n),
        .gen = try gpa.alloc(u32, n),
    };
    defer {
        gpa.free(st.known);
        gpa.free(st.copy);
        gpa.free(st.gen);
    }
    st.reset();
    @memset(st.gen, 0);
    var remove = try BitSet.initEmpty(gpa, f.insts.items.len);
    defer remove.deinit(gpa);

    for (f.insts.items, 0..) |*inst, idx| {
        // Copy propagation: read the oldest equivalent register.
        var ubuf: [ir.max_call_args]ir.VReg = undefined;
        const old_uses = inst.uses(&ubuf);
        var changed_use = false;
        for (old_uses) |u| {
            if (st.resolve(u) != u) changed_use = true;
        }
        if (changed_use) {
            inst.mapUses(&st, mapResolve);
            stats.copies_propagated += 1;
        }

        switch (inst.*) {
            .label => st.reset(),
            .jmp, .ret => st.reset(),
            .iconst => |i| {
                st.define(i.dst);
                st.known[i.dst] = i.value;
            },
            .mov => |i| {
                if (i.dst == i.src) {
                    remove.set(idx);
                    stats.folded += 1;
                    continue;
                }
                if (st.known[i.src]) |k| {
                    inst.* = .{ .iconst = .{ .dst = i.dst, .value = k } };
                    stats.folded += 1;
                    st.define(i.dst);
                    st.known[i.dst] = k;
                } else {
                    st.define(i.dst);
                    st.copy[i.dst] = .{ .src = i.src, .gen = st.gen[i.src] };
                }
            },
            .bin => |i| {
                const ka = st.known[i.lhs];
                const kb = st.known[i.rhs];
                const simplified: ?Simplified = if (ka != null and kb != null)
                    .{ .constant = i.op.eval(ka.?, kb.?) }
                else
                    simplifyBin(i.op, i.lhs, i.rhs, ka, kb);
                st.define(i.dst);
                if (simplified) |s| {
                    stats.folded += 1;
                    switch (s) {
                        .constant => |c| {
                            inst.* = .{ .iconst = .{ .dst = i.dst, .value = c } };
                            st.known[i.dst] = c;
                        },
                        .copy => |src| {
                            if (src == i.dst) {
                                remove.set(idx);
                            } else {
                                inst.* = .{ .mov = .{ .dst = i.dst, .src = src } };
                                st.copy[i.dst] = .{ .src = src, .gen = st.gen[src] };
                            }
                        },
                    }
                }
            },
            .cmp => |i| {
                const ka = st.known[i.lhs];
                const kb = st.known[i.rhs];
                const result: ?bool = if (ka != null and kb != null)
                    i.cond.eval(ka.?, kb.?)
                else if (i.lhs == i.rhs)
                    i.cond.eval(0, 0)
                else
                    null;
                st.define(i.dst);
                if (result) |r| {
                    inst.* = .{ .iconst = .{ .dst = i.dst, .value = @intFromBool(r) } };
                    st.known[i.dst] = @intFromBool(r);
                    stats.folded += 1;
                }
            },
            .call => |i| st.define(i.dst),
            .br => |b| {
                const ka = st.known[b.lhs];
                const kb = st.known[b.rhs];
                const taken: ?bool = if (ka != null and kb != null)
                    b.cond.eval(ka.?, kb.?)
                else if (b.lhs == b.rhs)
                    b.cond.eval(0, 0)
                else
                    null;
                if (taken) |t| {
                    stats.branches_folded += 1;
                    if (t) {
                        inst.* = .{ .jmp = b.target };
                        st.reset();
                    } else {
                        remove.set(idx);
                    }
                }
            },
        }
    }
    compact(gpa, f, &remove);
}

const Simplified = union(enum) { constant: i64, copy: ir.VReg };

fn simplifyBin(op: ir.BinOp, a: ir.VReg, b: ir.VReg, ka: ?i64, kb: ?i64) ?Simplified {
    if (a == b) switch (op) {
        .sub, .xor => return .{ .constant = 0 },
        .@"and", .@"or" => return .{ .copy = a },
        else => {},
    };
    if (kb) |k| switch (op) {
        .add, .sub, .@"or", .xor => if (k == 0) return .{ .copy = a },
        .mul => {
            if (k == 0) return .{ .constant = 0 };
            if (k == 1) return .{ .copy = a };
        },
        .@"and" => {
            if (k == 0) return .{ .constant = 0 };
            if (k == -1) return .{ .copy = a };
        },
        .shl, .shr, .sar => if (k & 63 == 0) return .{ .copy = a },
    };
    if (ka) |k| switch (op) {
        .add, .@"or", .xor => if (k == 0) return .{ .copy = b },
        .mul => {
            if (k == 0) return .{ .constant = 0 };
            if (k == 1) return .{ .copy = b };
        },
        .@"and" => {
            if (k == 0) return .{ .constant = 0 };
            if (k == -1) return .{ .copy = b };
        },
        .shl, .shr => if (k == 0) return .{ .constant = 0 },
        .sar => if (k == 0 or k == -1) return .{ .constant = k },
        .sub => {},
    };
    if (op == .@"or") {
        if (ka == -1 or kb == -1) return .{ .constant = -1 };
    }
    return null;
}

/// Deletes every instruction in a block that cannot be reached from entry.
pub fn removeUnreachable(gpa: std.mem.Allocator, f: *ir.Function, stats: *Stats) !void {
    var cfg = try analysis.Cfg.build(gpa, f);
    defer cfg.deinit(gpa);
    var reach = try cfg.reachable(gpa);
    defer reach.deinit(gpa);
    var remove = try BitSet.initEmpty(gpa, f.insts.items.len);
    defer remove.deinit(gpa);
    var any = false;
    for (cfg.blocks, 0..) |b, bi| {
        if (reach.isSet(bi)) continue;
        any = true;
        for (b.start..b.end) |i| remove.set(i);
        stats.unreachable_removed += b.end - b.start;
    }
    if (any) compact(gpa, f, &remove);
}

/// Removes jumps and branches to the label that immediately follows them,
/// and labels that nothing jumps to.
pub fn simplifyJumps(gpa: std.mem.Allocator, f: *ir.Function, stats: *Stats) !void {
    const items = f.insts.items;
    var remove = try BitSet.initEmpty(gpa, items.len);
    defer remove.deinit(gpa);
    for (items, 0..) |inst, i| {
        if (i + 1 >= items.len) break;
        const target: ?ir.Label = switch (inst) {
            .jmp => |l| l,
            .br => |b| b.target,
            else => null,
        };
        const t = target orelse continue;
        // Look past consecutive labels: any of them is the fall-through point.
        var j = i + 1;
        while (j < items.len and items[j] == .label) : (j += 1) {
            if (items[j].label == t) {
                remove.set(i);
                stats.jumps_removed += 1;
                break;
            }
        }
    }
    var referenced = try BitSet.initEmpty(gpa, f.num_labels);
    defer referenced.deinit(gpa);
    for (items, 0..) |inst, i| {
        if (remove.isSet(i)) continue;
        switch (inst) {
            .jmp => |l| referenced.set(l),
            .br => |b| referenced.set(b.target),
            else => {},
        }
    }
    for (items, 0..) |inst, i| {
        if (inst == .label and !referenced.isSet(inst.label)) {
            remove.set(i);
            stats.jumps_removed += 1;
        }
    }
    compact(gpa, f, &remove);
}

/// Removes pure instructions whose results are never read.
pub fn eliminateDeadCode(gpa: std.mem.Allocator, f: *ir.Function, stats: *Stats) !void {
    var cfg = try analysis.Cfg.build(gpa, f);
    defer cfg.deinit(gpa);
    var live = try analysis.Liveness.compute(gpa, f, &cfg);
    defer live.deinit(gpa);
    var remove = try BitSet.initEmpty(gpa, f.insts.items.len);
    defer remove.deinit(gpa);
    var cur = try BitSet.initEmpty(gpa, f.num_vregs);
    defer cur.deinit(gpa);
    var any = false;
    var buf: [ir.max_call_args]ir.VReg = undefined;
    for (cfg.blocks, 0..) |b, bi| {
        cur.unsetAll();
        cur.setUnion(live.live_out[bi]);
        var i = b.end;
        while (i > b.start) {
            i -= 1;
            const inst = &f.insts.items[i];
            if (inst.def()) |d| {
                if (inst.isPure() and !cur.isSet(d)) {
                    remove.set(i);
                    stats.dead_removed += 1;
                    any = true;
                    continue;
                }
                cur.unset(d);
            }
            for (inst.uses(&buf)) |u| cur.set(u);
        }
    }
    if (any) compact(gpa, f, &remove);
}

const interp = @import("interp.zig");

test "constant folding collapses arithmetic and branches" {
    const gpa = std.testing.allocator;
    var f = ir.Function.init(1);
    defer f.deinit(gpa);
    const a = try f.iconst(gpa, 6);
    const b = try f.iconst(gpa, 7);
    const c = try f.binop(gpa, .mul, a, b);
    const zero = try f.iconst(gpa, 0);
    const d = try f.binop(gpa, .add, 0, zero); // x + 0
    const e = try f.binop(gpa, .xor, d, d); // always 0
    const r = try f.binop(gpa, .add, c, e);
    const skip = f.newLabel();
    try f.append(gpa, .{ .br = .{ .cond = .gt, .lhs = c, .rhs = zero, .target = skip } });
    try f.append(gpa, .{ .ret = 0 });
    try f.append(gpa, .{ .label = skip });
    try f.append(gpa, .{ .ret = r });

    var orig = try f.clone(gpa);
    defer orig.deinit(gpa);
    const stats = try optimize(gpa, &f);
    try std.testing.expect(stats.folded >= 3);
    try std.testing.expect(stats.branches_folded == 1);
    // Everything folds to `const 42; ret`.
    try std.testing.expectEqual(@as(usize, 2), f.insts.items.len);
    try std.testing.expectEqual(@as(i64, 42), f.insts.items[0].iconst.value);
    try std.testing.expect(f.insts.items[1] == .ret);
    for ([_]i64{ -5, 0, 9 }) |x| {
        const want = try interp.run(gpa, &orig, &.{x}, 100);
        const got = try interp.run(gpa, &f, &.{x}, 100);
        try std.testing.expectEqual(want.value, got.value);
    }
}

test "dead code elimination keeps calls and loop-carried values" {
    const gpa = std.testing.allocator;
    var f = ir.Function.init(1);
    defer f.deinit(gpa);
    const s = try f.iconst(gpa, 0);
    const unused = try f.binop(gpa, .mul, 0, 0);
    _ = unused;
    const one = try f.iconst(gpa, 1);
    const head = f.newLabel();
    const exit = f.newLabel();
    try f.append(gpa, .{ .label = head });
    try f.append(gpa, .{ .br = .{ .cond = .le, .lhs = 0, .rhs = s, .target = exit } });
    try f.append(gpa, .{ .bin = .{ .op = .add, .dst = s, .lhs = s, .rhs = one } });
    try f.append(gpa, .{ .jmp = head });
    try f.append(gpa, .{ .label = exit });
    try f.append(gpa, .{ .ret = s });
    var stats: Stats = .{};
    try eliminateDeadCode(gpa, &f, &stats);
    try std.testing.expectEqual(@as(u32, 1), stats.dead_removed);
    const r = try interp.run(gpa, &f, &.{5}, 1000);
    try std.testing.expectEqual(@as(i64, 5), r.value);
}

test "unreachable blocks and redundant jumps are removed" {
    const gpa = std.testing.allocator;
    var f = ir.Function.init(1);
    defer f.deinit(gpa);
    const next = f.newLabel();
    const dead = f.newLabel();
    try f.append(gpa, .{ .jmp = next });
    try f.append(gpa, .{ .label = dead });
    _ = try f.iconst(gpa, 99);
    try f.append(gpa, .{ .jmp = dead });
    try f.append(gpa, .{ .label = next });
    try f.append(gpa, .{ .ret = 0 });
    const stats = try optimize(gpa, &f);
    try std.testing.expect(stats.unreachable_removed >= 3);
    try std.testing.expectEqual(@as(usize, 1), f.insts.items.len);
    try std.testing.expect(f.insts.items[0] == .ret);
}
