const std = @import("std");
const builtin = @import("builtin");
const display_rows = @import("display_rows.zig");
const registry = @import("registry.zig");
const io_util = @import("io_util.zig");
const timefmt = @import("timefmt.zig");
const subscription = @import("subscription.zig");
const pixel = @import("pixel.zig");
const portrait = @import("portrait.zig");
const c = @cImport({
    @cInclude("time.h");
});

const ansi = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const green = "\x1b[32m";
    const bold = "\x1b[1m";
    const teal = "\x1b[38;2;8;131;153m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
};

fn colorEnabled() bool {
    return std.fs.File.stdout().isTty() and !std.process.hasEnvVarConstant("NO_COLOR") and !plainTerminal();
}

fn plainTerminal() bool {
    const allocator = std.heap.page_allocator;
    const term = std.process.getEnvVarOwned(allocator, "TERM") catch return false;
    defer allocator.free(term);
    return std.mem.eql(u8, term, "dumb");
}

fn planDisplay(rec: *const registry.AccountRecord, missing: []const u8) []const u8 {
    if (registry.resolveDisplayPlan(rec)) |p| return registry.planLabel(p);
    return missing;
}

pub fn printAccounts(reg: *registry.Registry) !void {
    try printAccountsWithUsageOverrides(reg, null);
}

pub fn printAccountsWithUsageOverrides(
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
) !void {
    try printAccountsTable(reg, usage_overrides);
}

fn printAccountsTable(reg: *registry.Registry, usage_overrides: ?[]const ?[]const u8) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeAccountsTableWithUsageOverrides(out, reg, colorEnabled(), usage_overrides);
    try out.flush();
}

fn writeAccountsTable(out: *std.Io.Writer, reg: *registry.Registry, use_color: bool) !void {
    try writeAccountsTableWithUsageOverrides(out, reg, use_color, null);
}

fn usageOverrideForAccount(
    usage_overrides: ?[]const ?[]const u8,
    account_idx: usize,
) ?[]const u8 {
    const overrides = usage_overrides orelse return null;
    if (account_idx >= overrides.len) return null;
    return overrides[account_idx];
}

fn writeAccountsTableWithUsageOverrides(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    use_color: bool,
    usage_overrides: ?[]const ?[]const u8,
) !void {
    try writeAccountsTableWithSubscriptions(out, reg, use_color, usage_overrides, null);
}

pub fn printAccountsWithSubscriptions(
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
    snapshots: []const subscription.Snapshot,
) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    try writeAccountsTableWithSubscriptions(stdout.out(), reg, colorEnabled(), usage_overrides, snapshots);
    try stdout.out().flush();
}

fn writeAccountsTableWithSubscriptions(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    use_color: bool,
    usage_overrides: ?[]const ?[]const u8,
    snapshots: ?[]const subscription.Snapshot,
) !void {
    if (plainTerminal()) {
        try writeAccountDetails(out, reg, false, usage_overrides, snapshots, 80, false);
    } else try writeAccountPanels(out, reg, use_color, usage_overrides, snapshots, terminalWidth());
}

fn writeAccountPanels(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    use_color: bool,
    usage_overrides: ?[]const ?[]const u8,
    snapshots: ?[]const subscription.Snapshot,
    terminal_columns: usize,
) !void {
    const allocator = std.heap.page_allocator;
    const width = @max(@as(usize, 24), @min(@as(usize, 160), if (terminal_columns == 0) 128 else terminal_columns));
    var information: std.Io.Writer.Allocating = .init(allocator);
    defer information.deinit();
    try writeAccountDetails(&information.writer, reg, use_color, usage_overrides, snapshots, portrait.Layout.forWidth(width).infoWidth(width), true);
    try portrait.write(out, information.written(), width, use_color);
}

