const std = @import("std");

/// ASCII frames, with UTF-8-aware wrapping for account and workspace names.
pub const Panel = struct {
    out: *std.Io.Writer,
    width: usize,
    border_color: []const u8 = "",

    pub fn inner(self: Panel) usize {
        return self.width - 4;
    }

    pub fn border(self: Panel, title: []const u8) !void {
        try self.color(self.border_color);
        try self.out.writeByte('+');
        const room = self.width - 2;
        if (title.len > 0 and title.len + 4 <= room) {
            try self.out.print("-- {s} ", .{title});
            try repeat(self.out, '-', room - title.len - 4);
        } else try repeat(self.out, '-', room);
        try self.out.writeAll("+");
        try self.reset(self.border_color);
        try self.out.writeByte('\n');
        if (title.len + 4 > room and title.len > 0) try self.line(title, self.border_color);
    }

    pub fn line(self: Panel, text: []const u8, tone: []const u8) !void {
        const allocator = std.heap.page_allocator;
        const safe = try sanitize(allocator, text);
        defer allocator.free(safe);
        var remaining: []const u8 = safe;
        while (true) {
            var end: usize = 0;
            var cells: usize = 0;
            var last_space: ?usize = null;
            var it = (try std.unicode.Utf8View.init(remaining)).iterator();
            while (it.nextCodepointSlice()) |part| {
                const cp = std.unicode.utf8Decode(part) catch unreachable;
                const n = cellWidth(cp);
                if (cells + n > self.inner()) break;
                if (cp == ' ' and end > 0) last_space = end;
                end += part.len;
                cells += n;
            }
            // Wrap at word boundaries; split long identifiers only between code points.
            if (end < remaining.len) {
                if (last_space) |space| end = space;
            }
            const fragment = std.mem.trimEnd(u8, remaining[0..end], " ");
            try self.color(self.border_color);
            try self.out.writeAll("| ");
            try self.reset(self.border_color);
            try self.color(tone);
            try self.out.writeAll(fragment);
            try self.reset(tone);
            try repeat(self.out, ' ', self.inner() - displayWidth(fragment));
            try self.color(self.border_color);
            try self.out.writeAll(" |");
            try self.reset(self.border_color);
            try self.out.writeByte('\n');
            if (end == remaining.len) break;
            remaining = std.mem.trimStart(u8, remaining[end..], " ");
            if (remaining.len == 0) break;
        }
    }

    fn color(self: Panel, tone: []const u8) !void {
        if (tone.len > 0) try self.out.writeAll(tone);
    }

    fn reset(self: Panel, tone: []const u8) !void {
        if (tone.len > 0) try self.out.writeAll("\x1b[0m");
    }
};

fn repeat(out: *std.Io.Writer, ch: u8, count: usize) !void {
    for (0..count) |_| try out.writeByte(ch);
}

fn sanitize(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var offset: usize = 0;
    while (offset < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
        const end = @min(text.len, offset + len);
        const cp = std.unicode.utf8Decode(text[offset..end]) catch 0;
        if (cp < 32 or (cp >= 127 and cp < 160)) {
            try out.writer.writeByte('?');
        } else try out.writer.writeAll(text[offset..end]);
        offset = end;
    }
    return out.toOwnedSlice();
}

pub fn displayWidth(text: []const u8) usize {
    var it = (std.unicode.Utf8View.init(text) catch return text.len).iterator();
    var width: usize = 0;
    while (it.nextCodepoint()) |cp| width += cellWidth(cp);
    return width;
}

fn cellWidth(cp: u21) usize {
    // Combining accents, variation selectors, and joiners occupy no extra cells.
    if ((cp >= 0x0300 and cp <= 0x036f) or (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or (cp >= 0xfe00 and cp <= 0xfe0f) or cp == 0x200d) return 0;
    if ((cp >= 0x1100 and cp <= 0x115f) or (cp >= 0x2e80 and cp <= 0xa4cf) or
        (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe10 and cp <= 0xfe6f) or (cp >= 0xff01 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or (cp >= 0x1f300 and cp <= 0x1faff) or
        (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

test "pixel panels wrap long UTF-8 names and neutralize terminal control characters" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const panel = Panel{ .out = &writer, .width = 40 };
    try panel.border("[01] * ACTIVE / Pro");
    try panel.line("交易账户 cafe\u{301} / very-long-account-name-without-spaces@example.com", "");
    try panel.line("untrusted\x1b[31m\nname", "");
    try panel.border("");
    var lines = std.mem.tokenizeScalar(u8, writer.buffered(), '\n');
    while (lines.next()) |line| {
        try std.testing.expectEqual(@as(usize, 40), displayWidth(line));
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    }
    try std.testing.expect(std.mem.indexOfScalar(u8, writer.buffered(), 0x1b) == null);
}
