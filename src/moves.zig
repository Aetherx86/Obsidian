//! Parallel move resolution. Used for parameter entry moves and for
//! placing call arguments, where the destination registers may also be
//! sources of other moves in the same group.

const std = @import("std");
const Loc = @import("regalloc.zig").Loc;

pub const Move = struct { dst: Loc, src: Loc };

/// Emits `moves` so that every destination receives the value its source
/// held before any move ran. Destinations must be distinct. Cycles are broken
/// through the `scratch` register, which must not appear in any move.
/// `ctx.move(dst, src)` performs a single move (including memory to memory).
pub fn resolve(moves_in: []const Move, scratch: u8, ctx: anytype) !void {
    var buf: [16]Move = undefined;
    std.debug.assert(moves_in.len <= buf.len);
    var n: usize = 0;
    for (moves_in) |m| {
        if (m.dst.eql(m.src) or m.src == .none or m.dst == .none) continue;
        buf[n] = m;
        n += 1;
    }
    const scratch_loc: Loc = .{ .reg = scratch };
    while (n > 0) {
        var emitted = false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var blocked = false;
            for (buf[0..n], 0..) |other, j| {
                if (j != i and other.src.eql(buf[i].dst)) {
                    blocked = true;
                    break;
                }
            }
            if (!blocked) {
                try ctx.move(buf[i].dst, buf[i].src);
                buf[i] = buf[n - 1];
                n -= 1;
                emitted = true;
                break;
            }
        }
        if (emitted) continue;
        // Every pending destination is still needed as a source: a cycle.
        const d = buf[0].dst;
        try ctx.move(scratch_loc, d);
        for (buf[0..n]) |*m| {
            if (m.src.eql(d)) m.src = scratch_loc;
        }
    }
}

const Sim = struct {
    regs: [8]i64,
    count: usize = 0,

    fn move(self: *Sim, dst: Loc, src: Loc) !void {
        self.regs[dst.reg] = self.regs[src.reg];
        self.count += 1;
    }
};

test "parallel moves handle chains and cycles" {
    // r0 <- r1, r1 <- r2, r2 <- r0 (cycle) and r3 <- r0 (fan out), r4 <- r4.
    var sim: Sim = .{ .regs = .{ 10, 11, 12, 13, 14, 15, 16, 0 } };
    const moves = [_]Move{
        .{ .dst = .{ .reg = 0 }, .src = .{ .reg = 1 } },
        .{ .dst = .{ .reg = 1 }, .src = .{ .reg = 2 } },
        .{ .dst = .{ .reg = 2 }, .src = .{ .reg = 0 } },
        .{ .dst = .{ .reg = 3 }, .src = .{ .reg = 0 } },
        .{ .dst = .{ .reg = 4 }, .src = .{ .reg = 4 } },
    };
    try resolve(&moves, 7, &sim);
    try std.testing.expectEqual(@as(i64, 11), sim.regs[0]);
    try std.testing.expectEqual(@as(i64, 12), sim.regs[1]);
    try std.testing.expectEqual(@as(i64, 10), sim.regs[2]);
    try std.testing.expectEqual(@as(i64, 10), sim.regs[3]);
    try std.testing.expectEqual(@as(i64, 14), sim.regs[4]);
    try std.testing.expectEqual(@as(usize, 5), sim.count);
}

test "parallel moves: random permutations" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    for (0..500) |_| {
        var sim: Sim = .{ .regs = .{ 0, 1, 2, 3, 4, 5, 6, -1 } };
        var perm = [_]u8{ 0, 1, 2, 3, 4, 5, 6 };
        rnd.shuffle(u8, &perm);
        var moves: [7]Move = undefined;
        const n = rnd.intRangeAtMost(usize, 1, 7);
        // Destinations are distinct; sources are arbitrary registers.
        for (0..n) |k| moves[k] = .{ .dst = .{ .reg = perm[k] }, .src = .{ .reg = rnd.uintLessThan(u8, 7) } };
        try resolve(moves[0..n], 7, &sim);
        for (moves[0..n]) |m| try std.testing.expectEqual(@as(i64, m.src.reg), sim.regs[m.dst.reg]);
        for (perm[n..]) |r| try std.testing.expectEqual(@as(i64, r), sim.regs[r]);
    }
}
