const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const Action = @import("ghostty.zig").Action;
const build_config = @import("../build_config.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Options = struct {
    class: ?[:0]const u8 = null,
    instance: ?[]const u8 = null,
    request: ?[]const u8 = null,
    @"request-file": ?[]const u8 = null,
    live: bool = false,
    pub fn help(_: Options) !void {
        return Action.help_error;
    }
    pub fn deinit(_: *Options) void {}
};

pub fn directCommand(arg: []const u8) bool {
    inline for (.{ "inspect", "tabs", "terminal", "config", "extensions", "agent", "start", "stop", "restart", "instances" }) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

/// Unified Gizmo command line. No arguments launch the terminal application.
///
/// Commands:
///   gizmo start [-- LAUNCH_ARGUMENTS...]
///   gizmo stop|restart [--instance ID | --class CLASS]
///   gizmo instances
///   gizmo inspect
///   gizmo tabs list
///   gizmo terminal read SURFACE [--region=viewport|active|history|screen]
///   gizmo terminal send SURFACE [TEXT | --text-file=PATH | --text-file=-]
///   gizmo terminal key SURFACE KEY [--ctrl=true --shift=true --event=press]
///   gizmo terminal action SURFACE ACTION
///   gizmo terminal status SURFACE [--id=PROGRAM_ID]
///   gizmo config get [KEY]
///   gizmo config set [KEY VALUE | --text=CONFIG | --text-file=PATH]
///   gizmo config reset KEY
///   gizmo config validate
///   gizmo config reload
///   gizmo extensions discover|list|install|update|remove|inspect|export [ID]
///   gizmo extensions invoke|context|save|load [ID]
///   gizmo agent list|discover|request|enable|disable
///
/// Config and extension definition commands use saved files by default.
/// Saved writes take effect at the next startup, not in running applications.
/// --live or --live=true selects runtime operations; --live=false selects saved data.
/// config reload and extensions invoke/context/save/load always use a running app.
/// Saved operations reject --instance and --class without --live.
///
/// start creates an independent, controlled process without changing saved files.
/// It enables session control and enforces gtk-single-instance=false before -e or --.
/// Launch flags include --class=APP_ID; class does not select an existing process.
/// stop requests normal quit and waits up to 30 seconds for actual process exit.
/// Native close confirmation remains active. A timeout never forces a close.
/// restart preserves executable, launch arguments and working directory, not sessions.
/// A replacement starts only after the original process exits.
///
/// Live commands accept --instance ID, --class CLASS, --params=JSON,
/// --params-file=PATH, and arbitrary --key=value parameters.
/// File arguments accept '-' for stdin. No shell command parsing occurs.
/// agent enable/disable change the preferred saved config; disable also revokes
/// the selected running instance. Multiple matches require --instance.
///
/// Advanced API: gizmo +agent-control --request=JSON [--class=BUS_NAME].
/// --request-file=PATH accepts a complete request. GIZMO_AGENT_TOKEN supplies
/// an explicit manual credential. Normal discovery needs no environment token.
/// Private records use $XDG_RUNTIME_DIR/gizmo, directory 0700 and files 0600.
/// The client validates ownership, permissions, links and the authenticated bus PID.
/// JSON envelopes use {ok:true,result} or {ok:false,error}; failures exit nonzero.
/// Request limit: 1 MiB. Response limit: 16 MiB. Credentials are never printed.
pub fn run(alloc: Allocator) !u8 {
    if (comptime builtin.os.tag != .linux or build_config.app_runtime != .gtk) {
        return fail(alloc, "UnsupportedPlatform");
    } else {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        return runGTK(arena.allocator()) catch |err| switch (err) {
            Action.help_error => return err,
            else => fail(alloc, @errorName(err)),
        };
    }
}

fn fail(alloc: Allocator, message: []const u8) !u8 {
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
fn fileText(alloc: Allocator, path: []const u8, limit: usize) ![]const u8 {
    const file = if (std.mem.eql(u8, path, "-")) std.Io.File.stdin() else try std.Io.Dir.cwd().openFile(global.io(), path, .{});
    defer if (!std.mem.eql(u8, path, "-")) file.close(global.io());
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(global.io(), &buffer);
    return reader.interface.allocRemaining(alloc, .limited(limit));
}
fn object(alloc: Allocator, text: []const u8) !Value {
    const value = try std.json.parseFromSliceLeaky(Value, alloc, text, .{ .allocate = .alloc_always });
    if (value != .object) return error.ExpectedObject;
    return value;
}
fn put(alloc: Allocator, value: *Value, key: []const u8, text: []const u8) !void {
    try value.object.put(alloc, key, .{ .string = text });
}

/// Remove the backend selector only at argv[1], never from request data.
fn RequestIterator(comptime Iterator: type) type {
    return struct {
        iterator: Iterator,
        first: bool = true,

        pub fn next(self: *@This()) ?[]const u8 {
            const arg = self.iterator.next() orelse return null;
            if (self.first) {
                self.first = false;
                if (std.mem.eql(u8, arg, "+agent-control") or std.mem.eql(u8, arg, "agent-control"))
                    return self.iterator.next();
            }
            return arg;
        }

        pub fn deinit(self: *@This()) void {
            self.iterator.deinit();
        }
    };
}

fn runGTK(alloc: Allocator) !u8 {
    const gio = @import("gio");
    const glib = @import("glib");
    const discovery = @import("../agent_discovery.zig");
    const control = @import("../apprt/gtk/agent_control.zig");
    var raw_args = try global.args().iterateAllocator(alloc);
    _ = raw_args.next();
    var iter: RequestIterator(@TypeOf(raw_args)) = .{ .iterator = raw_args };
    defer iter.deinit();
    var positional: std.ArrayList([]const u8) = .empty;
    var params: Value = .{ .object = .empty };
    var opts: Options = .{};
    var params_text: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var fields: std.ArrayList(struct { key: []const u8, value: []const u8 }) = .empty;
    while (iter.next()) |arg| {
        if (positional.items.len == 0 and std.mem.eql(u8, arg, "start")) return startCommand(alloc, &iter);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return Action.help_error;
        if (!std.mem.startsWith(u8, arg, "--")) {
            try positional.append(alloc, arg);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const key = if (eq) |n| arg[2..n] else arg[2..];
        if (std.mem.eql(u8, key, "live")) {
            const value = if (eq) |n| arg[n + 1 ..] else "true";
            if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.ExpectedBoolean;
            opts.live = std.mem.eql(u8, value, "true");
            continue;
        }
        const value = if (eq) |n| arg[n + 1 ..] else iter.next() orelse return error.OptionValueRequired;
        if (std.mem.eql(u8, key, "instance")) opts.instance = value else if (std.mem.eql(u8, key, "class")) opts.class = try alloc.dupeSentinel(u8, value, 0) else if (std.mem.eql(u8, key, "request")) opts.request = value else if (std.mem.eql(u8, key, "request-file")) opts.@"request-file" = value else if (std.mem.eql(u8, key, "params")) params_text = value else if (std.mem.eql(u8, key, "params-file")) params_text = try fileText(alloc, value, control.max_request) else if (std.mem.eql(u8, key, "text")) text = value else if (std.mem.eql(u8, key, "text-file")) text = try fileText(alloc, value, control.max_request) else try fields.append(alloc, .{ .key = key, .value = value });
    }
    if (opts.request != null and opts.@"request-file" != null) return error.ConflictingRequestSources;
    if (params_text) |raw| params = try object(alloc, raw);
    for (fields.items) |field| {
        const is_bool = std.mem.eql(u8, field.key, "ctrl") or std.mem.eql(u8, field.key, "shift") or std.mem.eql(u8, field.key, "alt") or std.mem.eql(u8, field.key, "super") or std.mem.eql(u8, field.key, "docs") or std.mem.eql(u8, field.key, "precision");
        if (is_bool) {
            if (!std.mem.eql(u8, field.value, "true") and !std.mem.eql(u8, field.value, "false")) return error.ExpectedBoolean;
            try params.object.put(alloc, field.key, .{ .bool = std.mem.eql(u8, field.value, "true") });
        } else try put(alloc, &params, field.key, field.value);
    }
    if (text) |v| try put(alloc, &params, "text", v);
    const words = positional.items;
    var method: []const u8 = "discover";
    var local: enum { none, list, enable, disable } = .none;
    var saved: enum { none, config, extensions } = .none;
    var saved_verb: []const u8 = "";
    var lifecycle_command: enum { none, stop, restart } = .none;
    if (words.len != 0) {
        const command = words[0];
        const verb = if (words.len > 1) words[1] else "";
        if (std.mem.eql(u8, command, "inspect")) {
            if (words.len != 1) return error.UnexpectedArgument;
            method = "tree";
        } else if (std.mem.eql(u8, command, "tabs")) {
            if (words.len != 2 or !std.mem.eql(u8, verb, "list")) return error.ExpectedTabsList;
            method = "tree";
        } else if (std.mem.eql(u8, command, "terminal")) {
            if (words.len > 4) return error.UnexpectedArgument;
            if (words.len > 2) try put(alloc, &params, "surface", words[2]);
            if (std.mem.eql(u8, verb, "read")) method = "screen.read" else if (std.mem.eql(u8, verb, "send")) {
                method = "input.text";
                if (words.len > 3) try put(alloc, &params, "text", words[3]);
            } else if (std.mem.eql(u8, verb, "key")) {
                method = "input.key";
                if (words.len > 3) try put(alloc, &params, "key", words[3]);
            } else if (std.mem.eql(u8, verb, "action")) {
                method = "action";
                if (words.len > 3) try put(alloc, &params, "action", words[3]);
            } else if (std.mem.eql(u8, verb, "status")) method = if (params.object.contains("id")) "status.get" else "status.list" else return error.UnknownTerminalCommand;
        } else if (std.mem.eql(u8, command, "config")) {
            if (words.len > 4) return error.UnexpectedArgument;
            if ((std.mem.eql(u8, verb, "get") or std.mem.eql(u8, verb, "reset")) and words.len > 3) return error.UnexpectedArgument;
            if ((std.mem.eql(u8, verb, "validate") or std.mem.eql(u8, verb, "reload")) and words.len != 2) return error.UnexpectedArgument;
            if (std.mem.eql(u8, verb, "get")) {
                method = "config.get";
                if (words.len > 2) try put(alloc, &params, "key", words[2]);
            } else if (std.mem.eql(u8, verb, "set")) {
                method = "config.set";
                if (words.len > 2) {
                    const line = if (words.len == 4) try alloc.print("{s} = {s}\n", .{ words[2], words[3] }) else words[2];
                    try put(alloc, &params, "text", line);
                }
            } else if (std.mem.eql(u8, verb, "reset")) {
                if (opts.live) {
                    method = if (words.len > 2) "config.set" else "config.reset";
                    if (words.len > 2) try put(alloc, &params, "text", try alloc.print("{s} =\n", .{words[2]}));
                } else if (words.len > 2) try put(alloc, &params, "key", words[2]);
            } else if (std.mem.eql(u8, verb, "validate")) {
                method = "config.validate";
            } else if (std.mem.eql(u8, verb, "reload")) method = "config.reload" else return error.UnknownConfigCommand;
            if (!opts.live and !std.mem.eql(u8, verb, "reload")) {
                saved = .config;
                saved_verb = verb;
            }
        } else if (std.mem.eql(u8, command, "extensions")) {
            if (words.len < 2 or words.len > 3) return error.ExpectedExtensionCommand;
            method = try alloc.print("extensions.{s}", .{verb});
            if (words.len == 3) try put(alloc, &params, "id", words[2]);
            const inherent_live = std.mem.eql(u8, verb, "invoke") or std.mem.eql(u8, verb, "context") or std.mem.eql(u8, verb, "save") or std.mem.eql(u8, verb, "load");
            if (!opts.live and !inherent_live) {
                saved = .extensions;
                saved_verb = verb;
            }
        } else if (std.mem.eql(u8, command, "agent")) {
            if (words.len != 2) return error.ExpectedAgentCommand;
            if (std.mem.eql(u8, verb, "enable")) local = .enable else if (std.mem.eql(u8, verb, "disable")) local = .disable else if (std.mem.eql(u8, verb, "list")) local = .list else if (!std.mem.eql(u8, verb, "discover") and !std.mem.eql(u8, verb, "request")) return error.UnknownAgentCommand;
        } else if (std.mem.eql(u8, command, "instances")) {
            if (words.len != 1) return error.UnexpectedArgument;
            local = .list;
        } else if (std.mem.eql(u8, command, "stop") or std.mem.eql(u8, command, "restart")) {
            if (words.len != 1) return error.UnexpectedArgument;
            lifecycle_command = if (std.mem.eql(u8, command, "stop")) .stop else .restart;
        } else return error.UnknownCommand;
    }
    if (local != .none and (opts.request != null or opts.@"request-file" != null)) return error.RequestNotAllowedForLocalCommand;
    if (saved != .none) {
        if (opts.instance != null or opts.class != null) return error.SavedOperationDoesNotAcceptInstanceUseLive;
        if (opts.request != null or opts.@"request-file" != null) return error.RequestNotAllowedForSavedOperation;
        const result = switch (saved) {
            .config => try @import("saved_config.zig").request(alloc, saved_verb, params),
            .extensions => try @import("saved_extensions.zig").request(alloc, saved_verb, params),
            .none => unreachable,
        };
        return success(alloc, result);
    }
    if (lifecycle_command != .none and (opts.request != null or opts.@"request-file" != null)) return error.RequestNotAllowedForLifecycle;
    if (local == .enable) {
        if (opts.instance != null or opts.class != null) return error.SavedOperationDoesNotAcceptInstance;
        return success(alloc, try @import("saved_config.zig").setAgentControl(alloc, true));
    }
    var gerr: ?*glib.Error = null;
    defer if (gerr) |e| e.free();
    const connection = gio.busGetSync(.session, null, &gerr) orelse {
        if (local == .disable and opts.instance == null and opts.class == null) {
            return success(alloc, try @import("saved_config.zig").setAgentControl(alloc, false));
        }
        return error.SessionBusUnavailable;
    };
    defer connection.unref();
    var records: std.ArrayList(discovery.Record) = .empty;
    const manual_fallback = lifecycle_command == .none and local == .none and opts.instance == null and global.environ().getPosix("GIZMO_AGENT_TOKEN") != null;
    const manual = manual_fallback and opts.class != null;
    const dir = if (manual) null else discovery.openDirectory(alloc, false) catch |err| switch (err) {
        error.FileNotFound => null,
        error.XdgRuntimeDirectoryRequired => if (manual_fallback or (local == .disable and opts.instance == null and opts.class == null)) null else return err,
        else => return err,
    };
    if (dir) |d| {
        defer d.close(global.io());
        var entries = d.iterate();
        while (try entries.next(global.io())) |entry| {
            const record = discovery.readRecord(alloc, d, entry.name) catch continue;
            if (try live(alloc, connection, record.bus_name, record.pid)) try records.append(alloc, record);
        }
    }
    if (local == .list) {
        const Metadata = discovery.Metadata;
        var result: std.ArrayList(Metadata) = .empty;
        for (records.items) |r| {
            if (opts.instance) |id| if (!std.mem.eql(u8, id, r.instance)) continue;
            if (opts.class) |class| if (!std.mem.eql(u8, class, r.app_class) and !std.mem.eql(u8, class, r.bus_name)) continue;
            try result.append(alloc, r.metadata());
        }
        try print(try std.json.Stringify.valueAlloc(alloc, .{ .ok = true, .result = result.items }, .{}));
        return 0;
    }
    var selected: ?discovery.Record = null;
    for (records.items) |r| {
        if (opts.instance) |id| if (!std.mem.eql(u8, id, r.instance)) continue;
        if (opts.class) |class| if (!std.mem.eql(u8, class, r.app_class) and !std.mem.eql(u8, class, r.bus_name)) continue;
        if (selected != null) return error.AmbiguousInstanceUseInstanceOption;
        selected = r;
    }
    if (opts.instance != null and selected == null) return error.InstanceNotFound;
    if (local == .disable) {
        const saved_result = try @import("saved_config.zig").setAgentControl(alloc, false);
        if (selected == null and opts.class == null) {
            return success(alloc, saved_result);
        }
        method = "config.set";
        params = .{ .object = .empty };
        try put(alloc, &params, "text", "agent-control = false\n");
        try params.object.put(alloc, "revoke_agent_control", .{ .bool = true });
    }
    if (lifecycle_command != .none) {
        const record = selected orelse return error.NoEnabledInstance;
        const lifecycle = @import("lifecycle.zig");
        const fd = try lifecycle.openProcess(record.pid);
        defer _ = std.posix.system.close(fd);
        // Revalidate after pinning the process identity, before requesting quit.
        if (!try live(alloc, connection, record.bus_name, record.pid)) return error.InstanceExited;
        const launch = if (lifecycle_command == .restart) try remote(alloc, connection, record, "lifecycle.launch", .{ .object = .empty }) else null;
        if (launch) |reply| if (!try responseOK(alloc, reply)) {
            try print(reply);
            return 1;
        };
        const stopped = try remote(alloc, connection, record, "lifecycle.stop", .{ .object = .empty });
        if (!try responseOK(alloc, stopped)) {
            try print(stopped);
            return 1;
        }
        if (!try lifecycle.waitExit(fd, 30000)) return error.StopNotConfirmedBeforeTimeout;
        if (launch) |reply| {
            const root = try object(alloc, reply);
            const value = root.object.get("result") orelse return error.InvalidLaunchMetadata;
            const metadata = try std.json.parseFromValueLeaky(lifecycle.Launch, alloc, value, .{ .allocate = .alloc_always });
            return success(alloc, (try launchAndWait(alloc, connection, metadata)).metadata());
        }
        return success(alloc, .{ .stopped = true, .instance = record.instance, .pid = record.pid });
    }
    const destination = if (selected) |r| try alloc.dupeSentinel(u8, r.bus_name, 0) else opts.class orelse if (global.environ().getPosix("GIZMO_AGENT_TOKEN") != null) @import("../apprt/gtk/build/info.zig").application_id else return error.NoEnabledInstance;
    const token = if (selected) |r| r.token else global.environ().getPosix("GIZMO_AGENT_TOKEN") orelse return error.AuthenticationRequired;
    var request: Value = if (opts.@"request-file") |path| try object(alloc, try fileText(alloc, path, control.max_request)) else if (opts.request) |raw| try object(alloc, raw) else .{ .object = .empty };
    if (!request.object.contains("method")) try put(alloc, &request, "method", method);
    if (!request.object.contains("params")) try request.object.put(alloc, "params", params);
    try put(alloc, &request, "token", token);
    const response = try call(alloc, connection, destination, request);
    try print(response);
    return if (try responseOK(alloc, response)) 0 else 1;
}

fn live(alloc: Allocator, connection: *@import("gio").DBusConnection, name: []const u8, pid: u32) !bool {
    return liveTimeout(alloc, connection, name, pid, 2000);
}

fn liveTimeout(alloc: Allocator, connection: *@import("gio").DBusConnection, name: []const u8, pid: u32, timeout: i32) !bool {
    const glib = @import("glib");
    const z = try alloc.dupeSentinel(u8, name, 0);
    var gerr: ?*glib.Error = null;
    defer if (gerr) |e| e.free();
    const reply = connection.callSync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", glib.Variant.new("(s)", z.ptr), null, .{ .no_auto_start = true }, timeout, null, &gerr) orelse return false;
    defer reply.unref();
    const child = reply.getChildValue(0);
    defer child.unref();
    return child.getUint32() == pid;
}
fn success(alloc: Allocator, result: anytype) !u8 {
    try print(try std.json.Stringify.valueAlloc(alloc, .{ .ok = true, .result = result }, .{}));
    return 0;
}

fn responseOK(alloc: Allocator, response: []const u8) !bool {
    const root = try object(alloc, response);
    const ok = root.object.get("ok") orelse return error.InvalidResponseEnvelope;
    if (ok != .bool) return error.InvalidResponseEnvelope;
    return ok.bool;
}

fn call(alloc: Allocator, connection: *@import("gio").DBusConnection, destination: [:0]const u8, request: Value) ![]const u8 {
    return callTimeout(alloc, connection, destination, request, 30000);
}

fn callTimeout(alloc: Allocator, connection: *@import("gio").DBusConnection, destination: [:0]const u8, request: Value, timeout: i32) ![]const u8 {
    const glib = @import("glib");
    const control = @import("../apprt/gtk/agent_control.zig");
    const json = try std.json.Stringify.valueAlloc(alloc, request, .{});
    if (json.len > control.max_request) return error.RequestTooLarge;
    const terminated = try alloc.dupeSentinel(u8, json, 0);
    var gerr: ?*glib.Error = null;
    defer if (gerr) |err| err.free();
    const reply = connection.callSync(destination, control.object_path, control.interface, "Request", glib.Variant.new("(s)", terminated.ptr), null, .{ .no_auto_start = true }, timeout, null, &gerr) orelse {
        return std.json.Stringify.valueAlloc(alloc, .{ .ok = false, .@"error" = if (gerr) |err| std.mem.span(err.f_message orelse "RequestFailed") else "RequestFailed" }, .{});
    };
    defer reply.unref();
    const child = reply.getChildValue(0);
    defer child.unref();
    var len: usize = 0;
    const response = child.getString(&len)[0..len];
    if (len > control.max_response) return error.ResponseTooLarge;
    return alloc.dupe(u8, response);
}

fn remote(alloc: Allocator, connection: *@import("gio").DBusConnection, record: @import("../agent_discovery.zig").Record, method: []const u8, params: Value) ![]const u8 {
    return remoteTimeout(alloc, connection, record, method, params, 30000);
}

fn remoteTimeout(alloc: Allocator, connection: *@import("gio").DBusConnection, record: @import("../agent_discovery.zig").Record, method: []const u8, params: Value, timeout: i32) ![]const u8 {
    var request: Value = .{ .object = .empty };
    try put(alloc, &request, "method", method);
    try put(alloc, &request, "token", record.token);
    try request.object.put(alloc, "params", params);
    return callTimeout(alloc, connection, try alloc.dupeSentinel(u8, record.bus_name, 0), request, timeout);
}

fn startCommand(alloc: Allocator, iter: anytype) !u8 {
    const gio = @import("gio");
    const glib = @import("glib");
    const lifecycle = @import("lifecycle.zig");
    var argv: std.ArrayList([]const u8) = .empty;
    const exe = try lifecycle.executable(alloc);
    try argv.append(alloc, exe);
    var first = true;
    while (iter.next()) |arg| {
        if (first and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) return Action.help_error;
        if (first and std.mem.eql(u8, arg, "--")) {
            first = false;
            continue;
        }
        first = false;
        try argv.append(alloc, arg);
    }
    var gerr: ?*glib.Error = null;
    defer if (gerr) |err| err.free();
    const connection = gio.busGetSync(.session, null, &gerr) orelse return error.SessionBusUnavailable;
    defer connection.unref();
    return success(alloc, (try launchAndWait(alloc, connection, .{
        .executable = exe,
        .argv = argv.items,
        .cwd = try std.process.currentPathAlloc(global.io(), alloc),
    })).metadata());
}

fn launchAndWait(alloc: Allocator, connection: *@import("gio").DBusConnection, launch: @import("lifecycle.zig").Launch) !@import("../agent_discovery.zig").Record {
    const discovery = @import("../agent_discovery.zig");
    const lifecycle = @import("lifecycle.zig");
    const argv = try controlledArguments(alloc, launch.executable, launch.argv);
    // Reject unsafe runtime-directory state before creating an application.
    const dir = try discovery.openDirectory(alloc, true);
    defer dir.close(global.io());
    const child = try lifecycle.spawn(alloc, .{ .executable = launch.executable, .argv = argv, .cwd = launch.cwd });
    defer child.deinit();
    errdefer child.rollback();
    const fd = try lifecycle.openProcess(child.pid);
    defer _ = std.posix.system.close(fd);
    const deadline = std.Io.Timestamp.now(global.io(), .awake).nanoseconds + 15 * std.time.ns_per_s;
    while (std.Io.Timestamp.now(global.io(), .awake).nanoseconds < deadline) {
        if (try lifecycle.waitExit(fd, 0)) return error.ApplicationExitedBeforeReady;
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const scratch = arena.allocator();
        var entries = dir.iterate();
        while (try entries.next(global.io())) |entry| {
            _ = try readinessRemaining(deadline);
            const record = discovery.readRecord(scratch, dir, entry.name) catch continue;
            if (record.pid != child.pid or !try liveTimeout(scratch, connection, record.bus_name, record.pid, @min(2000, try readinessRemaining(deadline)))) continue;
            const response = try remoteTimeout(scratch, connection, record, "discover", .{ .object = .empty }, try readinessRemaining(deadline));
            _ = try readinessRemaining(deadline);
            if (!try responseOK(scratch, response)) return error.ApplicationReadinessFailed;
            // Copy only the selected authenticated record into the request arena.
            const result = try std.json.parseFromSliceLeaky(discovery.Record, alloc, try std.json.Stringify.valueAlloc(scratch, record, .{}), .{ .allocate = .alloc_always });
            _ = try readinessRemaining(deadline);
            if (try lifecycle.waitExit(fd, 0)) return error.ApplicationExitedBeforeReady;
            return result;
        }
        if (try lifecycle.waitExit(fd, @min(100, try readinessRemaining(deadline)))) return error.ApplicationExitedBeforeReady;
    }
    return error.ApplicationReadinessTimeout;
}

fn readinessRemaining(deadline: i96) !i32 {
    const remaining = deadline - std.Io.Timestamp.now(global.io(), .awake).nanoseconds;
    if (remaining <= 0) return error.ApplicationReadinessTimeout;
    return @intCast(@min(std.math.maxInt(i32), @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
}

fn controlledArguments(alloc: Allocator, executable: []const u8, original: []const []const u8) ![]const []const u8 {
    if (original.len == 0) return error.InvalidLaunchMetadata;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, executable);
    var boundary: usize = original.len;
    for (original[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--")) {
            boundary = i;
            break;
        }
        if (std.mem.startsWith(u8, arg, "+") or std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return error.LaunchArgumentIsUtility;
        if (i == 1 and Action.detectDirectCommand(arg) != null) return error.LaunchArgumentIsUtility;
        if (std.mem.eql(u8, arg, "--instance") or std.mem.startsWith(u8, arg, "--instance=")) return error.StartDoesNotSelectExistingInstance;
        // Do not accumulate our own enforced flags across repeated restarts.
        if (std.mem.eql(u8, arg, "--gtk-single-instance=false")) continue;
        try argv.append(alloc, arg);
    }
    try argv.append(alloc, "--gtk-single-instance=false");
    if (boundary < original.len and std.mem.eql(u8, original[boundary], "--")) {
        try argv.append(alloc, "-e");
        try argv.appendSlice(alloc, original[boundary + 1 ..]);
    } else try argv.appendSlice(alloc, original[boundary..]);
    return argv.items;
}

test "controlled launch preserves terminal arguments after command boundary" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const actual = try controlledArguments(arena.allocator(), "/bin/gizmo", &.{
        "gizmo",  "--class=org.example.Gizmo",  "--font-size=17", "--agent-control=false",
        "-e",     "/bin/sh",                    "-c",             "printf '%s' \"$1\"",
        "config", "--gtk-single-instance=true",
    });
    const expected = [_][]const u8{
        "/bin/gizmo",                  "--class=org.example.Gizmo", "--font-size=17",             "--agent-control=false",
        "--gtk-single-instance=false", "-e",                        "/bin/sh",                    "-c",
        "printf '%s' \"$1\"",          "config",                    "--gtk-single-instance=true",
    };
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "controlled restart does not accumulate enforced flags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const first = try controlledArguments(arena.allocator(), "/bin/gizmo", &.{ "gizmo", "--font-size=17", "--", "/bin/sh", "--help" });
    const second = try controlledArguments(arena.allocator(), "/bin/gizmo", first);
    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "backend selector is removed only before the command" {
    const Iterator = std.process.Args.IteratorGeneral(.{});
    const raw = try Iterator.init(std.testing.allocator, "+agent-control config set agent-control false");
    var iter: RequestIterator(Iterator) = .{ .iterator = raw };
    defer iter.deinit();
    for ([_][]const u8{ "config", "set", "agent-control", "false" }) |expected|
        try std.testing.expectEqualStrings(expected, iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "terminal payload can equal a backend selector" {
    const Iterator = std.process.Args.IteratorGeneral(.{});
    const raw = try Iterator.init(std.testing.allocator, "terminal send 42 +agent-control");
    var iter: RequestIterator(Iterator) = .{ .iterator = raw };
    defer iter.deinit();
    for ([_][]const u8{ "terminal", "send", "42", "+agent-control" }) |expected|
        try std.testing.expectEqualStrings(expected, iter.next().?);
    try std.testing.expect(iter.next() == null);
}
