//! Parser for the textual IR used by the command line tool.
//!
//!     # comments start with '#' or '//'
//!     fn sum_squares(n) {
//!         s = 0                    # same as: s = const 0
//!         i = 0
//!     loop:
//!         br ge i, n, done
//!         t = mul i, i
//!         s = add s, t
//!         i = add i, 1             # integer operands are allowed anywhere
//!         jmp loop
//!     done:
//!         r = call max(s, 1)
//!         ret r
//!     }
//!
//! Statements: `x = const K`, `x = mov y`, `x = y`, `x = K`,
//! `x = <binop> a, b` (add sub mul and or xor shl shr sar),
//! `x = <cond> a, b` (eq ne lt le gt ge ult ule ugt uge; yields 0 or 1),
//! `x = call name(args...)`, `label:`, `jmp label`,
//! `br <cond> a, b, label` and `ret a`.

const std = @import("std");
const ir = @import("ir.zig");
const analysis = @import("analysis.zig");

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
    /// Offending identifier, when there is one (points into the source).
    name: []const u8 = "",
};

pub const Parsed = struct {
    func: ir.Function,
    name: []const u8,
    /// Source name of each virtual register; empty for literal temporaries.
    vreg_names: [][]const u8,

    pub fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        self.func.deinit(gpa);
        gpa.free(self.vreg_names);
        self.* = undefined;
    }
};

pub const Error = error{ SyntaxError, OutOfMemory };

const max_line_tokens = 32;

const Token = union(enum) {
    ident: []const u8,
    int: i64,
    punct: u8,
};

fn tokenize(line: []const u8, out: *[max_line_tokens]Token, diag: *Diagnostic) Error![]Token {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }
        if (n == max_line_tokens) return fail(diag, "line has too many tokens", "");
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const s = i;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_' or line[i] == '.')) i += 1;
            out[n] = .{ .ident = line[s..i] };
        } else if (std.ascii.isDigit(c) or (c == '-' and i + 1 < line.len and std.ascii.isDigit(line[i + 1]))) {
            const s = i;
            i += 1;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
            out[n] = .{ .int = parseInt(line[s..i]) orelse return fail(diag, "invalid or out-of-range integer", line[s..i]) };
        } else if (std.mem.indexOfScalar(u8, "(),=:{}", c) != null) {
            out[n] = .{ .punct = c };
            i += 1;
        } else {
            return fail(diag, "unexpected character", line[i .. i + 1]);
        }
        n += 1;
    }
    return out[0..n];
}

fn parseInt(text: []const u8) ?i64 {
    const neg = text[0] == '-';
    const body = if (neg) text[1..] else text;
    if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) {
        const u = std.fmt.parseInt(u64, body[2..], 16) catch return null;
        const v: i64 = @bitCast(u);
        return if (neg) 0 -% v else v;
    }
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn fail(diag: *Diagnostic, message: []const u8, name: []const u8) Error {
    diag.message = message;
    diag.name = name;
    return error.SyntaxError;
}

