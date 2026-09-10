const std = @import("std");

pub const Span = struct { text: []const u8, tone: []const u8 = "" };

/// UTF-8-aware rows with optional frames and independently styled text spans.
pub const Panel = struct {
    out: *std.Io.Writer,
    width: usize,
    border_color: []const u8 = "",
    framed: bool = true,
    dotted: bool = false,

    pub fn inner(self: Panel) usize {
        return if (self.framed) self.width - 4 else self.width;
    }

    pub fn border(self: Panel, title: []const u8) !void {
        if (!self.framed) {
            if (title.len > 0) try self.line(title, self.border_color);
            return;
        }
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
        try self.spans(&.{.{ .text = text, .tone = tone }});
    }

    pub fn spans(self: Panel, parts: []const Span) !void {
        const allocator = std.heap.page_allocator;
        const Band = struct { start: usize, end: usize, tone: []const u8 };
        var text: std.Io.Writer.Allocating = .init(allocator);
        defer text.deinit();
        var bands = std.ArrayList(Band).empty;
        defer bands.deinit(allocator);
        for (parts) |part| {
            const safe = try sanitize(allocator, part.text);
            defer allocator.free(safe);
            const start = text.written().len;
            try text.writer.writeAll(safe);
            try bands.append(allocator, .{ .start = start, .end = text.written().len, .tone = part.tone });
        }
        const safe = text.written();
        var start: usize = 0;
        while (true) {
            const remaining = safe[start..];
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
            if (end < remaining.len) {
                if (last_space) |space| end = space;
            }
            const fragment = std.mem.trimEnd(u8, remaining[0..end], " ");
            if (self.framed) {
                try self.color(self.border_color);
                try self.out.writeAll("| ");
                try self.reset(self.border_color);
            }
            for (bands.items) |band| {
                const lo = @max(start, band.start);
                const hi = @min(start + fragment.len, band.end);
                if (lo >= hi) continue;
                try self.color(band.tone);
                try self.out.writeAll(safe[lo..hi]);
                try self.reset(band.tone);
            }
            try repeat(self.out, ' ', self.inner() - displayWidth(fragment));
            if (self.framed) {
                try self.color(self.border_color);
                try self.out.writeAll(" |");
                try self.reset(self.border_color);
            }
            try self.out.writeByte('\n');
            start += end;
            if (start == safe.len) break;
            while (start < safe.len and safe[start] == ' ') start += 1;
            if (start == safe.len) break;
        }
    }

    pub fn columns(self: Panel, left: []const Span, right: []const Span) !void {
        var used: usize = 0;
        for (left) |part| used += displayWidth(part.text);
        for (right) |part| used += displayWidth(part.text);
        if (used + 2 > self.inner()) {
            try self.spans(left);
            try self.spans(right);
            return;
        }
        const allocator = std.heap.page_allocator;
        const padding = try allocator.alloc(u8, self.inner() - used);
        defer allocator.free(padding);
        @memset(padding, ' ');
        var parts = std.ArrayList(Span).empty;
        defer parts.deinit(allocator);
        try parts.appendSlice(allocator, left);
        try parts.append(allocator, .{ .text = padding });
        try parts.appendSlice(allocator, right);
        try self.spans(parts.items);
    }

    pub fn rule(self: Panel, tone: []const u8) !void {
        const allocator = std.heap.page_allocator;
        var text: std.Io.Writer.Allocating = .init(allocator);
        defer text.deinit();
        for (0..self.inner()) |_| try text.writer.writeAll(if (self.dotted) "─" else "-");
        try self.line(text.written(), tone);
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

test "styled spans preserve wrapping and sanitize content independently of color" {
    const allocator = std.testing.allocator;
    var colored_buffer: [4096]u8 = undefined;
    var plain_buffer: [4096]u8 = undefined;
    var colored: std.Io.Writer = .fixed(&colored_buffer);
    var plain: std.Io.Writer = .fixed(&plain_buffer);
    const content = "交易账户 cafe\u{301} / long-unbroken-email@example.com\x1b[31m";
    try (Panel{ .out = &colored, .width = 24, .framed = false }).spans(&.{
        .{ .text = "01  ", .tone = "\x1b[2m" },
        .{ .text = content, .tone = "\x1b[1m\x1b[36m" },
        .{ .text = "  ACTIVE" },
    });
    try (Panel{ .out = &plain, .width = 24, .framed = false }).spans(&.{
        .{ .text = "01  " }, .{ .text = content }, .{ .text = "  ACTIVE" },
    });
    var stripped: std.Io.Writer.Allocating = .init(allocator);
    defer stripped.deinit();
    var offset: usize = 0;
    const bytes = colored.buffered();
    while (offset < bytes.len) : (offset += 1) {
        if (bytes[offset] == 0x1b) {
            while (offset < bytes.len and bytes[offset] != 'm') offset += 1;
        } else try stripped.writer.writeByte(bytes[offset]);
    }
    try std.testing.expectEqualStrings(plain.buffered(), stripped.written());
    try std.testing.expect(std.mem.indexOf(u8, plain.buffered(), "?[31m") != null);
    var lines = std.mem.tokenizeScalar(u8, stripped.written(), '\n');
    while (lines.next()) |line| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
        try std.testing.expectEqual(@as(usize, 24), displayWidth(line));
    }
}
