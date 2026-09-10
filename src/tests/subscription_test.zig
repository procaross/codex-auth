const std = @import("std");
const auth = @import("../auth.zig");
const registry = @import("../registry.zig");
const subscription = @import("../subscription.zig");
const display = @import("../subscription_display.zig");
const bdd = @import("bdd_helpers.zig");

pub fn fixture(allocator: std.mem.Allocator, account_id: []const u8, until: []const u8, checked: []const u8) ![]u8 {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"fixture@example.com\",\"exp\":4102444800,\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_user_id\":\"user-fixture\",\"chatgpt_plan_type\":\"pro\",\"chatgpt_subscription_active_until\":{s},\"chatgpt_subscription_last_checked\":{s}}}}}",
        .{ account_id, until, checked },
    );
    defer allocator.free(payload);
    const encoded = try bdd.b64url(allocator, payload);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "{{\"tokens\":{{\"account_id\":\"{s}\",\"id_token\":\"e30.{s}.test\"}}}}", .{ account_id, encoded });
}

test "subscription metadata is decoded from ID token and never from token exp" {
    const allocator = std.testing.allocator;
    const data = try fixture(allocator, "account-a", "\"2030-01-02T03:04:05+00:00\"", "\"2030-01-01T03:04:05.123456+00:00\"");
    defer allocator.free(data);
    const info = try auth.parseAuthInfoData(allocator, data);
    defer info.deinit(allocator);
    try std.testing.expectEqual(@as(?i64, 1893553445), info.subscription.valid_until);
    try std.testing.expectEqual(@as(?i64, 1893467045), info.subscription.checked_at);

    for ([_][]const u8{ "null", "false", "123", "{}", "[]", "\"bad date\"", "\"\"" }) |invalid| {
        const invalid_data = try fixture(allocator, "account-a", invalid, invalid);
        defer allocator.free(invalid_data);
        const invalid_info = try auth.parseAuthInfoData(allocator, invalid_data);
        defer invalid_info.deinit(allocator);
        try std.testing.expect(invalid_info.subscription.valid_until == null);
        try std.testing.expect(invalid_info.subscription.checked_at == null);
    }
    const legacy_data = try bdd.authJsonWithEmailPlan(allocator, "old@example.com", "plus");
    defer allocator.free(legacy_data);
    const legacy = try auth.parseAuthInfoData(allocator, legacy_data);
    defer legacy.deinit(allocator);
    try std.testing.expect(legacy.subscription.valid_until == null);
}

test "subscription snapshots read active and stored accounts without writes or cross-account dates" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var reg = try registry.loadRegistry(allocator, root);
    defer reg.deinit(allocator);
    try tmp.dir.makePath("accounts");
    const active = try fixture(allocator, "account-a", "\"2030-01-02T03:04:05Z\"", "null");
    defer allocator.free(active);
    const stored = try fixture(allocator, "account-b", "\"2030-02-02T03:04:05Z\"", "null");
    defer allocator.free(stored);
    for ([_][]const u8{ active, stored }) |data| {
        const info = try auth.parseAuthInfoData(allocator, data);
        defer info.deinit(allocator);
        try registry.upsertAccount(allocator, &reg, try registry.accountFromAuth(allocator, "", &info));
    }
    try registry.setActiveAccountKey(allocator, &reg, "user-fixture::account-a");
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = active });
    const stored_path = try registry.accountAuthPath(allocator, root, "user-fixture::account-b");
    defer allocator.free(stored_path);
    try std.fs.cwd().writeFile(.{ .sub_path = stored_path, .data = stored });
    const snapshots = try display.loadSnapshots(allocator, root, &reg);
    defer allocator.free(snapshots);
    try std.testing.expectEqual(subscription.parseTimestamp("2030-01-02T03:04:05Z"), snapshots[0].valid_until);
    try std.testing.expectEqual(subscription.parseTimestamp("2030-02-02T03:04:05Z"), snapshots[1].valid_until);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("accounts/registry.json", .{}));
    const saved = try bdd.readFileAlloc(allocator, stored_path);
    defer allocator.free(saved);
    try std.testing.expectEqualStrings(stored, saved);

    // A concurrent switch and a misplaced snapshot must both yield unknown.
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = stored });
    try std.fs.cwd().writeFile(.{ .sub_path = stored_path, .data = active });
    const mismatched = try display.loadSnapshots(allocator, root, &reg);
    defer allocator.free(mismatched);
    for (mismatched) |snapshot| try std.testing.expect(snapshot.valid_until == null);

    try tmp.dir.deleteFile("auth.json");
    try std.fs.cwd().writeFile(.{ .sub_path = stored_path, .data = "not json" });
    const missing = try display.loadSnapshots(allocator, root, &reg);
    defer allocator.free(missing);
    for (missing) |snapshot| try std.testing.expect(snapshot.valid_until == null);
}