const Parser = struct {
    gpa: std.mem.Allocator,
    diag: *Diagnostic,
    f: ir.Function,
    names: std.StringHashMapUnmanaged(ir.VReg) = .empty,
    vreg_names: std.ArrayList([]const u8) = .empty,
    labels: std.StringHashMapUnmanaged(ir.Label) = .empty,
    label_names: std.ArrayList([]const u8) = .empty,
    label_defined: std.ArrayList(bool) = .empty,
    label_first_use: std.ArrayList(usize) = .empty,
    hosts: []const ir.HostFn,
    line_no: usize = 0,

    fn deinitScratch(p: *Parser) void {
        p.names.deinit(p.gpa);
        p.labels.deinit(p.gpa);
        p.label_names.deinit(p.gpa);
        p.label_defined.deinit(p.gpa);
        p.label_first_use.deinit(p.gpa);
    }

    fn newVReg(p: *Parser, name: []const u8) Error!ir.VReg {
        if (p.f.num_vregs >= ir.max_vregs) return fail(p.diag, "too many registers", "");
        const v = p.f.newVReg();
        try p.vreg_names.append(p.gpa, name);
        return v;
    }

    fn variable(p: *Parser, name: []const u8) Error!ir.VReg {
        if (p.names.get(name)) |v| return v;
        const v = try p.newVReg(name);
        try p.names.put(p.gpa, name, v);
        return v;
    }

    fn label(p: *Parser, name: []const u8) Error!ir.Label {
        if (p.labels.get(name)) |l| return l;
        if (p.f.num_labels >= ir.max_labels) return fail(p.diag, "too many labels", "");
        const l = p.f.newLabel();
        try p.labels.put(p.gpa, name, l);
        try p.label_names.append(p.gpa, name);
        try p.label_defined.append(p.gpa, false);
        try p.label_first_use.append(p.gpa, p.line_no);
        return l;
    }

    fn emit(p: *Parser, inst: ir.Inst) Error!void {
        if (p.f.insts.items.len >= ir.max_insts) return fail(p.diag, "too many instructions", "");
        try p.f.append(p.gpa, inst);
    }

    /// An operand: a variable name or an integer literal (materialized into
    /// a fresh temporary).
    fn operand(p: *Parser, t: Token) Error!ir.VReg {
        switch (t) {
            .ident => |name| return p.variable(name),
            .int => |k| {
                const v = try p.newVReg("");
                try p.emit(.{ .iconst = .{ .dst = v, .value = k } });
                return v;
            },
            .punct => return fail(p.diag, "expected a variable or integer", ""),
        }
    }

    fn statement(p: *Parser, toks: []const Token) Error!void {
        if (toks.len == 2 and toks[0] == .ident and isPunct(toks[1], ':')) {
            const l = try p.label(toks[0].ident);
            if (p.label_defined.items[l]) return fail(p.diag, "duplicate label", toks[0].ident);
            p.label_defined.items[l] = true;
            return p.emit(.{ .label = l });
        }
        if (toks[0] != .ident) return fail(p.diag, "expected a statement", "");
        const head = toks[0].ident;
        if (std.mem.eql(u8, head, "jmp")) {
            if (toks.len != 2 or toks[1] != .ident) return fail(p.diag, "expected: jmp <label>", "");
            return p.emit(.{ .jmp = try p.label(toks[1].ident) });
        }
        if (std.mem.eql(u8, head, "ret")) {
            if (toks.len != 2) return fail(p.diag, "expected: ret <value>", "");
            return p.emit(.{ .ret = try p.operand(toks[1]) });
        }
        if (std.mem.eql(u8, head, "br")) {
            // br <cond> a , b , label
            if (toks.len != 7 or toks[1] != .ident or !isPunct(toks[3], ',') or !isPunct(toks[5], ',') or toks[6] != .ident)
                return fail(p.diag, "expected: br <cond> a, b, <label>", "");
            const cond = std.meta.stringToEnum(ir.Cond, toks[1].ident) orelse return fail(p.diag, "unknown condition", toks[1].ident);
            const a = try p.operand(toks[2]);
            const b = try p.operand(toks[4]);
            return p.emit(.{ .br = .{ .cond = cond, .lhs = a, .rhs = b, .target = try p.label(toks[6].ident) } });
        }
        if (toks.len < 3 or !isPunct(toks[1], '=')) return fail(p.diag, "expected an assignment, label, jmp, br or ret", head);
        const rhs = toks[2..];
        if (rhs.len == 1) {
            // x = y  |  x = 5
            switch (rhs[0]) {
                .int => |k| return p.emit(.{ .iconst = .{ .dst = try p.variable(head), .value = k } }),
                .ident => |src| {
                    const s = try p.variable(src);
                    return p.emit(.{ .mov = .{ .dst = try p.variable(head), .src = s } });
                },
                .punct => return fail(p.diag, "expected a value", ""),
            }
        }
        if (rhs[0] != .ident) return fail(p.diag, "expected an operation", "");
        const op = rhs[0].ident;
        if (std.mem.eql(u8, op, "const")) {
            if (rhs.len != 2 or rhs[1] != .int) return fail(p.diag, "expected: const <integer>", "");
            return p.emit(.{ .iconst = .{ .dst = try p.variable(head), .value = rhs[1].int } });
        }
        if (std.mem.eql(u8, op, "mov")) {
            if (rhs.len != 2) return fail(p.diag, "expected: mov <value>", "");
            const s = try p.operand(rhs[1]);
            return p.emit(.{ .mov = .{ .dst = try p.variable(head), .src = s } });
        }
        if (std.mem.eql(u8, op, "call")) return p.call(head, rhs[1..]);
        if (rhs.len != 4 or !isPunct(rhs[2], ',')) return fail(p.diag, "expected: <op> a, b", op);
        if (std.meta.stringToEnum(ir.BinOp, op)) |bop| {
            const a = try p.operand(rhs[1]);
            const b = try p.operand(rhs[3]);
            return p.emit(.{ .bin = .{ .op = bop, .dst = try p.variable(head), .lhs = a, .rhs = b } });
        }
        if (std.meta.stringToEnum(ir.Cond, op)) |cond| {
            const a = try p.operand(rhs[1]);
            const b = try p.operand(rhs[3]);
            return p.emit(.{ .cmp = .{ .cond = cond, .dst = try p.variable(head), .lhs = a, .rhs = b } });
        }
        return fail(p.diag, "unknown operation", op);
    }

    fn call(p: *Parser, dst_name: []const u8, toks: []const Token) Error!void {
        // name ( [a {, a}] )
        if (toks.len < 3 or toks[0] != .ident or !isPunct(toks[1], '(') or !isPunct(toks[toks.len - 1], ')'))
            return fail(p.diag, "expected: call name(args...)", "");
        const name = toks[0].ident;
        var callee: ?u32 = null;
        for (p.hosts, 0..) |h, i| {
            if (std.mem.eql(u8, h.name, name)) callee = @intCast(i);
        }
        const ci = callee orelse return fail(p.diag, "unknown function", name);
        var args: [ir.max_call_args]ir.VReg = @splat(0);
        var argc: usize = 0;
        const inner = toks[2 .. toks.len - 1];
        var i: usize = 0;
        while (i < inner.len) {
            if (argc == ir.max_call_args) return fail(p.diag, "too many call arguments", name);
            args[argc] = try p.operand(inner[i]);
            argc += 1;
            i += 1;
            if (i < inner.len) {
                if (!isPunct(inner[i], ',') or i + 1 == inner.len) return fail(p.diag, "expected ',' between arguments", "");
                i += 1;
            }
        }
        if (argc != p.hosts[ci].arity) return fail(p.diag, "wrong number of arguments", name);
        return p.emit(.{ .call = .{ .dst = try p.variable(dst_name), .callee = ci, .argc = @intCast(argc), .args = args } });
    }
};

