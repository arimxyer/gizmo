const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const build_config = @import("../build_config.zig");

pub const Options = struct {
    /// GTK application ID or unique session-bus name of the running instance.
    class: ?[:0]const u8 = null,
    /// JSON object with method and optional params. Defaults to discovery.
    request: []const u8 = "{\"method\":\"discover\"}",
    pub fn help(_: Options) !void {
        return Action.help_error;
    }
    pub fn deinit(_: *Options) void {}
};

/// Control a running Gizmo Linux instance with authenticated JSON over D-Bus.
///
/// Start the application with GIZMO_AGENT_TOKEN set to a secret of 32 or more
/// bytes. Without this variable, the control endpoint does not exist.
/// Use a randomly generated capability, not a password used elsewhere.
/// The endpoint shares the application's session bus identity (--class).
/// A unique D-Bus name also works with --class=:1.123 for non-unique instances.
///
/// D-Bus interface: org.gizmo.Agent1
/// Object path: /org/gizmo/Agent1
/// Method: Request(s JSON) -> (s JSON)
/// Request: {"token":"capability","method":"tree","params":{}}
/// Success: {"ok":true,"result":...}
/// Failure: D-Bus error org.gizmo.Agent1.Error with a stable error identifier.
/// CLI failures print {"ok":false,"error":"..."} and exit nonzero.
/// Requests are limited to 1 MiB. Responses are limited to 16 MiB.
/// This client reads GIZMO_AGENT_TOKEN and adds it to the request automatically.
/// No requests, terminal text, or capability values are logged.
///
/// Examples:
///   ghostty +agent-control --class=org.example.Gizmo --request='{"method":"tree"}'
///   ghostty +agent-control --request='{"method":"screen.read","params":{"surface":"123","region":"viewport"}}'
///   ghostty +agent-control --request='{"method":"action","params":{"surface":"123","action":"new_split:right"}}'
///   ghostty +agent-control --request='{"method":"input.text","params":{"surface":"123","text":"printf hello\\n"}}'
///   ghostty +agent-control --request='{"method":"config.set","params":{"text":"font-size = 16"}}'
///
/// discover returns all method, binding-action, physical-key, GTK-action and
/// config schemas. tree returns stable surface IDs and window/tab/split layout.
/// ui.tree includes native widgets and dialogs. screen.capture returns PNG/base64
/// for rendered GTK windows, including graphics not represented in plain text.
/// Configuration edits are session-only unless persist_path explicitly names an
/// absolute file. Persistence atomically replaces that file with canonical config.
/// config.reset restores defaults. config.reload reloads files and launch options.
/// Existing options that only affect new terminals keep those existing semantics.
/// Tools and workflows execute only from explicit requests or panel invocations.
/// Only supported on Linux GTK. No TCP listener is created.
pub fn run(alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    var iter = try args.argsIterator(alloc, global.args());
    defer iter.deinit();
    try args.parse(Options, alloc, &opts, &iter);
    if (comptime builtin.os.tag != .linux or build_config.app_runtime != .gtk) {
        return fail(alloc, "UnsupportedPlatform");
    } else {
        return runGTK(alloc, opts) catch |err| fail(alloc, @errorName(err));
    }
}

fn fail(alloc: std.mem.Allocator, message: []const u8) !u8 {
    const json = try std.json.Stringify.valueAlloc(alloc, .{ .ok = false, .@"error" = message }, .{});
    defer alloc.free(json);
    try print(json);
    return 1;
}
fn print(text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(global.io(), &buffer);
    try output.interface.writeAll(text);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
fn runGTK(alloc: std.mem.Allocator, opts: Options) !u8 {
    const gio = @import("gio");
    const glib = @import("glib");
    const control = @import("../apprt/gtk/agent_control.zig");
    const info = @import("../apprt/gtk/build/info.zig");
    const token = global.environ().getPosix("GIZMO_AGENT_TOKEN") orelse return error.AuthenticationRequired;
    if (opts.request.len > control.max_request) return error.RequestTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, opts.request, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.ExpectedRequestObject;
    try parsed.value.object.put(parsed.arena.allocator(), "token", .{ .string = token });
    const json = try std.json.Stringify.valueAlloc(alloc, parsed.value, .{});
    defer alloc.free(json);
    if (json.len > control.max_request) return error.RequestTooLarge;
    const terminated = try alloc.dupeSentinel(u8, json, 0);
    defer alloc.free(terminated);
    var gerr: ?*glib.Error = null;
    defer if (gerr) |e| e.free();
    const connection = gio.busGetSync(.session, null, &gerr) orelse return error.SessionBusUnavailable;
    defer connection.unref();
    const reply = connection.callSync(opts.class orelse info.application_id, control.object_path, control.interface, "Request", glib.Variant.new("(s)", terminated.ptr), null, .{ .no_auto_start = true }, 30000, null, &gerr) orelse {
        return fail(alloc, if (gerr) |e| std.mem.span(e.f_message orelse "RequestFailed") else "RequestFailed");
    };
    defer reply.unref();
    const child = reply.getChildValue(0);
    defer child.unref();
    var len: usize = 0;
    const text = child.getString(&len)[0..len];
    if (len > control.max_response) return error.ResponseTooLarge;
    try print(text);
    return 0;
}
