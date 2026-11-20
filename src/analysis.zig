//! Control-flow graph construction and backward liveness analysis.

const std = @import("std");
const ir = @import("ir.zig");

const BitSet = std.bit_set.Dynamic;

pub const no_block = std.math.maxInt(u32);

pub const Block = struct {
    /// Index of the first instruction.
    start: u32,
    /// One past the last instruction.
    end: u32,
    /// Successor block indices; `no_block` marks an unused slot.
    succ: [2]u32 = .{ no_block, no_block },
};

pub const Cfg = struct {
    blocks: []Block,
    /// Block index for each label.
    label_block: []u32,
    /// Block index for each instruction.
    inst_block: []u32,

    /// Builds the CFG of a function that has passed `Function.validate`.
    pub fn build(gpa: std.mem.Allocator, f: *const ir.Function) !Cfg {
        const insts = f.insts.items;
        var blocks: std.ArrayList(Block) = .empty;
        errdefer blocks.deinit(gpa);
        const label_block = try gpa.alloc(u32, f.num_labels);
        errdefer gpa.free(label_block);
        @memset(label_block, no_block);
        const inst_block = try gpa.alloc(u32, insts.len);
        errdefer gpa.free(inst_block);

        var start: u32 = 0;
        for (insts, 0..) |inst, i| {
            const idx: u32 = @intCast(i);
            if (inst == .label and idx != start) {
                try blocks.append(gpa, .{ .start = start, .end = idx });
                start = idx;
            }
            switch (inst) {
                .jmp, .br, .ret => {
                    try blocks.append(gpa, .{ .start = start, .end = idx + 1 });
                    start = idx + 1;
                },
                else => {},
            }
        }
        if (start < insts.len) try blocks.append(gpa, .{ .start = start, .end = @intCast(insts.len) });

        for (blocks.items, 0..) |b, bi| {
            for (b.start..b.end) |i| inst_block[i] = @intCast(bi);
            if (insts[b.start] == .label) label_block[insts[b.start].label] = @intCast(bi);
        }
        const nblocks = blocks.items.len;
        for (blocks.items, 0..) |*b, bi| {
            const next: u32 = if (bi + 1 < nblocks) @intCast(bi + 1) else no_block;
            switch (insts[b.end - 1]) {
                .jmp => |l| b.succ[0] = label_block[l],
                .ret => {},
                .br => |br| {
                    b.succ[0] = label_block[br.target];
                    if (next != label_block[br.target]) b.succ[1] = next;
                },
                else => b.succ[0] = next,
            }
        }
        return .{
            .blocks = try blocks.toOwnedSlice(gpa),
            .label_block = label_block,
            .inst_block = inst_block,
        };
    }

    pub fn deinit(self: *Cfg, gpa: std.mem.Allocator) void {
        gpa.free(self.blocks);
        gpa.free(self.label_block);
        gpa.free(self.inst_block);
        self.* = undefined;
    }

    /// Marks blocks reachable from the entry block.
    pub fn reachable(self: *const Cfg, gpa: std.mem.Allocator) !BitSet {
        var seen = try BitSet.initEmpty(gpa, self.blocks.len);
        errdefer seen.deinit(gpa);
        if (self.blocks.len == 0) return seen;
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, 0);
        seen.set(0);
        while (stack.pop()) |b| {
            for (self.blocks[b].succ) |s| {
                if (s != no_block and !seen.isSet(s)) {
                    seen.set(s);
                    try stack.append(gpa, s);
                }
            }
        }
        return seen;
    }
};