fn writeAccountDetails(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    use_color: bool,
    usage_overrides: ?[]const ?[]const u8,
    snapshots: ?[]const subscription.Snapshot,
    width: usize,
    dotted: bool,
) !void {
    const allocator = std.heap.page_allocator;
    const now = std.time.timestamp();
    var display = try display_rows.buildDisplayRows(allocator, reg, null);
    defer display.deinit(allocator);
    if (use_color) try out.writeAll(ansi.teal);
    try out.writeAll("CODEX AUTH\n");
    try out.print("{d} ACCOUNTS / QUOTA LEFT\n", .{display.selectable_row_indices.len});
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeByte('\n');

    if (display.selectable_row_indices.len == 0) {
        const panel = pixel.Panel{ .out = out, .width = width, .framed = false };
        try panel.border("START");
        try panel.line("No saved accounts.", "");
        try panel.line("Ready when you are!", "");
        try panel.line("Run: codex-auth login", "");
        try panel.border("");
        return;
    }
    for (display.selectable_row_indices, 0..) |row_index, number| {
        const row = display.rows[row_index];
        const account_idx = row.account_index.?;
        const rec = &reg.accounts.items[account_idx];
        const panel = pixel.Panel{
            .out = out,
            .width = width,
            .border_color = if (!use_color) "" else if (row.is_active) ansi.teal else ansi.bold,
            .framed = false,
            .dotted = dotted,
        };
        const title = try std.fmt.allocPrint(allocator, "[{d:0>2}] {s}{s}", .{
            number + 1, if (row.is_active) "* ACTIVE / " else "", planDisplay(rec, "Unknown"),
        });
        defer allocator.free(title);
        try panel.border(title);
        try panel.line(rec.email, if (use_color) ansi.bold else "");
        if (row.depth == 0 and rec.alias.len > 0) try panel.line(rec.alias, "");
        if (row.depth > 0) try panel.line(row.account_cell, "");
        const usage_override = usageOverrideForAccount(usage_overrides, account_idx);
        const last = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, now);
        defer allocator.free(last);
        const seen = try std.fmt.allocPrint(allocator, "seen {s}", .{last});
        defer allocator.free(seen);
        try writeAccountStatus(panel, accountMood(rec.last_usage, usage_override, now), seen, use_color);
        try writePixelQuota(panel, "5H", resolveRateWindow(rec.last_usage, 300, true), usage_override, now, use_color);
        try writePixelQuota(panel, "WEEK", resolveRateWindow(rec.last_usage, 10080, false), usage_override, now, use_color);
        if (snapshots) |items| {
            if (account_idx < items.len) {
                try panel.line("", "");
                try writePixelSubscription(panel, items[account_idx], now, use_color);
            }
        }
        try panel.border("");
        try out.writeByte('\n');
    }
    if (snapshots != null) {
        try out.writeAll("SUB: login snapshot\nRenewal: unconfirmed\nTimes: local\n");
    }
}

const Mood = enum { ready, low, empty, unknown, failed };

fn quotaRemaining(window: ?registry.RateLimitWindow, failure: ?[]const u8, now: i64) ?i64 {
    if (failure != null) return null;
    const w = window orelse return null;
    if (!std.math.isFinite(w.used_percent)) return null;
    if (w.resets_at) |ts| if (ts <= now) return 100;
    return remainingPercent(w.used_percent);
}

fn accountMood(usage: ?registry.RateLimitSnapshot, failure: ?[]const u8, now: i64) Mood {
    if (failure != null) return .failed;
    const five = quotaRemaining(resolveRateWindow(usage, 300, true), null, now);
    const week = quotaRemaining(resolveRateWindow(usage, 10080, false), null, now);
    const lowest = @min(five orelse 100, week orelse 100);
    if (lowest <= 5) return .empty;
    if (lowest <= 20) return .low;
    if (five == null or week == null) return .unknown;
    return .ready;
}

fn writeAccountStatus(panel: pixel.Panel, mood: Mood, activity: []const u8, use_color: bool) !void {
    const allocator = std.heap.page_allocator;
    const label: []const u8 = switch (mood) {
        .ready => "READY!",
        .low => "EASY...",
        .empty => "NAP TIME",
        .unknown => "HMM...?",
        .failed => "UH-OH!",
    };
    const tone: []const u8 = if (!use_color) "" else switch (mood) {
        .ready => ansi.green,
        .low, .unknown => ansi.yellow,
        .empty, .failed => ansi.red,
    };
    const status = try std.fmt.allocPrint(allocator, "{s} / {s}", .{ label, activity });
    defer allocator.free(status);
    try panel.line(status, tone);
    try panel.line("", "");
}

