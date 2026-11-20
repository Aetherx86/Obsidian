//! Annotated machine-code listings: every emitted machine instruction is
//! recorded with its offset, length and assembler text, interleaved with
//! the IR instruction it was generated from.

const std = @import("std");

pub const Kind = enum { ir, insn };

pub const Line = struct {
    kind: Kind,
    offset: u32,
    len: u32,
    text_start: u32,
    text_end: u32,
};

pub const Listing = struct {
    gpa: std.mem.Allocator,
    lines: std.ArrayList(Line) = .empty,
    text: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Listing {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Listing) void {
        self.lines.deinit(self.gpa);
        self.text.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn add(self: *Listing, kind: Kind, offset: usize, len: usize, comptime fmt: []const u8, args: anytype) !void {
        var buf: [160]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        const start: u32 = @intCast(self.text.items.len);
        try self.text.appendSlice(self.gpa, s);
        try self.lines.append(self.gpa, .{
            .kind = kind,
            .offset = @intCast(offset),
            .len = @intCast(len),
            .text_start = start,
            .text_end = @intCast(self.text.items.len),
        });
    }

    pub fn lineText(self: *const Listing, line: Line) []const u8 {
        return self.text.items[line.text_start..line.text_end];
    }

    /// Writes a disassembly-style listing: offset, raw bytes, mnemonic.
    pub fn render(self: *const Listing, code: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.lines.items) |line| {
            switch (line.kind) {
                .ir => try w.print("                                   ; {s}\n", .{self.lineText(line)}),
                .insn => {
                    try w.print("  {x:0>4}:  ", .{line.offset});
                    var col: usize = 0;
                    var i: usize = 0;
                    while (i < line.len) : (i += 1) {
                        // Long encodings (movabs) wrap so the text column stays aligned.
                        if (i != 0 and i % 10 == 0) {
                            try w.writeAll("\n         ");
                            col = 0;
                        }
                        try w.print("{x:0>2} ", .{code[line.offset + i]});
                        col += 3;
                    }
                    try w.splatByteAll(' ', 31 - col);
                    try w.print("{s}\n", .{self.lineText(line)});
                },
            }
        }
    }
};
