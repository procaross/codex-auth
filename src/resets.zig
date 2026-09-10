const std = @import("std");
const cli = @import("cli.zig");
const chatgpt_http = @import("chatgpt_http.zig");

// Node is already the HTTP runtime for this CLI. Keep the public feed separate
// from the authenticated ChatGPT client: no auth file or account headers here.
pub fn run(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ResetOptions) !void {
    const node = try chatgpt_http.resolveNodeExecutableForDebugAlloc(allocator);
    defer allocator.free(node);
    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("NODE_USE_ENV_PROXY", "1");
    if (env.get("ALL_PROXY") orelse env.get("all_proxy")) |proxy| {
        if (env.get("HTTP_PROXY") == null and env.get("http_proxy") == null) try env.put("HTTP_PROXY", proxy);
        if (env.get("HTTPS_PROXY") == null and env.get("https_proxy") == null) try env.put("HTTPS_PROXY", proxy);
    }
    const script = @embedFile("resets.mjs") ++ "\nawait main(process.argv.slice(1));\n";
    var child = std.process.Child.init(&.{
        node,
        "--input-type=module",
        "-e",
        script,
        @tagName(opts.action),
        codex_home,
        exe,
        if (opts.cached) "cached" else "online",
        if (opts.json) "json" else "text",
    }, allocator);
    child.env_map = &env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ResetCommandFailed,
        else => return error.ResetCommandFailed,
    }
}