fn writePixelQuota(
    panel: pixel.Panel,
    label: []const u8,
    window: ?registry.RateLimitWindow,
    failure: ?[]const u8,
    now: i64,
    use_color: bool,
) !void {
    const allocator = std.heap.page_allocator;
    const remaining = quotaRemaining(window, failure, now);
    const count = @min(@as(usize, 20), panel.inner() - 15);
    var bars: [20]u8 = undefined;
    const filled: usize = if (remaining) |value| @intCast(@divTrunc(value * @as(i64, @intCast(count)), 100)) else 0;
    for (bars[0..count], 0..) |*cell, i| cell.* = if (remaining == null) '?' else if (i < filled or (i == 0 and remaining.? > 0)) '#' else '.';
    var metric: std.Io.Writer.Allocating = .init(allocator);
    defer metric.deinit();
    try metric.writer.print("{s}", .{label});
    try writeRepeat(&metric.writer, ' ', 6 - label.len);
    try metric.writer.writeByte('[');
    for (bars[0..count]) |cell| {
        if (panel.dotted and cell != '?') {
            try metric.writer.writeAll(if (cell == '#') "⣿" else "⣀");
        } else try metric.writer.writeByte(cell);
    }
    try metric.writer.writeAll("] ");
    if (failure) |value| {
        try metric.writer.print("{s}", .{value});
    } else if (remaining) |value| {
        try metric.writer.print("{d: >3}%", .{@as(u8, @intCast(value))});
    } else try metric.writer.writeAll(" --%");
    const tone = if (!use_color) "" else if (failure != null) ansi.red else if (remaining) |value|
        (if (value <= 5) ansi.red else if (value <= 20) ansi.yellow else ansi.green)
    else
        ansi.dim;
    const reset = if (failure != null) try allocator.dupe(u8, "refresh failed") else if (window) |w| blk: {
        if (w.resets_at) |ts| {
            if (ts <= now) break :blk try allocator.dupe(u8, "window reset");
            const when = try formatResetTimeAlloc(ts, now);
            defer allocator.free(when);
            break :blk try std.fmt.allocPrint(allocator, "reset {s}", .{when});
        }
        break :blk try allocator.dupe(u8, "reset unknown");
    } else try allocator.dupe(u8, "no usage data");
    defer allocator.free(reset);
    if (pixel.displayWidth(metric.written()) + 3 + reset.len <= panel.inner()) {
        try metric.writer.print("   {s}", .{reset});
        try panel.line(metric.written(), tone);
    } else {
        try panel.line(metric.written(), tone);
        const reset_line = try std.fmt.allocPrint(allocator, "      {s}", .{reset});
        defer allocator.free(reset_line);
        try panel.line(reset_line, "");
    }
}

fn writePixelSubscription(panel: pixel.Panel, snapshot: subscription.Snapshot, now: i64, use_color: bool) !void {
    const allocator = std.heap.page_allocator;
    var details: std.Io.Writer.Allocating = .init(allocator);
    defer details.deinit();
    try details.writer.writeAll("SUB   ");
    if (snapshot.valid_until) |until| {
        try writeSubscriptionTime(&details.writer, until);
        if (until <= now) {
            try details.writer.writeAll(" / past snapshot");
        } else {
            const days = @divTrunc(until - now, 86400);
            if (days == 0) try details.writer.writeAll(" / <1d left") else try details.writer.print(" / {d}d left", .{days});
        }
    } else try details.writer.writeAll("unknown");
    const is_past = if (snapshot.valid_until) |ts| ts <= now else false;
    try panel.line(details.written(), if (use_color and is_past) ansi.yellow else "");
    var checked: std.Io.Writer.Allocating = .init(allocator);
    defer checked.deinit();
    try checked.writer.writeAll("CHECKED  ");
    if (snapshot.checked_at) |ts| try writeSubscriptionTime(&checked.writer, ts) else try checked.writer.writeAll("unknown");
    try panel.line(checked.written(), if (use_color) ansi.dim else "");
}

fn writeSubscriptionTime(out: *std.Io.Writer, ts: i64) !void {
    var tm: c.struct_tm = undefined;
    if (!localtimeCompat(ts, &tm)) return out.writeAll("unknown");
    // Reuse the same local timezone conversion as usage-reset times.
    var buf: [64]u8 = undefined;
    const len = c.strftime(&buf, buf.len, "%Y-%m-%d %H:%M %z", &tm);
    if (len == 0) return out.writeAll("unknown");
    try out.writeAll(buf[0..len]);
}