fn isPunct(t: Token, c: u8) bool {
    return t == .punct and t.punct == c;
}

fn stripComment(line: []const u8) []const u8 {
    var end = line.len;
    if (std.mem.indexOfScalar(u8, line, '#')) |i| end = @min(end, i);
    if (std.mem.indexOf(u8, line, "//")) |i| end = @min(end, i);
    return std.mem.trim(u8, line[0..end], " \t\r");
}

/// Parses one function. On `error.SyntaxError`, `diag` describes the problem.
pub fn parse(gpa: std.mem.Allocator, source: []const u8, hosts: []const ir.HostFn, diag: *Diagnostic) Error!Parsed {
    diag.* = .{};
    var p: Parser = .{ .gpa = gpa, .diag = diag, .f = ir.Function.init(0), .hosts = hosts };
    defer p.deinitScratch();
    errdefer {
        p.f.deinit(gpa);
        p.vreg_names.deinit(gpa);
    }
    p.f.hosts = hosts;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var state: enum { header, body, done } = .header;
    var fn_name: []const u8 = "";
    var toks_buf: [max_line_tokens]Token = undefined;
    while (lines.next()) |raw| {
        p.line_no += 1;
        diag.line = p.line_no;
        const line = stripComment(raw);
        if (line.len == 0) continue;
        const toks = try tokenize(line, &toks_buf, diag);
        switch (state) {
            .header => {
                // fn name ( params ) {
                if (toks.len < 5 or toks[0] != .ident or !std.mem.eql(u8, toks[0].ident, "fn") or toks[1] != .ident or
                    !isPunct(toks[2], '(') or !isPunct(toks[toks.len - 1], '{') or !isPunct(toks[toks.len - 2], ')'))
                    return fail(diag, "expected: fn name(params) {", "");
                fn_name = toks[1].ident;
                const params = toks[3 .. toks.len - 2];
                var i: usize = 0;
                while (i < params.len) {
                    if (params[i] != .ident) return fail(diag, "expected a parameter name", "");
                    const name = params[i].ident;
                    if (p.names.contains(name)) return fail(diag, "duplicate parameter", name);
                    if (p.f.num_params == ir.max_params) return fail(diag, "too many parameters (at most 6)", name);
                    p.f.num_params += 1;
                    _ = try p.variable(name);
                    i += 1;
                    if (i < params.len) {
                        if (!isPunct(params[i], ',') or i + 1 == params.len) return fail(diag, "expected ',' between parameters", "");
                        i += 1;
                    }
                }
                state = .body;
            },
            .body => {
                if (toks.len == 1 and isPunct(toks[0], '}')) {
                    state = .done;
                    continue;
                }
                try p.statement(toks);
            },
            .done => return fail(diag, "unexpected text after the closing '}'", ""),
        }
    }
    if (state != .done) {
        diag.line = 0;
        return fail(diag, if (state == .header) "missing function header" else "missing closing '}'", "");
    }

    for (p.label_defined.items, 0..) |defined, l| {
        if (!defined) {
            diag.line = p.label_first_use.items[l];
            return fail(diag, "undefined label", p.label_names.items[l]);
        }
    }
    p.f.validate() catch |e| {
        diag.line = 0;
        return fail(diag, switch (e) {
            error.MissingTerminator => "the function can run past its last statement (end it with ret or jmp)",
            else => "invalid function",
        }, "");
    };
    var cfg = try analysis.Cfg.build(gpa, &p.f);
    defer cfg.deinit(gpa);
    var live = try analysis.Liveness.compute(gpa, &p.f, &cfg);
    defer live.deinit(gpa);
    var bad: ir.VReg = 0;
    analysis.checkDefinedUses(&p.f, &live, &bad) catch {
        diag.line = 0;
        return fail(diag, "variable may be used before it is assigned", p.vreg_names.items[bad]);
    };
    return .{ .func = p.f, .name = fn_name, .vreg_names = try p.vreg_names.toOwnedSlice(gpa) };
}

