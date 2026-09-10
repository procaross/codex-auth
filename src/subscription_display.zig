const std = @import("std");
const auth = @import("auth.zig");
const registry = @import("registry.zig");
const subscription = @import("subscription.zig");

/// Read metadata on demand so all stored accounts work without a registry migration.
/// This function performs no requests, token refreshes, or writes.
pub fn loadSnapshots(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const registry.Registry,
) ![]subscription.Snapshot {
    const snapshots = try allocator.alloc(subscription.Snapshot, reg.accounts.items.len);
    errdefer allocator.free(snapshots);
    for (reg.accounts.items, snapshots) |rec, *snapshot| {
        snapshot.* = .{};
        if (rec.auth_mode == .apikey) continue;
        const is_active = if (reg.active_account_key) |key| std.mem.eql(u8, key, rec.account_key) else false;
        const path = if (is_active)
            try registry.activeAuthPath(allocator, codex_home)
        else
            try registry.accountAuthPath(allocator, codex_home, rec.account_key);
        defer allocator.free(path);
        const info = auth.parseAuthInfo(allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer info.deinit(allocator);
        const key = info.record_key orelse continue;
        // A file replaced during a switch must not attach another account's dates.
        if (!std.mem.eql(u8, key, rec.account_key)) continue;
        snapshot.* = info.subscription;
    }
    return snapshots;
}