fn resolveRateWindow(usage: ?registry.RateLimitSnapshot, minutes: i64, fallback_primary: bool) ?registry.RateLimitWindow {
    if (usage == null) return null;
    if (usage.?.primary) |p| {
        if (p.window_minutes != null and p.window_minutes.? == minutes) return p;
    }
    if (usage.?.secondary) |s| {
        if (s.window_minutes != null and s.window_minutes.? == minutes) return s;
    }
    return if (fallback_primary) usage.?.primary else usage.?.secondary;
}

const ResetParts = struct {
    time: []u8,
    date: []u8,
    same_day: bool,

    fn deinit(self: *ResetParts) void {
        std.heap.page_allocator.free(self.time);
        std.heap.page_allocator.free(self.date);
    }
};

fn localtimeCompat(ts: i64, out_tm: *c.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        // Bind directly to the exported CRT symbol on Windows.
        if (comptime @hasDecl(c, "_localtime64_s") and @hasDecl(c, "__time64_t")) {
            var t64 = std.math.cast(c.__time64_t, ts) orelse return false;
            return c._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c.time_t, ts) orelse return false;
    if (comptime @hasDecl(c, "localtime_r")) {
        return c.localtime_r(&t, out_tm) != null;
    }

    if (comptime @hasDecl(c, "localtime")) {
        const tm_ptr = c.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }

    return false;
}

fn resetPartsAlloc(reset_at: i64, now: i64) !ResetParts {
    var tm: c.struct_tm = undefined;
    if (!localtimeCompat(reset_at, &tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
            .date = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
            .same_day = true,
        };
    }
    var now_tm: c.struct_tm = undefined;
    if (!localtimeCompat(now, &now_tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
            .date = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
            .same_day = true,
        };
    }

    const same_day = tm.tm_year == now_tm.tm_year and tm.tm_mon == now_tm.tm_mon and tm.tm_mday == now_tm.tm_mday;
    const hour = @as(u32, @intCast(tm.tm_hour));
    const min = @as(u32, @intCast(tm.tm_min));
    const day = @as(u32, @intCast(tm.tm_mday));
    const months = [_][]const u8{
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    };
    const month_idx: usize = if (tm.tm_mon < 0) 0 else @min(@as(usize, @intCast(tm.tm_mon)), months.len - 1);
    return ResetParts{
        .time = try std.fmt.allocPrint(std.heap.page_allocator, "{d:0>2}:{d:0>2}", .{ hour, min }),
        .date = try std.fmt.allocPrint(std.heap.page_allocator, "{d} {s}", .{ day, months[month_idx] }),
        .same_day = same_day,
    };
}

fn formatRateLimitFullAlloc(window: ?registry.RateLimitWindow) ![]u8 {
    if (window == null) return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    if (window.?.resets_at == null) return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    const now = std.time.timestamp();
    const reset_at = window.?.resets_at.?;
    if (now >= reset_at) {
        return try std.fmt.allocPrint(std.heap.page_allocator, "100%", .{});
    }
    const remaining = remainingPercent(window.?.used_percent);
    var parts = try resetPartsAlloc(reset_at, now);
    defer parts.deinit();
    if (parts.same_day) {
        return std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s})", .{ remaining, parts.time });
    }
    return std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
}