const interp = @import("interp.zig");
const compiler = @import("compiler.zig");

test "parse and run a program with loops, literals and calls" {
    const gpa = std.testing.allocator;
    const src =
        \\# sum of squares below n, at least 1
        \\fn sum_squares(n) {
        \\    s = 0
        \\    i = const 0
        \\loop:
        \\    br ge i, n, done      // exit test
        \\    t = mul i, i
        \\    s = add s, t
        \\    i = add i, 1
        \\    jmp loop
        \\done:
        \\    r = call max(s, 1)
        \\    ret r
        \\}
    ;
    var diag: Diagnostic = .{};
    var p = try parse(gpa, src, &compiler.builtin_hosts, &diag);
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("sum_squares", p.name);
    try std.testing.expectEqual(@as(u8, 1), p.func.num_params);
    try std.testing.expectEqual(@as(i64, 285), (try interp.run(gpa, &p.func, &.{10}, 10_000)).value);
    try std.testing.expectEqual(@as(i64, 1), (try interp.run(gpa, &p.func, &.{-3}, 10_000)).value);
}

test "parser accepts hex, negative and boundary literals" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var p = try parse(gpa, "fn f() {\n a = 0xFFFFFFFFFFFFFFFF\n b = -9223372036854775808\n c = xor a, b\n d = sub c, -0x10\n ret d\n}\n", &.{}, &diag);
    defer p.deinit(gpa);
    const want: i64 = (@as(i64, -1) ^ std.math.minInt(i64)) +% 16;
    try std.testing.expectEqual(want, (try interp.run(gpa, &p.func, &.{}, 100)).value);
}

