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
    const muted = "\x1b[38;2;124;139;146m";
    const rule = "\x1b[38;2;165;181;185m";
    const coral = "\x1b[38;2;185;101;86m";
    const amber = "\x1b[38;2;168;131;63m";
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
    try writeAccountDetails(&information.writer, reg, use_color, usage_overrides, snapshots, @min(@as(usize, 72), portrait.Layout.forWidth(width).infoWidth(width)), true);
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
    const heading = pixel.Panel{ .out = out, .width = width, .framed = false, .dotted = dotted };
    const count = try std.fmt.allocPrint(allocator, "{d:0>2} ACCOUNTS", .{display.selectable_row_indices.len});
    defer allocator.free(count);
    try heading.columns(&.{.{ .text = "CODEX / AUTH", .tone = if (use_color) ansi.bold ++ ansi.teal else "" }}, &.{.{ .text = count, .tone = if (use_color) ansi.muted else "" }});
    try heading.line("REMAINING QUOTA", if (use_color) ansi.muted else "");
    try heading.rule(if (use_color) ansi.rule else "");
    try heading.line("", "");

    if (display.selectable_row_indices.len == 0) {
        const panel = pixel.Panel{ .out = out, .width = width, .framed = false };
        try panel.border("START");
        try panel.line("No saved accounts.", "");
        try panel.line("Ready when you are!", "");
        try panel.line("Run: codex-auth login", "");
        try panel.border("");
        return;
    }
    // Keep the original selectable ordinal used by switch/remove, even when pinned.
    for ([_]bool{ true, false }) |active_first| {
        for (display.selectable_row_indices, 0..) |row_index, number| {
            const row = display.rows[row_index];
            if (row.is_active != active_first) continue;
            const account_idx = row.account_index.?;
            const rec = &reg.accounts.items[account_idx];
            const panel = pixel.Panel{
                .out = out,
                .width = width,
                .border_color = if (!use_color) "" else if (row.is_active) ansi.teal else ansi.bold,
                .framed = false,
                .dotted = dotted,
            };
            const number_text = try std.fmt.allocPrint(allocator, "{d:0>2}  ", .{number + 1});
            defer allocator.free(number_text);
            try panel.columns(&.{
                .{ .text = number_text, .tone = if (use_color) ansi.muted else "" },
                .{ .text = planDisplay(rec, "Unknown"), .tone = if (use_color) ansi.bold else "" },
            }, &.{.{ .text = if (row.is_active) "* ACTIVE" else "SAVED", .tone = if (!use_color) "" else if (row.is_active) ansi.teal else ansi.muted }});
            try panel.line(rec.email, if (use_color and row.is_active) ansi.bold else "");
            if (row.depth == 0 and rec.alias.len > 0) try panel.line(rec.alias, "");
            if (row.depth > 0) try panel.line(row.account_cell, "");
            const usage_override = usageOverrideForAccount(usage_overrides, account_idx);
            const last = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, now);
            defer allocator.free(last);
            const seen = try std.fmt.allocPrint(allocator, "Updated {s}", .{last});
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
            try panel.rule(if (use_color) ansi.rule else "");
            try panel.line("", "");
        }
    }
    if (snapshots != null) {
        try heading.line("Subscription dates are login snapshots.", if (use_color) ansi.muted else "");
        try heading.line("Renewal: unconfirmed. All times local.", if (use_color) ansi.muted else "");
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

fn statusTone(mood: Mood, use_color: bool) []const u8 {
    if (!use_color) return "";
    return switch (mood) {
        .ready => ansi.teal,
        .low => ansi.amber,
        .empty, .failed => ansi.coral,
        .unknown => ansi.muted,
    };
}

fn writeAccountStatus(panel: pixel.Panel, mood: Mood, activity: []const u8, use_color: bool) !void {
    const label: []const u8 = switch (mood) {
        .ready => "Ready",
        .low => "Running low",
        .empty => "Low quota",
        .unknown => "No usage data",
        .failed => "Refresh failed",
    };
    try panel.columns(&.{.{ .text = label, .tone = statusTone(mood, use_color) }}, &.{.{ .text = activity, .tone = if (use_color) ansi.muted else "" }});
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
    const count: usize = @min(18, panel.inner() - 15);
    const tone = statusTone(if (failure != null) .failed else if (remaining) |value| (if (value <= 5) .empty else if (value <= 20) .low else .ready) else .unknown, use_color);
    const muted = if (use_color) ansi.muted else "";
    var filled: std.Io.Writer.Allocating = .init(allocator);
    defer filled.deinit();
    var empty: std.Io.Writer.Allocating = .init(allocator);
    defer empty.deinit();
    // Four central dots make a fine horizontal ribbon, with quarter-cell precision.
    var dots: usize = if (remaining) |value| @intCast(@max(if (value > 0) @as(i64, 1) else 0, @divTrunc(value * @as(i64, @intCast(count * 4)), 100))) else 0;
    const partial = [_][]const u8{ "", "⠄", "⠆", "⠖", "⠶" };
    for (0..count) |_| {
        if (dots > 0) {
            const n = @min(@as(usize, 4), dots);
            try filled.writer.writeAll(if (panel.dotted) partial[n] else "=");
            dots -= n;
        } else try empty.writer.writeAll(if (remaining == null) "?" else if (panel.dotted) "·" else ".");
    }
    const label_text = try std.fmt.allocPrint(allocator, "{s: <5}", .{label});
    defer allocator.free(label_text);
    const value_text = if (failure) |value| try std.fmt.allocPrint(allocator, "{s: >5}", .{value}) else if (remaining) |value|
        try std.fmt.allocPrint(allocator, "{d: >4}%", .{@as(u8, @intCast(value))})
    else
        try allocator.dupe(u8, "  --%");
    defer allocator.free(value_text);
    const reset = if (failure != null) try allocator.dupe(u8, "refresh failed") else if (window) |w| blk: {
        if (w.resets_at) |ts| {
            break :blk try resetCountdownAlloc(ts, now);
        }
        break :blk try allocator.dupe(u8, "reset unknown");
    } else try allocator.dupe(u8, "no usage data");
    defer allocator.free(reset);
    const parts = [_]pixel.Span{
        .{ .text = label_text, .tone = muted },
        .{ .text = value_text, .tone = if (use_color) ansi.bold else "" },
        .{ .text = "  " },
        .{ .text = filled.written(), .tone = tone },
        .{ .text = empty.written(), .tone = muted },
    };
    if (pixel.displayWidth(label_text) + pixel.displayWidth(value_text) + 2 + count + 3 + reset.len <= panel.inner()) {
        try panel.columns(&parts, &.{.{ .text = reset, .tone = muted }});
    } else {
        try panel.spans(&parts);
        try panel.spans(&.{ .{ .text = "     " }, .{ .text = reset, .tone = muted } });
    }
}

/// Relative reset labels do not depend on the local timezone or calendar day.
fn resetCountdownAlloc(reset_at: i64, now: i64) ![]u8 {
    const allocator = std.heap.page_allocator;
    if (reset_at <= now) return allocator.dupe(u8, "window reset");
    const seconds: u64 = @intCast(@as(i128, reset_at) - @as(i128, now));
    if (seconds < 60) return allocator.dupe(u8, "resets in <1m");
    const days = seconds / 86400;
    const hours = (seconds / 3600) % 24;
    const minutes = (seconds / 60) % 60;
    if (days > 0) {
        if (hours == 0) return std.fmt.allocPrint(allocator, "resets in {d}d", .{days});
        return std.fmt.allocPrint(allocator, "resets in {d}d {d}h", .{ days, hours });
    }
    if (hours > 0) {
        if (minutes == 0) return std.fmt.allocPrint(allocator, "resets in {d}h", .{hours});
        return std.fmt.allocPrint(allocator, "resets in {d}h {d}m", .{ hours, minutes });
    }
    return std.fmt.allocPrint(allocator, "resets in {d}m", .{minutes});
}

fn writePixelSubscription(panel: pixel.Panel, snapshot: subscription.Snapshot, now: i64, use_color: bool) !void {
    const allocator = std.heap.page_allocator;
    const muted = if (use_color) ansi.muted else "";
    const is_past = if (snapshot.valid_until) |ts| ts <= now else false;
    const status = if (snapshot.valid_until) |until| blk: {
        if (until <= now) break :blk try allocator.dupe(u8, "Past snapshot");
        const days = @divTrunc(until - now, 86400);
        break :blk if (days == 0) try allocator.dupe(u8, "<1d left") else try std.fmt.allocPrint(allocator, "{d}d left", .{days});
    } else try allocator.dupe(u8, "Unknown");
    defer allocator.free(status);
    var until: std.Io.Writer.Allocating = .init(allocator);
    defer until.deinit();
    if (snapshot.valid_until) |ts| try writeSubscriptionTime(&until.writer, ts) else try until.writer.writeAll("unknown");
    try panel.columns(&.{
        .{ .text = "SUB      ", .tone = muted },
        .{ .text = until.written() },
    }, &.{.{ .text = status, .tone = if (use_color and is_past) ansi.amber else "" }});
    var checked: std.Io.Writer.Allocating = .init(allocator);
    defer checked.deinit();
    try checked.writer.writeAll("Checked  ");
    if (snapshot.checked_at) |ts| try writeSubscriptionTime(&checked.writer, ts) else try checked.writer.writeAll("unknown");
    try panel.line(checked.written(), muted);
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

test "active account is first without changing switch and remove row numbers" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "a@example.com", "", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Als's Workspace");
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "b@example.com", "", .free);

    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-2");

    var buffer: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "01  Business") != null);
    const saved_pos = std.mem.indexOf(u8, output, "01  Business").?;
    const active_pos = std.mem.indexOf(u8, output, "02  Free").?;
    try std.testing.expect(active_pos < saved_pos);
    try std.testing.expect(std.mem.indexOf(u8, output[active_pos..saved_pos], "* ACTIVE") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "02  Free"));
    var selectable = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer selectable.deinit(gpa);
    try std.testing.expectEqual(@as(?usize, 0), selectable.rows[selectable.selectable_row_indices[0]].account_index);
    try std.testing.expectEqual(@as(?usize, 1), selectable.rows[selectable.selectable_row_indices[1]].account_index);
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
    try std.testing.expect(std.mem.indexOf(u8, output, "SUB      2030-") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Checked  2030-") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2d left") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<1d left") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Past snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SUB      unknown") != null);
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
    reg.active_account_key = try allocator.dupe(u8, "user-1::acc-2");
    const overrides = [_]?[]const u8{ null, "403" };
    var buffer: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithSubscriptions(&writer, &reg, false, &overrides, &snapshots);
    const output = writer.buffered();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "SUB      "));
    try std.testing.expect(std.mem.indexOf(u8, output, "Renewal: unconfirmed") != null);
    const saved_pos = std.mem.indexOf(u8, output, "02  Pro").?;
    const active_pos = std.mem.indexOf(u8, output, "01  Free").?;
    const active_card = output[active_pos..saved_pos];
    try std.testing.expect(std.mem.indexOf(u8, active_card, "SUB      unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_card, "403") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_card, "2030-") == null);
    try std.testing.expect(std.mem.indexOf(u8, output[saved_pos..], "SUB      2030-") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[saved_pos..], "403") == null);
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
        try std.testing.expect(std.mem.indexOf(u8, output, "No usage data") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "2030-") != null);
        try std.testing.expect(std.mem.indexOfScalar(u8, output, 0x1b) == null);
        var lines = std.mem.tokenizeScalar(u8, output, '\n');
        while (lines.next()) |line| try std.testing.expect(pixel.displayWidth(line) <= width);
    }
}

test "quota and status distinguish exhausted unknown failed and reset windows" {
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
    try std.testing.expect(std.mem.indexOf(u8, output, "0%  ..................") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--%  ??????????????????") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "403  ??????????????????") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "100%  ==================") != null);
}

test "reset countdown handles expired subminute hour and day boundaries" {
    const now: i64 = 1000;
    const cases = .{
        .{ @as(i64, -1), "window reset" },
        .{ @as(i64, 0), "window reset" },
        .{ @as(i64, 1), "resets in <1m" },
        .{ @as(i64, 59), "resets in <1m" },
        .{ @as(i64, 60), "resets in 1m" },
        .{ @as(i64, 3599), "resets in 59m" },
        .{ @as(i64, 3600), "resets in 1h" },
        .{ @as(i64, 3660), "resets in 1h 1m" },
        .{ @as(i64, 86399), "resets in 23h 59m" },
        .{ @as(i64, 86400), "resets in 1d" },
        .{ @as(i64, 2 * 86400 + 4 * 3600), "resets in 2d 4h" },
    };
    inline for (cases) |case| {
        const label = try resetCountdownAlloc(now + case[0], now);
        defer std.heap.page_allocator.free(label);
        try std.testing.expectEqualStrings(case[1], label);
    }
}