fn formatRateLimitUiAlloc(window: ?registry.RateLimitWindow, width: usize) ![]u8 {
    if (window == null) return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    if (window.?.resets_at == null) return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    const now = std.time.timestamp();
    const reset_at = window.?.resets_at.?;
    if (now >= reset_at) {
        return try std.fmt.allocPrint(std.heap.page_allocator, "100%", .{});
    }
    const remaining = remainingPercent(window.?.used_percent);
    var parts = try resetPartsAlloc(reset_at, now);
    defer parts.deinit();

    const candidates_same = [_][]const u8{
        try std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s})", .{ remaining, parts.time }),
        try std.fmt.allocPrint(std.heap.page_allocator, "{d}%", .{remaining}),
    };
    defer std.heap.page_allocator.free(candidates_same[0]);
    defer std.heap.page_allocator.free(candidates_same[1]);

    if (parts.same_day) {
        if (width >= candidates_same[0].len or width == 0) return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidates_same[0]});
        return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidates_same[1]});
    }

    const candidate_full = try std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
    defer std.heap.page_allocator.free(candidate_full);
    const candidate_date = try std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s})", .{ remaining, parts.date });
    defer std.heap.page_allocator.free(candidate_date);
    const candidate_time = try std.fmt.allocPrint(std.heap.page_allocator, "{d}% ({s})", .{ remaining, parts.time });
    defer std.heap.page_allocator.free(candidate_time);
    const candidate_percent = try std.fmt.allocPrint(std.heap.page_allocator, "{d}%", .{remaining});
    defer std.heap.page_allocator.free(candidate_percent);

    if (width >= candidate_full.len or width == 0) return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidate_full});
    if (width >= candidate_date.len) return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidate_date});
    if (width >= candidate_time.len) return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidate_time});
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{candidate_percent});
}

fn remainingPercent(used: f64) i64 {
    const remaining = 100.0 - used;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}

fn formatResetTimeAlloc(ts: i64, now: i64) ![]u8 {
    var tm: c.struct_tm = undefined;
    if (!localtimeCompat(ts, &tm)) {
        return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    }
    var now_tm: c.struct_tm = undefined;
    if (!localtimeCompat(now, &now_tm)) {
        return try std.fmt.allocPrint(std.heap.page_allocator, "-", .{});
    }

    const same_day = tm.tm_year == now_tm.tm_year and tm.tm_mon == now_tm.tm_mon and tm.tm_mday == now_tm.tm_mday;
    const hour = @as(u32, @intCast(tm.tm_hour));
    const min = @as(u32, @intCast(tm.tm_min));
    if (same_day) {
        return std.fmt.allocPrint(std.heap.page_allocator, "{d:0>2}:{d:0>2}", .{ hour, min });
    }
    const day = @as(u32, @intCast(tm.tm_mday));
    const months = [_][]const u8{
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    };
    const month_idx: usize = if (tm.tm_mon < 0) 0 else @min(@as(usize, @intCast(tm.tm_mon)), months.len - 1);
    return std.fmt.allocPrint(std.heap.page_allocator, "{d:0>2}:{d:0>2} on {d} {s}", .{ hour, min, day, months[month_idx] });
}

fn printTableBorder(out: *std.Io.Writer, widths: []const usize) !void {
    try out.writeAll("+");
    for (widths) |w| {
        var i: usize = 0;
        while (i < w + 2) : (i += 1) {
            try out.writeAll("=");
        }
        try out.writeAll("+");
    }
    try out.writeAll("\n");
}

fn printTableDivider(out: *std.Io.Writer, widths: []const usize) !void {
    try out.writeAll("+");
    for (widths) |w| {
        var i: usize = 0;
        while (i < w + 2) : (i += 1) {
            try out.writeAll("=");
        }
        try out.writeAll("+");
    }
    try out.writeAll("\n");
}

fn printTableEnd(out: *std.Io.Writer, widths: []const usize) !void {
    try out.writeAll("+");
    for (widths) |w| {
        var i: usize = 0;
        while (i < w + 2) : (i += 1) {
            try out.writeAll("=");
        }
        try out.writeAll("+");
    }
    try out.writeAll("\n");
}

fn printTableRow(out: *std.Io.Writer, widths: []const usize, cells: []const []const u8) !void {
    try out.writeAll("|");
    for (cells, 0..) |cell, idx| {
        try out.writeAll(" ");
        try out.print("{s}", .{cell});
        const pad = if (cell.len >= widths[idx]) 0 else (widths[idx] - cell.len);
        var i: usize = 0;
        while (i < pad) : (i += 1) {
            try out.writeAll(" ");
        }
        try out.writeAll(" |");
    }
    try out.writeAll("\n");
}

fn writePadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    try out.writeAll(value);
    if (value.len >= width) return;
    var i: usize = 0;
    const pad = width - value.len;
    while (i < pad) : (i += 1) {
        try out.writeAll(" ");
    }
}

fn writeRepeat(out: *std.Io.Writer, ch: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.writeByte(ch);
    }
}

