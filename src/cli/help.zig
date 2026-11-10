const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");

// Note that this options struct doesn't implement the `help` decl like other
// actions. That is because the help command is special and wants to handle its
// own logic around help detection.
pub const Options = struct {
    /// This must be registered so that it isn't an error to pass `--help`
    help: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

/// The `help` command shows general help for Gizmo.
/// Use `COMMAND --help` or `+ACTION --help` for command help.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(global.io(), &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\Usage: gizmo [COMMAND | +ACTION] [options]
        \\
        \\No arguments launch the Gizmo terminal application.
        \\Use configuration options such as --font-size=12 or --font-family="Fira Code".
        \\Use `gizmo -e COMMAND [ARGS...]` to run a command inside the terminal.
        \\
        \\Lifecycle:
        \\  start [-- LAUNCH_ARGUMENTS...]   Launch an independent controlled application.
        \\  stop [--instance ID]            Request normal quit and wait for process exit.
        \\  restart [--instance ID]         Preserve launch arguments and cwd, not sessions.
        \\  instances                       List authenticated running instances.
        \\  --class CLASS                   Select a class for stop/restart or live control.
        \\
        \\Configuration and extension definitions:
        \\  config get|set|reset|validate    Use saved files without a running application.
        \\  extensions discover|list|install|update|remove|inspect|export
        \\                                  Use saved extension definitions and state.
        \\  --live                          Explicitly select the running application.
        \\  config reload                   Reload the running application.
        \\  extensions invoke|context|save|load
        \\                                  Operate on the running application.
        \\Saved changes become active at the next application startup.
        \\
        \\Live control:
        \\  inspect, tabs list, terminal read|send|key|action|status
        \\  agent list|discover|request|enable|disable
        \\Use --instance ID when multiple controlled applications match.
        \\Use `gizmo +agent-control --help` for complete control and lifecycle usage.
        \\
        \\Utilities accept bare names and the existing +ACTION form:
        \\
    );

    inline for (@typeInfo(Action).@"enum".field_names) |field| {
        try stdout.print("  {s}\n", .{field});
    }

    try stdout.writeAll(
        \\
        \\Use `COMMAND --help` or `+ACTION --help` for command help.
        \\
    );
    try stdout.flush();

    return 0;
}
