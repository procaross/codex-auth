const std = @import("std");
const pixel = @import("pixel.zig");

pub const Layout = struct {
    columns: usize,
    side_by_side: bool,
    gap: usize = 4,

    pub fn forWidth(width: usize) Layout {
        return .{
            .columns = if (width >= 148) 64 else if (width >= 132) 56 else if (width >= 112) 48 else if (width >= 96) 40 else if (width >= 80) 32 else if (width >= 56) 48 else if (width >= 40) 32 else 20,
            .side_by_side = width >= 80,
        };
    }

    pub fn infoWidth(self: Layout, width: usize) usize {
        return if (self.side_by_side) width - self.columns - self.gap else width;
    }
};

pub fn artwork(columns: usize) []const u8 {
    return switch (columns) {
        20 => @embedFile("assets/portrait-20.txt"),
        32 => @embedFile("assets/portrait-32.txt"),
        40 => @embedFile("assets/portrait-40.txt"),
        48 => @embedFile("assets/portrait-48.txt"),
        56 => @embedFile("assets/portrait-56.txt"),
        64 => @embedFile("assets/portrait-64.txt"),
        else => unreachable,
    };
}

/// Compose trusted, pre-rendered information beside a deterministic UTF-8 asset.
/// No cursor movements, image protocols, or background-color changes are needed.
pub fn write(out: *std.Io.Writer, information: []const u8, width: usize, color: bool) !void {
    const layout = Layout.forWidth(width);
    var art = std.mem.splitScalar(u8, std.mem.trimEnd(u8, artwork(layout.columns), "\n"), '\n');
    if (!layout.side_by_side) {
        while (art.next()) |line| {
            try spaces(out, (width - layout.columns) / 2);
            try writeArt(out, line, color);
            try out.writeByte('\n');
        }
        try out.writeByte('\n');
        try out.writeAll(information);
        return;
    }
    var info = std.mem.splitScalar(u8, std.mem.trimEnd(u8, information, "\n"), '\n');
    while (true) {
        const drawing = art.next();
        const content = info.next();
        if (drawing == null and content == null) break;
        if (drawing) |line| {
            try writeArt(out, line, color);
            try spaces(out, layout.columns - pixel.displayWidth(line));
        } else try spaces(out, layout.columns);
        if (content) |line| {
            try spaces(out, layout.gap);
            try out.writeAll(line);
        }
        try out.writeByte('\n');
    }
}

fn writeArt(out: *std.Io.Writer, line: []const u8, color: bool) !void {
    if (color) try out.writeAll("\x1b[38;2;8;131;153m");
    try out.writeAll(line);
    if (color) try out.writeAll("\x1b[0m");
}

fn spaces(out: *std.Io.Writer, count: usize) !void {
    for (0..count) |_| try out.writeByte(' ');
}

test "portrait assets fit their Braille grid at all supported resolutions" {
    for ([_]usize{ 20, 32, 40, 48, 56, 64 }) |columns| {
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, artwork(columns), "\n"), '\n');
        var rows: usize = 0;
        while (lines.next()) |line| {
            rows += 1;
            try std.testing.expect(pixel.displayWidth(line) <= columns);
            var points = (try std.unicode.Utf8View.init(line)).iterator();
            while (points.nextCodepoint()) |cp| try std.testing.expect(cp == ' ' or (cp >= 0x2800 and cp <= 0x28ff));
        }
        try std.testing.expectEqual(columns / 2, rows);
    }
}

test "portrait layout preserves all information when either column is longer" {
    for ([_]usize{ 24, 40, 80, 96, 112, 132, 160 }) |width| {
        var buffer: [16384]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try write(&out, "first\nlast\n", width, false);
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "last") != null);
        var lines = std.mem.tokenizeScalar(u8, out.buffered(), '\n');
        while (lines.next()) |line| try std.testing.expect(pixel.displayWidth(line) <= width);
        var longer: std.Io.Writer = .fixed(&buffer);
        try write(&longer, "row\n" ** 40 ++ "final\n", width, false);
        try std.testing.expect(std.mem.indexOf(u8, longer.buffered(), "final") != null);
    }
}