fn adjustTableWidths(widths: []usize) void {
    const term_cols = terminalWidth();
    if (term_cols == 0) return;
    const total = tableTotalWidth(widths);
    if (total <= term_cols) return;

    const min_plan: usize = 4;
    const min_rate: usize = 2;
    const min_last: usize = 19;
    const min_email: usize = 10;

    var over = total - term_cols;
    if (over == 0) return;

    if (widths[0] > min_email) {
        const reducible = widths[0] - min_email;
        const reduce = @min(reducible, over);
        widths[0] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths[1] > min_plan) {
        const reducible = widths[1] - min_plan;
        const reduce = @min(reducible, over);
        widths[1] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths.len > 2 and widths[2] > min_rate) {
        const reducible = widths[2] - min_rate;
        const reduce = @min(reducible, over);
        widths[2] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths.len > 3 and widths[3] > min_rate) {
        const reducible = widths[3] - min_rate;
        const reduce = @min(reducible, over);
        widths[3] -= reduce;
        over -= reduce;
    }
    if (over == 0) return;

    if (widths.len > 4 and widths[4] > min_last) {
        const reducible = widths[4] - min_last;
        const reduce = @min(reducible, over);
        widths[4] -= reduce;
        over -= reduce;
    }
}

fn tableTotalWidth(widths: []const usize) usize {
    var sum: usize = 0;
    for (widths) |w| sum += w;
    return sum + (3 * widths.len) + 1;
}

fn terminalWidth() usize {
    const stdout_file = std.fs.File.stdout();
    if (!stdout_file.isTty()) return 0;

    if (comptime builtin.os.tag == .windows) {
        var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(stdout_file.handle, &info) == std.os.windows.FALSE) {
            return 0;
        }
        const width = @as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1;
        if (width <= 0) return 0;
        return @as(usize, @intCast(width));
    } else {
        var wsz: std.posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = std.posix.system.ioctl(stdout_file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (std.posix.errno(rc) != .SUCCESS) return 0;
        return @as(usize, wsz.col);
    }
}

fn truncateAlloc(value: []const u8, max_len: usize) ![]u8 {
    if (value.len <= max_len) return try std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{value});
    if (max_len == 0) return try std.fmt.allocPrint(std.heap.page_allocator, "", .{});
    if (max_len == 1) return try std.fmt.allocPrint(std.heap.page_allocator, ".", .{});
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}.", .{value[0 .. max_len - 1]});
}

fn makeTestRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendTestAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    record_key: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: registry.PlanType,
) !void {
    const sep = std.mem.lastIndexOf(u8, record_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = record_key[0..sep];
    const chatgpt_account_id = record_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, record_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = null,
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

test "printTableRow handles long cells without underflow" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const widths = [_]usize{3};
    const cells = [_][]const u8{"abcdef"};
    try printTableRow(&writer, &widths, &cells);
    try writer.flush();
}

test "truncateAlloc respects max_len" {
    const out1 = try truncateAlloc("abcdef", 3);
    defer std.heap.page_allocator.free(out1);
    try std.testing.expect(out1.len == 3);
    const out2 = try truncateAlloc("abcdef", 1);
    defer std.heap.page_allocator.free(out2);
    try std.testing.expect(out2.len == 1);
}

test "formatRateLimitFullAlloc shows 100% after reset instead of dash-prefixed value" {
    const now = std.time.timestamp();
    const window = registry.RateLimitWindow{
        .used_percent = 100.0,
        .window_minutes = 300,
        .resets_at = now - 60,
    };

    const formatted = try formatRateLimitFullAlloc(window);
    defer std.heap.page_allocator.free(formatted);

    try std.testing.expectEqualStrings("100%", formatted);
}

test "writeAccountsTable shows zero-padded row numbers for selectable accounts" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Als's Workspace");
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    var buffer: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "[01] Business") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[02] Free") != null);
}