test "parser reports precise diagnostics for hostile input" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { src: []const u8, line: usize, msg: []const u8 }{
        .{ .src = "", .line = 0, .msg = "missing function header" },
        .{ .src = "fn f(a) {\n ret a\n", .line = 0, .msg = "missing closing '}'" },
        .{ .src = "fn f(a, a) {\n ret a\n}", .line = 1, .msg = "duplicate parameter" },
        .{ .src = "fn f(a,b,c,d,e,g,h) {\n ret a\n}", .line = 1, .msg = "too many parameters (at most 6)" },
        .{ .src = "fn f(a) {\n x = frob a, a\n ret x\n}", .line = 2, .msg = "unknown operation" },
        .{ .src = "fn f(a) {\n jmp nowhere\n}", .line = 2, .msg = "undefined label" },
        .{ .src = "fn f(a) {\nl:\nl:\n ret a\n}", .line = 3, .msg = "duplicate label" },
        .{ .src = "fn f(a) {\n x = 99999999999999999999\n ret x\n}", .line = 2, .msg = "invalid or out-of-range integer" },
        .{ .src = "fn f(a) {\n x = call nope(a)\n ret x\n}", .line = 2, .msg = "unknown function" },
        .{ .src = "fn f(a) {\n x = call max(a)\n ret x\n}", .line = 2, .msg = "wrong number of arguments" },
        .{ .src = "fn f(a) {\n x = add a, a\n}", .line = 0, .msg = "the function can run past its last statement (end it with ret or jmp)" },
        .{ .src = "fn f(a) {\n br eq a, 0, skip\n y = 1\nskip:\n ret y\n}", .line = 0, .msg = "variable may be used before it is assigned" },
        .{ .src = "fn f(a) {\n x = a $ 1\n ret x\n}", .line = 2, .msg = "unexpected character" },
        .{ .src = "fn f(a) {\n ret a\n}\nextra", .line = 4, .msg = "unexpected text after the closing '}'" },
        .{ .src = "fn f(a) {\n br xx a, a, l\nl:\n ret a\n}", .line = 2, .msg = "unknown condition" },
        .{ .src = "fn f(a) {\n x = call max(a,, a)\n ret x\n}", .line = 2, .msg = "expected a variable or integer" },
    };
    for (cases) |c| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.SyntaxError, parse(gpa, c.src, &compiler.builtin_hosts, &diag));
        std.testing.expectEqualStrings(c.msg, diag.message) catch |e| {
            std.debug.print("source: {s}\n", .{c.src});
            return e;
        };
        try std.testing.expectEqual(c.line, diag.line);
    }
}

test "parser survives random byte soup" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    const alphabet = "fn(){}=,:# \n\tabcxyz0123456789-retjmpbrlteqaddmulcall";
    var buf: [256]u8 = undefined;
    for (0..3000) |k| {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = if (k % 3 == 0) rnd.int(u8) else alphabet[rnd.uintLessThan(usize, alphabet.len)];
        var diag: Diagnostic = .{};
        var p = parse(gpa, buf[0..len], &compiler.builtin_hosts, &diag) catch continue;
        // Anything that parses must also verify and compile.
        defer p.deinit(gpa);
        try analysis.verify(gpa, &p.func);
        var c = try compiler.compile(gpa, &p.func, .{ .arch = .aarch64 });
        c.deinit(gpa);
    }
}
