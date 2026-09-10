const std = @import("std");

/// Subscription claims describe the saved login, not a live billing status.
/// In particular, JWT `exp` is not a subscription expiration date.
pub const Snapshot = struct {
    valid_until: ?i64 = null,
    checked_at: ?i64 = null,
};

pub fn fromClaims(claims: std.json.ObjectMap) Snapshot {
    return .{
        .valid_until = timestampField(claims.get("chatgpt_subscription_active_until")),
        .checked_at = timestampField(claims.get("chatgpt_subscription_last_checked")),
    };
}

fn timestampField(value: ?std.json.Value) ?i64 {
    return switch (value orelse return null) {
        .string => |s| parseTimestamp(s),
        else => null,
    };
}

/// Parse RFC 3339 timestamps, including fractional seconds and UTC offsets.
/// Invalid/missing metadata must never prevent account management.
pub fn parseTimestamp(s: []const u8) ?i64 {
    if (s.len < 20 or s.len > 64) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const year = decimal(s[0..4]) orelse return null;
    const month = decimal(s[5..7]) orelse return null;
    const day = decimal(s[8..10]) orelse return null;
    const hour = decimal(s[11..13]) orelse return null;
    const minute = decimal(s[14..16]) orelse return null;
    const second = decimal(s[17..19]) orelse return null;
    if (year < 1970 or month < 1 or month > 12) return null;
    const days_in_month = std.time.epoch.getDaysInMonth(@intCast(year), @enumFromInt(month));
    if (day < 1 or day > days_in_month or hour > 23 or minute > 59 or second > 59) return null;

    var idx: usize = 19;
    if (s[idx] == '.') {
        idx += 1;
        const start = idx;
        while (idx < s.len and std.ascii.isDigit(s[idx])) : (idx += 1) {}
        if (idx == start) return null;
    }
    if (idx >= s.len) return null;
    var offset: i64 = 0;
    if (s[idx] == 'Z') {
        if (idx + 1 != s.len) return null;
    } else if (s[idx] == '+' or s[idx] == '-') {
        if (idx + 6 != s.len or s[idx + 3] != ':') return null;
        const offset_hour = decimal(s[idx + 1 .. idx + 3]) orelse return null;
        const offset_minute = decimal(s[idx + 4 .. idx + 6]) orelse return null;
        if (offset_hour > 23 or offset_minute > 59) return null;
        // RFC 3339 -00:00 means the local offset is unknown.
        if (s[idx] == '-' and offset_hour == 0 and offset_minute == 0) return null;
        offset = (offset_hour * 60 + offset_minute) * 60;
        if (s[idx] == '-') offset = -offset;
    } else return null;

    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(@intCast(year), @enumFromInt(m));
    return (days + day - 1) * 86400 + hour * 3600 + minute * 60 + second - offset;
}

fn decimal(s: []const u8) ?i64 {
    for (s) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

test "subscription timestamps handle offsets and fractional seconds" {
    const utc = parseTimestamp("2030-01-02T03:04:05Z").?;
    try std.testing.expectEqual(@as(i64, 1893553445), utc);
    try std.testing.expectEqual(utc, parseTimestamp("2030-01-02T03:04:05.123456+00:00").?);
    try std.testing.expectEqual(utc, parseTimestamp("2030-01-02T11:04:05+08:00").?);
    try std.testing.expectEqual(utc, parseTimestamp("2030-01-01T22:04:05-05:00").?);
    try std.testing.expect(parseTimestamp("2000-02-29T00:00:00Z") != null);
}

test "invalid subscription timestamps stay unknown" {
    const invalid = [_][]const u8{
        "",                          "2030-02-29T00:00:00Z",      "2100-02-29T00:00:00Z",      "2030-04-31T00:00:00Z",
        "2030-00-01T00:00:00Z",      "2030-01-00T00:00:00Z",      "2030-01-01T24:00:00Z",      "2030-01-01T00:60:00Z",
        "2030-01-01T00:00:60Z",      "2030-01-01T00:00:00",       "2030-01-01T00:00:00.Z",     "2030-01-01T00:00:00+24:00",
        "2030-01-01T00:00:00+00:60", "2030-01-01T00:00:00Zextra", "2030-01-01T00:00:00-00:00", "20x0-01-01T00:00:00Z",
    };
    for (invalid) |s| try std.testing.expect(parseTimestamp(s) == null);
}