test "subscription details distinguish future dates from past snapshots and unknown" {
    const now = subscription.parseTimestamp("2030-01-02T12:00:00Z").?;
    var buffer: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const panel = pixel.Panel{ .out = &writer, .width = 84 };
    try writePixelSubscription(panel, .{ .valid_until = now + 2 * 86400, .checked_at = now }, now, false);
    try writePixelSubscription(panel, .{ .valid_until = now + 60 }, now, false);
    try writePixelSubscription(panel, .{ .valid_until = now }, now, false);
    try writePixelSubscription(panel, .{}, now, false);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "SUB   2030-") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CHECKED  2030-") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/ 2d left") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/ <1d left") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/ past snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SUB   unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "expired") == null);
}

test "subscription details follow selectable rows in grouped account output" {
    const allocator = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(allocator);
    try appendTestAccount(allocator, &reg, "user-1::acc-1", "user@example.com", "", .pro);
    try appendTestAccount(allocator, &reg, "user-1::acc-2", "user@example.com", "", .free);
    const snapshots = [_]subscription.Snapshot{
        .{ .valid_until = subscription.parseTimestamp("2030-01-02T03:04:05Z") }, .{},
    };
    var buffer: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithSubscriptions(&writer, &reg, false, null, &snapshots);
    const output = writer.buffered();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "SUB  "));
    try std.testing.expect(std.mem.indexOf(u8, output, "Renewal: unconfirmed") != null);
}

test "writeAccountsTable shows usage override statuses for failed refreshes" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "403" };

    var buffer: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverrides(&writer, &reg, false, &usage_overrides);

    const output = writer.buffered();
    try std.testing.expect(std.mem.count(u8, output, "403") >= 2);
}

test "writeAccountsTable prefers usage snapshot plan labels over stored auth plan" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = .team,
    };

    var buffer: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Business") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Plus") == null);
}

test "account panels retain identity and fit narrow terminals without color" {
    const allocator = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(allocator);
    try appendTestAccount(allocator, &reg, "user::account", "very-long-account-name-for-wrapping@example.com", "交易账户 cafe\u{301}", .pro);
    reg.active_account_key = try allocator.dupe(u8, "user::account");
    const snapshots = [_]subscription.Snapshot{.{ .valid_until = subscription.parseTimestamp("2030-01-02T03:04:05Z") }};
    for ([_]usize{ 24, 40, 60, 84, 100, 128, 160 }) |width| {
        var buffer: [16384]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writeAccountPanels(&writer, &reg, false, null, &snapshots, width);
        const output = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, output, "* ACTIVE") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "HMM...?") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "2030-") != null);
        try std.testing.expect(std.mem.indexOfScalar(u8, output, 0x1b) == null);
        var lines = std.mem.tokenizeScalar(u8, output, '\n');
        while (lines.next()) |line| try std.testing.expect(pixel.displayWidth(line) <= width);
    }
}

test "quota and companion distinguish exhausted unknown failed and reset windows" {
    const now: i64 = 1000;
    var window = registry.RateLimitWindow{ .used_percent = 100, .window_minutes = 300, .resets_at = now + 60 };
    var usage = registry.RateLimitSnapshot{ .primary = window, .secondary = null, .credits = null, .plan_type = .pro };
    try std.testing.expectEqual(Mood.empty, accountMood(usage, null, now));
    try std.testing.expectEqual(Mood.failed, accountMood(usage, "403", now));
    try std.testing.expectEqual(Mood.unknown, accountMood(null, null, now));
    window.used_percent = 85;
    usage.primary = window;
    try std.testing.expectEqual(Mood.low, accountMood(usage, null, now));
    window.used_percent = 4;
    usage.primary = window;
    usage.secondary = .{ .used_percent = 4, .window_minutes = 10080, .resets_at = now + 60 };
    try std.testing.expectEqual(Mood.ready, accountMood(usage, null, now));

    var buffer: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const panel = pixel.Panel{ .out = &writer, .width = 84 };
    window.used_percent = 100;
    try writePixelQuota(panel, "5H", window, null, now, false);
    try writePixelQuota(panel, "5H", null, null, now, false);
    try writePixelQuota(panel, "5H", window, "403", now, false);
    window.resets_at = now;
    try writePixelQuota(panel, "5H", window, null, now, false);
    window.used_percent = std.math.nan(f64);
    try std.testing.expectEqual(@as(?i64, null), quotaRemaining(window, null, now));
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "[....................]   0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[????????????????????]  --%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[????????????????????] 403") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[####################] 100%   window reset") != null);
}