pub const Liveness = struct {
    live_in: []BitSet,
    live_out: []BitSet,

    pub fn compute(gpa: std.mem.Allocator, f: *const ir.Function, cfg: *const Cfg) !Liveness {
        const n = cfg.blocks.len;
        const nv = f.num_vregs;
        var self: Liveness = .{
            .live_in = try gpa.alloc(BitSet, n),
            .live_out = try gpa.alloc(BitSet, n),
        };
        var initialized: usize = 0;
        errdefer {
            for (0..initialized) |i| {
                self.live_in[i].deinit(gpa);
                self.live_out[i].deinit(gpa);
            }
            gpa.free(self.live_in);
            gpa.free(self.live_out);
        }
        const gen = try gpa.alloc(BitSet, n);
        const keep = try gpa.alloc(BitSet, n);
        var gk_init: usize = 0;
        defer {
            for (0..gk_init) |i| {
                gen[i].deinit(gpa);
                keep[i].deinit(gpa);
            }
            gpa.free(gen);
            gpa.free(keep);
        }
        for (0..n) |i| {
            gen[i] = try BitSet.initEmpty(gpa, nv);
            keep[i] = BitSet.initFull(gpa, nv) catch |e| {
                gen[i].deinit(gpa);
                return e;
            };
            gk_init += 1;
            self.live_in[i] = try BitSet.initEmpty(gpa, nv);
            self.live_out[i] = BitSet.initEmpty(gpa, nv) catch |e| {
                self.live_in[i].deinit(gpa);
                return e;
            };
            initialized += 1;
        }

        var buf: [ir.max_call_args]ir.VReg = undefined;
        for (cfg.blocks, 0..) |b, bi| {
            var i = b.end;
            while (i > b.start) {
                i -= 1;
                const inst = &f.insts.items[i];
                if (inst.def()) |d| {
                    gen[bi].unset(d);
                    keep[bi].unset(d);
                }
                for (inst.uses(&buf)) |u| gen[bi].set(u);
            }
        }

        var tmp = try BitSet.initEmpty(gpa, nv);
        defer tmp.deinit(gpa);
        var changed = true;
        while (changed) {
            changed = false;
            var bi = n;
            while (bi > 0) {
                bi -= 1;
                const out = &self.live_out[bi];
                for (cfg.blocks[bi].succ) |s| {
                    if (s != no_block) out.setUnion(self.live_in[s]);
                }
                copyBits(&tmp, out.*);
                tmp.setIntersection(keep[bi]);
                tmp.setUnion(gen[bi]);
                if (!tmp.eql(self.live_in[bi])) {
                    copyBits(&self.live_in[bi], tmp);
                    changed = true;
                }
            }
        }
        return self;
    }

    pub fn deinit(self: *Liveness, gpa: std.mem.Allocator) void {
        for (self.live_in) |*s| s.deinit(gpa);
        for (self.live_out) |*s| s.deinit(gpa);
        gpa.free(self.live_in);
        gpa.free(self.live_out);
        self.* = undefined;
    }
};

fn copyBits(dst: *BitSet, src: BitSet) void {
    dst.unsetAll();
    dst.setUnion(src);
}

pub const UseError = error{UseBeforeDefinition};

/// Rejects programs where some path from the entry reads a virtual register
/// that is neither a parameter nor written earlier on that path. On error,
/// `bad_reg` receives the offending register.
pub fn checkDefinedUses(f: *const ir.Function, live: *const Liveness, bad_reg: ?*ir.VReg) UseError!void {
    if (live.live_in.len == 0) return;
    var it = live.live_in[0].iterator(.{});
    while (it.next()) |v| {
        if (v >= f.num_params) {
            if (bad_reg) |p| p.* = @intCast(v);
            return error.UseBeforeDefinition;
        }
    }
}

/// Convenience wrapper: validates structure and definedness in one call.
pub fn verify(gpa: std.mem.Allocator, f: *const ir.Function) !void {
    try f.validate();
    var cfg = try Cfg.build(gpa, f);
    defer cfg.deinit(gpa);
    var live = try Liveness.compute(gpa, f, &cfg);
    defer live.deinit(gpa);
    try checkDefinedUses(f, &live, null);
}

test "cfg splits blocks at labels and branches" {
    const gpa = std.testing.allocator;
    var f = ir.Function.init(2);
    defer f.deinit(gpa);
    const done = f.newLabel();
    const loop = f.newLabel();
    try f.append(gpa, .{ .label = loop });
    try f.append(gpa, .{ .br = .{ .cond = .ge, .lhs = 0, .rhs = 1, .target = done } });
    const one = try f.iconst(gpa, 1);
    try f.append(gpa, .{ .bin = .{ .op = .add, .dst = 0, .lhs = 0, .rhs = one } });
    try f.append(gpa, .{ .jmp = loop });
    try f.append(gpa, .{ .label = done });
    try f.append(gpa, .{ .ret = 0 });
    try f.validate();

    var cfg = try Cfg.build(gpa, &f);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), cfg.blocks.len);
    try std.testing.expectEqual(@as(u32, 2), cfg.blocks[0].succ[0]);
    try std.testing.expectEqual(@as(u32, 1), cfg.blocks[0].succ[1]);
    try std.testing.expectEqual(@as(u32, 0), cfg.blocks[1].succ[0]);

    var live = try Liveness.compute(gpa, &f, &cfg);
    defer live.deinit(gpa);
    // Both parameters are live around the loop.
    try std.testing.expect(live.live_in[0].isSet(0));
    try std.testing.expect(live.live_in[0].isSet(1));
    try std.testing.expect(live.live_out[1].isSet(1));
    try std.testing.expect(!live.live_out[2].isSet(0));
    try checkDefinedUses(&f, &live, null);
}

test "use before definition on one path is rejected" {
    const gpa = std.testing.allocator;
    var f = ir.Function.init(1);
    defer f.deinit(gpa);
    const skip = f.newLabel();
    const x = f.newVReg();
    try f.append(gpa, .{ .br = .{ .cond = .eq, .lhs = 0, .rhs = 0, .target = skip } });
    try f.append(gpa, .{ .iconst = .{ .dst = x, .value = 3 } });
    try f.append(gpa, .{ .label = skip });
    try f.append(gpa, .{ .ret = x });
    try std.testing.expectError(error.UseBeforeDefinition, verify(gpa, &f));
}
