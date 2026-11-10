//! Opt-in Gizmo local agent control. D-Bus callbacks run on the GTK context.
//! No socket or network listener is created. Capability values are never logged.
const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gtk = @import("gtk");
const gobject = @import("gobject");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const configpkg = @import("../../config.zig");
const terminal = @import("../../terminal/main.zig");
const Application = @import("class/application.zig").Application;
const Surface = @import("class/surface.zig").Surface;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const ext = @import("ext.zig");
const extensions = @import("agent_extensions.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Self = @This();

pub const interface = "org.gizmo.Agent1";
pub const object_path = "/org/gizmo/Agent1";
pub const max_request = 1024 * 1024;
pub const max_response = 16 * 1024 * 1024;
const xml = "<node><interface name='org.gizmo.Agent1'><method name='Request'><arg name='json' type='s' direction='in'/><arg name='json' type='s' direction='out'/></method></interface></node>";

app: *Application,
connection: *gio.DBusConnection,
registration: c_uint,
node: *anyopaque,
token: []const u8,
next_id: usize = 1,
config_job: ?*ConfigJob = null,

// These declarations use the public GIO C ABI. Keeping the vtable here avoids
// depending on generated callback wrappers, which vary with zig-gobject.
const Method = *const fn (*gio.DBusConnection, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, *glib.Variant, *gio.DBusMethodInvocation, ?*anyopaque) callconv(.c) void;
const VTable = extern struct { method_call: ?Method, get_property: ?*const anyopaque = null, set_property: ?*const anyopaque = null, padding: [8]?*anyopaque = @splat(null) };
extern "c" fn g_dbus_node_info_new_for_xml([*:0]const u8, *?*glib.Error) ?*anyopaque;
extern "c" fn g_dbus_node_info_lookup_interface(*anyopaque, [*:0]const u8) ?*anyopaque;
extern "c" fn g_dbus_node_info_unref(*anyopaque) void;
extern "c" fn g_dbus_connection_register_object(*gio.DBusConnection, [*:0]const u8, *anyopaque, *const VTable, ?*anyopaque, ?*const fn (?*anyopaque) callconv(.c) void, *?*glib.Error) c_uint;
extern "c" fn g_object_get_data(*anyopaque, [*:0]const u8) ?*anyopaque;
extern "c" fn g_object_set_data(*anyopaque, [*:0]const u8, ?*anyopaque) void;
extern "c" fn g_type_name_from_instance(*anyopaque) [*:0]const u8;
extern "c" fn gtk_widget_activate_action_variant(*gtk.Widget, [*:0]const u8, ?*glib.Variant) c_int;
const vtable: VTable = .{ .method_call = onRequest };

pub fn init(app: *Application) !?*Self {
    const token = global.environ().getPosix("GIZMO_AGENT_TOKEN") orelse return null;
    // Setting a nonempty, sufficiently long secret is the explicit opt-in.
    if (token.len < 32 or token.len > 4096) return error.AgentTokenMustHaveAtLeast32Bytes;
    const connection = app.as(gio.Application).getDbusConnection() orelse return error.SessionBusUnavailable;
    const alloc = app.allocator();
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    const secret = try alloc.dupe(u8, token);
    errdefer alloc.free(secret);
    var gerr: ?*glib.Error = null;
    defer if (gerr) |e| e.free();
    const node = g_dbus_node_info_new_for_xml(xml, &gerr) orelse return error.AgentIntrospectionFailed;
    errdefer g_dbus_node_info_unref(node);
    self.* = .{ .app = app, .connection = connection, .registration = 0, .node = node, .token = secret };
    self.registration = g_dbus_connection_register_object(connection, object_path, g_dbus_node_info_lookup_interface(node, interface).?, &vtable, self, null, &gerr);
    if (self.registration == 0) return error.AgentRegistrationFailed;
    return self;
}

pub fn deinit(self: *Self) void {
    _ = self.connection.unregisterObject(self.registration);
    if (self.config_job) |job| {
        job.thread.?.join();
        if (job.source != 0) _ = glib.Source.remove(job.source);
        replyError(job.invocation, "ApplicationShuttingDown");
        job.destroy();
        self.config_job = null;
    }
    g_dbus_node_info_unref(self.node);
    const alloc = self.app.allocator();
    @memset(@constCast(self.token), 0);
    alloc.free(self.token);
    alloc.destroy(self);
}

fn onRequest(_: *gio.DBusConnection, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, args: *glib.Variant, invocation: *gio.DBusMethodInvocation, userdata: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(userdata.?));
    const arg = args.getChildValue(0);
    defer arg.unref();
    var len: usize = 0;
    const raw = arg.getString(&len)[0..len];
    if (len > max_request) return replyError(invocation, "RequestTooLarge");
    var arena: std.heap.ArenaAllocator = .init(self.app.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();
    const parsed = std.json.parseFromSlice(Value, alloc, raw, .{ .max_value_len = max_request }) catch return replyError(invocation, "InvalidJSON");
    const root = parsed.value;
    if (root != .object) return replyError(invocation, "ExpectedRequestObject");
    const token = string(root, "token") catch return replyError(invocation, "AuthenticationRequired");
    // Compare all bytes of an equal-length capability without early exit.
    var different: u8 = 0;
    if (token.len != self.token.len) return replyError(invocation, "AuthenticationFailed");
    for (token, self.token) |a, b| different |= a ^ b;
    if (different != 0) return replyError(invocation, "AuthenticationFailed");
    const method = string(root, "method") catch return replyError(invocation, "MethodRequired");
    const params = root.object.get("params") orelse Value{ .object = .empty };
    if (params != .object) return replyError(invocation, "ExpectedParamsObject");
    if (std.mem.eql(u8, method, "config.set") or std.mem.eql(u8, method, "config.reset") or std.mem.eql(u8, method, "config.reload")) {
        ConfigJob.start(self, invocation, method, params) catch |err| replyError(invocation, @errorName(err));
        return;
    }
    const result = self.request(alloc, root, method, params) catch |err| return replyError(invocation, @errorName(err));
    if (result.len > max_response) return replyError(invocation, "ResponseTooLarge");
    const envelope = alloc.printSentinel("{{\"ok\":true,\"result\":{s}}}", .{result}, 0) catch return replyError(invocation, "OutOfMemory");
    if (envelope.len > max_response) return replyError(invocation, "ResponseTooLarge");
    invocation.returnValue(glib.Variant.new("(s)", envelope.ptr));
}

fn replyError(invocation: *gio.DBusMethodInvocation, message: [:0]const u8) void {
    // Error names are static Zig error identifiers, never request text.
    invocation.returnDbusError("org.gizmo.Agent1.Error", message.ptr);
}

fn encode(alloc: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{ .emit_null_optional_fields = true });
}

fn cString(alloc: Allocator, text: []const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.NulNotSupportedInGTKText;
    return alloc.dupeSentinel(u8, text, 0);
}
fn string(value: Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.ExpectedObject;
    const v = value.object.get(key) orelse return error.MissingParameter;
    return if (v == .string) v.string else error.ExpectedString;
}
fn boolean(value: Value, key: []const u8, default: bool) !bool {
    const v = value.object.get(key) orelse return default;
    return if (v == .bool) v.bool else error.ExpectedBoolean;
}

pub fn findSurface(app: *Application, params: Value) !*@import("../../Surface.zig") {
    const id_text = try string(params, "surface");
    const surface_id = std.fmt.parseInt(u64, id_text, 10) catch return error.InvalidSurfaceID;
    for (app.core().surfaces.items) |surface| if (surface.core().id == surface_id) return surface.core();
    return error.SurfaceNotFound;
}

/// Shared by authenticated requests and explicit extension button invocations.
pub fn performBinding(app: *Application, alloc: Allocator, params: Value) !bool {
    const action = try input.Binding.Action.parse(try string(params, "action"));
    if (action == .text and std.mem.indexOfScalar(u8, action.text, '\\') != null) {
        const buffer = try alloc.alloc(u8, action.text.len);
        defer alloc.free(buffer);
        _ = try configpkg.string.parse(buffer, action.text);
    }
    if (params.object.contains("surface")) return try (try findSurface(app, params)).performBindingAction(action);
    const app_action = action.scoped(.app) orelse return error.SurfaceRequired;
    try app.core().performAction(app.rt(), app_action);
    return true;
}

fn request(self: *Self, alloc: Allocator, root: Value, method: []const u8, params: Value) ![]const u8 {
    if (std.mem.startsWith(u8, method, "extensions.")) return extensions.request(self.app, alloc, root);
    if (std.mem.eql(u8, method, "discover")) return self.discover(alloc);
    if (std.mem.eql(u8, method, "tree")) return self.tree(alloc);
    if (std.mem.eql(u8, method, "screen.read")) return self.screen(alloc, params);
    if (std.mem.eql(u8, method, "ui.tree")) return self.uiTree(alloc);
    if (std.mem.eql(u8, method, "ui.action")) {
        const widget = try self.findWidget(try string(params, "widget"));
        const operation = try string(params, "operation");
        if (widget.getSensitive() == 0) return error.WidgetDisabled;
        if (std.mem.eql(u8, operation, "activate")) {
            if (widget.activate() == 0) return error.WidgetCannotActivate;
        } else if (std.mem.eql(u8, operation, "focus")) {
            if (widget.grabFocus() == 0) return error.WidgetCannotFocus;
        } else if (std.mem.eql(u8, operation, "text")) {
            const editable = gobject.ext.cast(gtk.Editable, widget) orelse return error.WidgetNotEditable;
            if (editable.getEditable() == 0) return error.WidgetReadOnly;
            const text = try cString(alloc, try string(params, "text"));
            editable.setText(text);
        } else return error.UnknownWidgetOperation;
        return encode(alloc, .{ .performed = true });
    }
    if (std.mem.eql(u8, method, "screen.capture")) return self.capture(alloc, params);
    if (std.mem.eql(u8, method, "action")) return encode(alloc, .{ .performed = try performBinding(self.app, alloc, params) });
    if (std.mem.eql(u8, method, "input.text")) {
        const surface = try findSurface(self.app, params);
        const text = try string(params, "text");
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUTF8;
        // Escape backslashes for the existing text-binding parser, preserving
        // all requested bytes rather than applying paste newline conversion.
        var escaped: std.Io.Writer.Allocating = .init(alloc);
        defer escaped.deinit();
        const encoded = if (std.mem.indexOfScalar(u8, text, '\\') != null) encoded: {
            for (text) |byte| {
                if (byte == '\\') try escaped.writer.writeByte('\\');
                try escaped.writer.writeByte(byte);
            }
            break :encoded escaped.written();
        } else text;
        _ = try surface.performBindingAction(.{ .text = encoded });
        return encode(alloc, .{ .sent = text.len });
    }
    if (std.mem.eql(u8, method, "input.key")) {
        const surface = try findSurface(self.app, params);
        const key = std.meta.stringToEnum(input.Key, try string(params, "key")) orelse return error.UnknownKey;
        const action = if (params.object.get("event")) |v| if (v == .string) std.meta.stringToEnum(input.Action, v.string) orelse return error.UnknownKeyEvent else return error.ExpectedString else input.Action.press;
        const text = if (params.object.get("text")) |_| try string(params, "text") else "";
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUTF8;
        const result = try surface.keyCallback(.{ .key = key, .action = action, .utf8 = text, .mods = .{
            .shift = try boolean(params, "shift", false),
            .ctrl = try boolean(params, "ctrl", false),
            .alt = try boolean(params, "alt", false),
            .super = try boolean(params, "super", false),
        } });
        return encode(alloc, .{ .effect = @tagName(result) });
    }
    if (std.mem.eql(u8, method, "input.mouse")) {
        const surface = try findSurface(self.app, params);
        const event = try string(params, "event");
        const action: ?input.MouseButtonState = if (std.mem.eql(u8, event, "move")) null else std.meta.stringToEnum(input.MouseButtonState, event) orelse return error.UnknownMouseEvent;
        const button: ?input.MouseButton = if (action != null) button: {
            const value = std.meta.stringToEnum(input.MouseButton, try string(params, "button")) orelse return error.UnknownMouseButton;
            if (value == .unknown) return error.UnknownMouseButton;
            break :button value;
        } else if (params.object.contains("button")) return error.MouseMoveTakesNoButton else null;
        const pos = try pointerPosition(surface, params);
        const mods = try pointerModifiers(params);
        surface.rt_surface.gobj().setCursorPos(pos);
        try surface.cursorPosCallback(pos, mods);
        const consumed: ?bool = if (action) |state| try surface.mouseButtonCallback(state, button.?, mods) else null;
        return encode(alloc, .{ .performed = true, .consumed = consumed });
    }
    if (std.mem.eql(u8, method, "input.scroll")) {
        const surface = try findSurface(self.app, params);
        const pos = try pointerPosition(surface, params);
        const mods = try pointerModifiers(params);
        const dx = try finiteNumber(params, "delta_x");
        const dy = try finiteNumber(params, "delta_y");
        const scroll_mods: input.ScrollMods = .{ .precision = try boolean(params, "precision", false) };
        // Bound the work before CoreSurface converts to isize and emits one
        // mouse report per cell. Use its existing Linux scale semantics.
        const cell_width: f64 = @floatFromInt(surface.size.cell.width);
        const cell_height: f64 = @floatFromInt(surface.size.cell.height);
        const x_cells = if (scroll_mods.precision) (surface.mouse.pending_scroll_x + dx) / cell_width else @round(dx);
        const y_pixels = if (scroll_mods.precision)
            dy * surface.config.mouse_scroll_multiplier.precision
        else
            dy * cell_height * surface.config.mouse_scroll_multiplier.discrete;
        const y_cells = (surface.mouse.pending_scroll_y + y_pixels) / cell_height;
        if (!std.math.isFinite(x_cells) or !std.math.isFinite(y_cells) or @abs(x_cells) > 10000 or @abs(y_cells) > 10000) return error.ScrollDeltaOutOfRange;
        surface.rt_surface.gobj().setCursorPos(pos);
        try surface.cursorPosCallback(pos, mods);
        try surface.scrollCallback(dx, dy, scroll_mods);
        return encode(alloc, .{ .performed = true });
    }
    if (std.mem.eql(u8, method, "gtk.actions")) return self.gtkActions(alloc);
    if (std.mem.eql(u8, method, "gtk.action")) {
        const name = try cString(alloc, try string(params, "name"));
        var parameter: ?*glib.Variant = null;
        defer if (parameter) |p| p.unref();
        if (params.object.get("parameter")) |_| {
            const value = try cString(alloc, try string(params, "parameter"));
            var gerr: ?*glib.Error = null;
            defer if (gerr) |e| e.free();
            parameter = glib.Variant.parse(null, value, null, null, &gerr) orelse return error.InvalidVariantParameter;
        }
        if (params.object.contains("surface") or params.object.contains("widget")) {
            const widget = if (params.object.contains("surface")) (try findSurface(self.app, params)).rt_surface.gobj().as(gtk.Widget) else try self.findWidget(try string(params, "widget"));
            if (gtk_widget_activate_action_variant(widget, name, parameter) == 0) return error.UnknownOrDisabledWidgetAction;
            return encode(alloc, .{ .activated = true });
        }
        const group = self.app.as(gio.ActionGroup);
        if (group.hasAction(name) == 0) return error.UnknownGTKAction;
        if (group.getActionEnabled(name) == 0) return error.DisabledGTKAction;
        const expected = group.getActionParameterType(name);
        if (expected) |t| {
            if (parameter == null or parameter.?.isOfType(t) == 0) return error.GTKActionParameterTypeMismatch;
        } else if (parameter != null) return error.GTKActionTakesNoParameter;
        group.activateAction(name, parameter);
        return encode(alloc, .{ .activated = true });
    }
    if (std.mem.eql(u8, method, "config.get")) {
        const config = self.app.getConfig();
        defer config.unref();
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try (configpkg.FileFormatter{ .alloc = alloc, .config = config.get(), .docs = try boolean(params, "docs", false) }).format(&out.writer);
        return encode(alloc, .{ .format = "ghostty-config", .text = out.written(), .scope = "application", .persistence = "session changes require explicit persist_path" });
    }
    return error.UnknownMethod;
}

fn finiteNumber(params: Value, name: []const u8) !f64 {
    const value = params.object.get(name) orelse return error.MissingParameter;
    const number: f64 = switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        .number_string => |v| std.fmt.parseFloat(f64, v) catch return error.ExpectedNumber,
        else => return error.ExpectedNumber,
    };
    if (!std.math.isFinite(number)) return error.NonFiniteNumber;
    return number;
}

fn pointerModifiers(params: Value) !input.Mods {
    return .{
        .shift = try boolean(params, "shift", false),
        .ctrl = try boolean(params, "ctrl", false),
        .alt = try boolean(params, "alt", false),
        .super = try boolean(params, "super", false),
    };
}

fn pointerPosition(surface: *@import("../../Surface.zig"), params: Value) !@import("../../apprt.zig").CursorPos {
    if (surface.size.cell.width == 0 or surface.size.cell.height == 0 or surface.size.screen.width == 0 or surface.size.screen.height == 0) return error.SurfaceNotReady;
    const x = try finiteNumber(params, "x");
    const y = try finiteNumber(params, "y");
    const max_x: f64 = @as(f64, @floatFromInt(surface.size.screen.width)) + @as(f64, @floatFromInt(surface.size.cell.width));
    const max_y: f64 = @as(f64, @floatFromInt(surface.size.screen.height)) + @as(f64, @floatFromInt(surface.size.cell.height));
    // Permit leaving the viewport and dragging one cell beyond its edges,
    // without allowing unrepresentable grid coordinates in core callbacks.
    if (x < -1 or y < -1 or x > max_x or y > max_y) return error.PointerPositionOutOfRange;
    return .{ .x = @floatCast(x), .y = @floatCast(y) };
}

fn id(self: *Self, object: anytype) usize {
    const ptr: *anyopaque = @ptrCast(object);
    if (g_object_get_data(ptr, "gizmo-agent-id")) |value| return @intFromPtr(value);
    const result = self.next_id;
    self.next_id += 1;
    g_object_set_data(ptr, "gizmo-agent-id", @ptrFromInt(result));
    return result;
}

fn tree(self: *Self, alloc: Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"windows\":[");
    var windows: ?*glib.List = self.app.as(gtk.Application).getWindows();
    var first = true;
    while (windows) |entry| : (windows = entry.f_next) {
        const window = gobject.ext.cast(Window, @as(*gobject.Object, @ptrCast(@alignCast(entry.f_data orelse continue)))) orelse continue;
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.print("{{\"id\":\"w{d}\",\"title\":{s},\"active\":{},\"tabs\":[", .{ self.id(window), try encode(alloc, window.as(gtk.Window).getTitle()), window.as(gtk.Window).isActive() != 0 });
        const tabs = window.getTabView();
        var n: c_int = 0;
        while (n < tabs.getNPages()) : (n += 1) {
            if (n > 0) try out.writer.writeByte(',');
            const page = tabs.getNthPage(n);
            const tab = gobject.ext.cast(Tab, page.getChild()).?;
            try out.writer.print("{{\"id\":\"t{d}\",\"index\":{d},\"title\":{s},\"selected\":{},\"splits\":", .{ self.id(tab), n, try encode(alloc, std.mem.span(page.getTitle())), tabs.getSelectedPage() == page });
            if (tab.getSurfaceTree()) |t| {
                if (t.isEmpty()) try out.writer.writeAll("null") else try self.treeNode(alloc, &out.writer, t, 0);
            } else try out.writer.writeAll("null");
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
    }
    try out.writer.writeAll("]}");
    return alloc.dupe(u8, out.written());
}

fn treeNode(self: *Self, alloc: Allocator, writer: *std.Io.Writer, t: *Surface.Tree, index: usize) anyerror!void {
    switch (t.nodes[index]) {
        .leaf => |surface| {
            const core = surface.core() orelse return writer.writeAll(try encode(alloc, .{
                .surface = @as(?[]const u8, null),
                .widget = try alloc.print("u{d}", .{self.id(surface)}),
                .ready = false,
                .title = surface.getEffectiveTitle(),
            }));
            try writer.print("{{\"surface\":\"{d}\",\"widget\":\"u{d}\",\"ready\":true,\"title\":{s},\"focused\":{},\"width_px\":{d},\"height_px\":{d},\"cell_width_px\":{d},\"cell_height_px\":{d}}}", .{ core.id, self.id(surface), try encode(alloc, surface.getEffectiveTitle()), core.focused, core.size.screen.width, core.size.screen.height, core.size.cell.width, core.size.cell.height });
        },
        .split => |split| {
            try writer.print("{{\"direction\":{s},\"ratio\":{d},\"children\":[", .{ try encode(alloc, @tagName(split.layout)), split.ratio });
            try self.treeNode(alloc, writer, t, split.left.idx());
            try writer.writeByte(',');
            try self.treeNode(alloc, writer, t, split.right.idx());
            try writer.writeAll("]}");
        },
    }
}

fn screen(self: *Self, alloc: Allocator, params: Value) ![]const u8 {
    const surface = try findSurface(self.app, params);
    const region_text = if (params.object.get("region")) |_| try string(params, "region") else "viewport";
    const region: terminal.point.Tag = if (std.mem.eql(u8, region_text, "viewport")) .viewport else if (std.mem.eql(u8, region_text, "active")) .active else if (std.mem.eql(u8, region_text, "history")) .history else if (std.mem.eql(u8, region_text, "screen")) .screen else return error.UnknownScreenRegion;
    surface.renderer_state.mutex.lockUncancelable(global.io());
    defer surface.renderer_state.mutex.unlock(global.io());
    const term = surface.io.terminal;
    const screen_ = term.screens.active;
    const br = screen_.pages.getBottomRight(region);
    // A fixed writer bounds history allocation before traversing the buffer.
    const buffer = try alloc.alloc(u8, 4 * 1024 * 1024);
    var writer: std.Io.Writer = .fixed(buffer);
    if (br) |end| {
        screen_.dumpString(&writer, .{ .tl = screen_.pages.getTopLeft(region), .br = end, .unwrap = false }) catch return error.ScreenTextTooLarge;
    }
    return encode(alloc, .{ .text = writer.buffered(), .region = region_text, .columns = term.cols, .rows = term.rows, .cursor = .{ .x = screen_.cursor.x, .y = screen_.cursor.y }, .graphics = .{ .text_represents_images = false, .capture_method = "screen.capture", .terminal_image_storage = "not exported; capture rendered window" } });
}

fn gtkActions(self: *Self, alloc: Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"application\":");
    try actionGroupJSON(alloc, &out.writer, self.app.as(gio.ActionGroup));
    try out.writer.writeAll(",\"windows\":[");
    var windows: ?*glib.List = self.app.as(gtk.Application).getWindows();
    var first = true;
    while (windows) |entry| : (windows = entry.f_next) {
        const window = gobject.ext.cast(Window, @as(*gobject.Object, @ptrCast(@alignCast(entry.f_data orelse continue)))) orelse continue;
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.print("{{\"window\":\"w{d}\",\"widget\":\"u{d}\",\"prefix\":\"win.\",\"actions\":", .{ self.id(window), self.id(window) });
        try actionGroupJSON(alloc, &out.writer, window.as(gio.ActionGroup));
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    return alloc.dupe(u8, out.written());
}
fn actionGroupJSON(alloc: Allocator, out: *std.Io.Writer, group: *gio.ActionGroup) !void {
    const names: [*:null]?[*:0]u8 = @ptrCast(group.listActions());
    defer glib.strfreev(names);
    try out.writeByte('[');
    var n: usize = 0;
    while (names[n]) |name| : (n += 1) {
        if (n > 0) try out.writeByte(',');
        const parameter = group.getActionParameterType(name);
        const state = group.getActionState(name);
        defer if (state) |v| v.unref();
        const printed: ?[*:0]u8 = if (state) |v| v.print(1) else null;
        defer if (printed) |v| glib.free(v);
        try out.writeAll(try encode(alloc, .{ .name = std.mem.span(name), .enabled = group.getActionEnabled(name) != 0, .parameter_type = if (parameter) |p| p.peekString()[0..p.getStringLength()] else null, .state = if (printed) |v| std.mem.span(v) else null, .state_format = "GVariant" }));
    }
    try out.writeByte(']');
}

pub fn resetTabsOrientations(app: *Application) void {
    var windows: ?*glib.List = app.as(gtk.Application).getWindows();
    while (windows) |entry| : (windows = entry.f_next) {
        const window = gobject.ext.cast(Window, @as(*gobject.Object, @ptrCast(@alignCast(entry.f_data orelse continue)))) orelse continue;
        window.resetTabsOrientation();
    }
}

fn findWidget(self: *Self, target: []const u8) !*gtk.Widget {
    if (target.len < 2 or target[0] != 'u') return error.InvalidWidgetID;
    const wanted = std.fmt.parseInt(usize, target[1..], 10) catch return error.InvalidWidgetID;
    var windows: ?*glib.List = self.app.as(gtk.Application).getWindows();
    while (windows) |entry| : (windows = entry.f_next) {
        const widget: *gtk.Widget = @ptrCast(@alignCast(entry.f_data orelse continue));
        if (self.findWidgetChild(widget, wanted, 0)) |found| return found;
    }
    return error.WidgetNotFound;
}
fn findWidgetChild(self: *Self, widget: *gtk.Widget, wanted: usize, depth: usize) ?*gtk.Widget {
    if (depth > 64) return null;
    if (self.id(widget) == wanted) return widget;
    var child = widget.getFirstChild();
    while (child) |c| : (child = c.getNextSibling()) {
        if (self.findWidgetChild(c, wanted, depth + 1)) |found| return found;
    }
    return null;
}

fn discover(self: *Self, alloc: Allocator) ![]const u8 {
    @setEvalBranchQuota(100000);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"application_id\":{s},\"bus_name\":{s},", .{ try encode(alloc, self.app.as(gio.Application).getApplicationId()), try encode(alloc, self.connection.getUniqueName()) });
    try out.writer.writeAll("\"protocol\":1,\"name\":\"Gizmo\",\"interface\":\"org.gizmo.Agent1\",\"path\":\"/org/gizmo/Agent1\",\"request_limit\":1048576,\"response_limit\":16777216,\"surface_ids\":\"decimal strings; stable for the surface lifetime\",\"methods\":[");
    const methods = .{
        .{ "discover", "{}", "Method, action, key and config schemas" },
        .{ "tree", "{}", "All windows, tabs and recursive splits" },
        .{ "ui.tree", "{}", "GTK widgets including dialogs and extension panels; bounded depth and node count" },
        .{ "ui.action", "{widget:string,operation:activate|focus|text,text?:string}", "Invoke a widget exposed by ui.tree; text requires an editable widget" },
        .{ "screen.read", "{surface:string,region?:viewport|active|history|screen}", "Plain text plus grid, cursor and graphics metadata; 4 MiB text maximum" },
        .{ "screen.capture", "{window:string}", "PNG/base64 rendered window, including graphical content; requires realized window" },
        .{ "action", "{action:string,surface?:string}", "Existing binding syntax name[:parameter], every parsable binding action" },
        .{ "input.text", "{surface:string,text:string}", "Exact UTF-8 bytes through the existing text binding, without paste conversion" },
        .{ "input.key", "{surface:string,key:string,event?:press|release|repeat,text?:string,shift?:bool,ctrl?:bool,alt?:bool,super?:bool}", "Existing key callback, including configured bindings and terminal keyboard protocols" },
        .{ "input.mouse", "{surface:string,event:move|press|release,x:number,y:number,button?:left|right|middle|four|five|six|seven|eight|nine|ten|eleven,shift?:bool,ctrl?:bool,alt?:bool,super?:bool}", "Core cursor/button callbacks; x/y are device pixels from the terminal render surface top-left, including padding, excluding window/tab chrome. No GTK CSS scaling. Button required only for press/release; modifiers default false. Coordinates range from -1 through surface size plus one cell. Returns consumed for buttons, null for moves; false is not a failure." },
        .{ "input.scroll", "{surface:string,x:number,y:number,delta_x:number,delta_y:number,precision?:bool,shift?:bool,ctrl?:bool,alt?:bool,super?:bool}", "Core cursor/scroll callbacks at x/y device pixels, as input.mouse. Deltas are wheel ticks by default, device pixels if precision=true. Positive delta_x moves right; positive delta_y moves up. Core applies configured scroll multipliers and cell accumulation; no GTK CSS scaling, sign inversion or touchpad 10x factor. Maximum 10000 resulting cells per axis per call; errors propagate." },
        .{ "gtk.actions", "{}", "Available application GTK actions and GVariant parameter types" },
        .{ "gtk.action", "{name:string,parameter?:string,surface?:string,widget?:string}", "Activate app action or surface/widget action such as win.set-tabs-orientation with GVariant text parameter" },
        .{ "config.get", "{docs?:bool}", "Effective application config in canonical parser format" },
        .{ "config.set", "{text:string,persist_path?:absolute-string}", "Parse config lines onto current config; validate then update all surfaces; optional atomic explicit file replacement" },
        .{ "config.reset", "{persist_path?:absolute-string}", "Reset to defaults through existing config update path" },
        .{ "config.reload", "{}", "Reload files and launch arguments; discards session config edits" },
        .{ "extensions.*", "see extensions.discover", "Custom panels, tools and explicit-invocation workflows" },
    };
    inline for (methods, 0..) |method, n| {
        if (n != 0) try out.writer.writeByte(',');
        try out.writer.writeAll(try encode(alloc, .{ .method = method[0], .params = method[1], .params_schema = try parameterSchema(alloc, method[0], method[1]), .description = method[2] }));
    }
    try out.writer.writeAll("],\"actions\":[");
    inline for (@typeInfo(input.Binding.Action).@"union".field_names, @typeInfo(input.Binding.Action).@"union".field_types, 0..) |name, T, n| {
        if (n != 0) try out.writer.writeByte(',');
        const optional = comptime switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum" => @hasDecl(T, "default"),
            else => false,
        };
        try out.writer.writeAll(try encode(alloc, .{ .name = name, .parameter_type = @typeName(T), .parameter_required = T != void and !optional, .parsable = T != input.Binding.Action.CursorKey, .parameter_values = if (@typeInfo(T) == .@"enum") @typeInfo(T).@"enum".field_names else &.{}, .documentation = if (@hasDecl(@import("help_strings").KeybindAction, name)) @field(@import("help_strings").KeybindAction, name) else "" }));
    }
    try out.writer.writeAll("],\"keys\":");
    try out.writer.writeAll(try encode(alloc, @typeInfo(input.Key).@"enum".field_names));
    try out.writer.writeAll(",\"config\":[");
    comptime var first = true;
    inline for (@typeInfo(configpkg.Config).@"struct".field_names, @typeInfo(configpkg.Config).@"struct".field_types) |name, T| {
        if (comptime name[0] == '_') continue;
        if (comptime !first) try out.writer.writeByte(',');
        first = false;
        try out.writer.writeAll(try encode(alloc, .{ .key = name, .type = @typeName(T), .syntax = "key = value; empty value resets through the existing parser", .documentation = if (@hasDecl(@import("help_strings").Config, name)) @field(@import("help_strings").Config, name) else "" }));
    }
    try out.writer.writeAll("],\"gtk_actions\":");
    try out.writer.writeAll(try self.gtkActions(alloc));
    try out.writer.writeByte('}');
    return alloc.dupe(u8, out.written());
}

fn parameterSchema(alloc: Allocator, method: []const u8, syntax: []const u8) !Value {
    var schema: Value = .{ .object = .empty };
    try schema.object.put(alloc, "type", .{ .string = "object" });
    var properties: Value = .{ .object = .empty };
    var required: Value = .{ .array = .init(alloc) };
    if (syntax.len >= 2 and syntax[0] == '{') {
        var fields = std.mem.splitScalar(u8, syntax[1 .. syntax.len - 1], ',');
        while (fields.next()) |field| {
            if (field.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, field, ':') orelse continue;
            const optional = colon > 0 and field[colon - 1] == '?';
            const name = field[0 .. colon - @intFromBool(optional)];
            const typ = field[colon + 1 ..];
            var property: Value = .{ .object = .empty };
            try property.object.put(alloc, "type", .{ .string = if (std.mem.eql(u8, typ, "bool")) "boolean" else if (std.mem.eql(u8, typ, "number")) "number" else "string" });
            if (std.mem.eql(u8, method, "input.mouse") or std.mem.eql(u8, method, "input.scroll")) {
                if (std.mem.eql(u8, name, "x") or std.mem.eql(u8, name, "y")) {
                    try property.object.put(alloc, "minimum", .{ .integer = -1 });
                    try property.object.put(alloc, "description", .{ .string = "Finite device pixels from the terminal render surface top-left, including terminal padding, excluding chrome; maximum is surface size plus one cell on this axis. Negative coordinates indicate pointer exit." });
                } else if (std.mem.eql(u8, name, "delta_x")) {
                    try property.object.put(alloc, "description", .{ .string = "Finite horizontal delta: wheel ticks when precision=false (default), device pixels when true. Positive is right. Core rounds wheel ticks or accumulates pixels by cell width; maximum 10000 resulting cells." });
                } else if (std.mem.eql(u8, name, "delta_y")) {
                    try property.object.put(alloc, "description", .{ .string = "Finite vertical delta: wheel ticks when precision=false (default), device pixels when true. Positive is up. Core applies the configured discrete/precision mouse-scroll-multiplier and accumulates by cell height; maximum 10000 resulting cells." });
                } else if (std.mem.eql(u8, name, "precision")) {
                    try property.object.put(alloc, "default", .{ .bool = false });
                    try property.object.put(alloc, "description", .{ .string = "False selects wheel ticks; true selects device pixels. Values already use CoreSurface units: no additional GTK scale, sign inversion or 10x touchpad multiplier." });
                } else if (std.mem.eql(u8, name, "button")) {
                    try property.object.put(alloc, "description", .{ .string = "Required for press/release; forbidden for move. Held buttons persist across requests, enabling drag selection and TUI mouse motion." });
                }
            }
            if (std.mem.indexOfScalar(u8, typ, '|') != null) {
                var choices: Value = .{ .array = .init(alloc) };
                var options = std.mem.splitScalar(u8, typ, '|');
                while (options.next()) |option| try choices.array.append(.{ .string = option });
                try property.object.put(alloc, "enum", choices);
            }
            try properties.object.put(alloc, name, property);
            if (!optional) try required.array.append(.{ .string = name });
        }
    }
    try schema.object.put(alloc, "properties", properties);
    try schema.object.put(alloc, "required", required);
    if (std.mem.eql(u8, method, "input.mouse")) {
        const conditional = try std.json.parseFromSlice(Value, alloc,
            \\{"if":{"properties":{"event":{"enum":["press","release"]}}},"then":{"required":["button"]},"else":{"not":{"required":["button"]}}}
        , .{});
        var conditions: Value = .{ .array = .init(alloc) };
        try conditions.array.append(conditional.value);
        try schema.object.put(alloc, "allOf", conditions);
    }
    return schema;
}

fn uiTree(self: *Self, alloc: Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('[');
    var windows: ?*glib.List = self.app.as(gtk.Application).getWindows();
    var first = true;
    var remaining: usize = 10000;
    while (windows) |entry| : (windows = entry.f_next) {
        const widget: *gtk.Widget = @ptrCast(@alignCast(entry.f_data orelse continue));
        if (!first) try out.writer.writeByte(',');
        first = false;
        try self.widgetTree(alloc, &out.writer, widget, 0, &remaining);
    }
    try out.writer.writeByte(']');
    return alloc.dupe(u8, out.written());
}
fn widgetTree(self: *Self, alloc: Allocator, out: *std.Io.Writer, widget: *gtk.Widget, depth: usize, remaining: *usize) anyerror!void {
    if (remaining.* == 0 or depth > 64) return out.writeAll("{\"truncated\":true}");
    remaining.* -= 1;
    const label = if (gobject.ext.cast(gtk.Label, widget)) |w| std.mem.span(w.getText()) else if (gobject.ext.cast(gtk.Button, widget)) |w| if (w.getLabel()) |s| std.mem.span(s) else "" else if (gobject.ext.cast(gtk.Editable, widget)) |w| std.mem.span(w.getText()) else "";
    const window_id: ?[]const u8 = if (gobject.ext.cast(gtk.Window, widget) != null) try alloc.print("w{d}", .{self.id(widget)}) else null;
    const tooltip: ?[]const u8 = if (widget.getTooltipText()) |text| std.mem.span(text) else null;
    const icon: ?[]const u8 = if (gobject.ext.cast(gtk.Button, widget)) |button| if (button.getIconName()) |text| std.mem.span(text) else null else null;
    try out.print("{{\"id\":\"u{d}\",\"window_id\":{s},\"type\":{s},\"role\":{s},\"name\":{s},\"text\":{s},\"tooltip\":{s},\"icon\":{s},\"visible\":{},\"mapped\":{},\"sensitive\":{},\"focused\":{},\"width\":{d},\"height\":{d},\"children\":[", .{ self.id(widget), try encode(alloc, window_id), try encode(alloc, std.mem.span(g_type_name_from_instance(@ptrCast(widget)))), try encode(alloc, @tagName(widget.as(gtk.Accessible).getAccessibleRole())), try encode(alloc, std.mem.span(widget.getName())), try encode(alloc, label), try encode(alloc, tooltip), try encode(alloc, icon), widget.getVisible() != 0, widget.getMapped() != 0, widget.getSensitive() != 0, widget.hasFocus() != 0, widget.getWidth(), widget.getHeight() });
    var child = widget.getFirstChild();
    var first = true;
    while (child) |c| : (child = c.getNextSibling()) {
        if (!first) try out.writeByte(',');
        first = false;
        try self.widgetTree(alloc, out, c, depth + 1, remaining);
        if (remaining.* == 0) break;
    }
    try out.writeAll("]}");
}

extern "c" fn gtk_widget_paintable_new(*gtk.Widget) *anyopaque;
extern "c" fn gdk_paintable_snapshot(*anyopaque, *anyopaque, f64, f64) void;
extern "c" fn gtk_snapshot_new() *anyopaque;
extern "c" fn gtk_snapshot_free_to_node(*anyopaque) ?*anyopaque;
extern "c" fn gsk_render_node_unref(*anyopaque) void;
extern "c" fn gsk_renderer_new_for_surface(*anyopaque) ?*anyopaque;
extern "c" fn gsk_renderer_render_texture(*anyopaque, *anyopaque, ?*const anyopaque) ?*anyopaque;
extern "c" fn gsk_renderer_unrealize(*anyopaque) void;
extern "c" fn gdk_texture_save_to_png_bytes(*anyopaque) *glib.Bytes;
extern "c" fn g_object_unref(*anyopaque) void;
fn capture(self: *Self, alloc: Allocator, params: Value) ![]const u8 {
    const target = try string(params, "window");
    var windows: ?*glib.List = self.app.as(gtk.Application).getWindows();
    while (windows) |entry| : (windows = entry.f_next) {
        const window: *gtk.Window = @ptrCast(@alignCast(entry.f_data orelse continue));
        const name = try alloc.print("w{d}", .{self.id(window)});
        if (!std.mem.eql(u8, name, target)) continue;
        const widget = window.as(gtk.Widget);
        const width = widget.getWidth();
        const height = widget.getHeight();
        if (width <= 0 or height <= 0 or width > 8192 or height > 8192) return error.CaptureDimensionsOutOfRange;
        const native = widget.getNative() orelse return error.WindowNotRealized;
        const surface = native.getSurface() orelse return error.WindowNotRealized;
        const paintable = gtk_widget_paintable_new(widget);
        defer g_object_unref(paintable);
        const snapshot = gtk_snapshot_new();
        gdk_paintable_snapshot(paintable, snapshot, @floatFromInt(width), @floatFromInt(height));
        const node = gtk_snapshot_free_to_node(snapshot) orelse return error.WindowHasNoRenderedContent;
        defer gsk_render_node_unref(node);
        const renderer = gsk_renderer_new_for_surface(@ptrCast(surface)) orelse return error.CaptureRendererUnavailable;
        defer g_object_unref(renderer);
        defer gsk_renderer_unrealize(renderer);
        const texture = gsk_renderer_render_texture(renderer, node, null) orelse return error.CaptureRenderFailed;
        defer g_object_unref(texture);
        const bytes = gdk_texture_save_to_png_bytes(texture);
        defer bytes.unref();
        var len: usize = 0;
        const png: [*]const u8 = @ptrCast(bytes.getData(&len) orelse return error.EmptyCapture);
        if (len > 10 * 1024 * 1024) return error.CaptureTooLarge;
        const base64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(len));
        _ = std.base64.standard.Encoder.encode(base64, png[0..len]);
        return encode(alloc, .{ .mime = "image/png", .encoding = "base64", .width = width, .height = height, .data = base64, .scope = "GTK window render; compositor decorations and other applications excluded" });
    }
    return error.WindowNotFound;
}

// Loading, finalizing and writing configuration can perform disk IO. Do that
// work off the GTK thread, then apply via the normal main-context update path.
const ConfigJob = struct {
    app: *Application,
    owner: *Self,
    thread: ?std.Thread = null,
    source: c_uint = 0,
    invocation: *gio.DBusMethodInvocation,
    arena: std.heap.ArenaAllocator,
    method: []const u8,
    text: []const u8,
    path: ?[:0]const u8,
    config: ?configpkg.Config,
    failure: ?anyerror = null,

    fn start(owner: *Self, invocation: *gio.DBusMethodInvocation, method: []const u8, params: Value) !void {
        if (owner.config_job != null) return error.ConfigurationBusy;
        const app = owner.app;
        const alloc = app.allocator();
        const job = try alloc.create(ConfigJob);
        errdefer alloc.destroy(job);
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const text = if (std.mem.eql(u8, method, "config.set")) try a.dupe(u8, try string(params, "text")) else "";
        const path: ?[:0]const u8 = if (params.object.get("persist_path")) |_| try cString(a, try string(params, "persist_path")) else null;
        if (path) |p| if (!std.fs.path.isAbsolute(p)) return error.PersistenceRequiresAbsolutePath;
        // Finish arena allocations before copying its ownership into job.
        const method_copy = try a.dupe(u8, method);
        const current = app.getConfig();
        defer current.unref();
        var config = if (std.mem.eql(u8, method, "config.set")) try current.get().clone(alloc) else null;
        errdefer if (config) |*c| c.deinit();
        invocation.ref();
        job.* = .{ .owner = owner, .app = app, .invocation = invocation, .arena = arena, .method = method_copy, .text = text, .path = path, .config = config };
        errdefer invocation.unref();
        job.thread = try std.Thread.spawn(.{}, work, .{job});
        owner.config_job = job;
    }
    fn work(self: *ConfigJob) void {
        self.prepare() catch |err| {
            self.failure = err;
        };
        self.source = glib.idleAdd(finish, self);
    }
    fn prepare(self: *ConfigJob) !void {
        const alloc = self.app.allocator();
        // A session edit must reject new errors, not inherited diagnostics.
        // Reload/reset still require a configuration without diagnostics.
        const baseline_diagnostics = if (std.mem.eql(u8, self.method, "config.set") and self.config != null) self.config.?._diagnostics.items().len else 0;
        if (std.mem.eql(u8, self.method, "config.reload")) {
            self.config = try configpkg.Config.load(alloc);
        } else {
            if (self.config == null) self.config = try configpkg.Config.default(alloc);
            if (std.mem.eql(u8, self.method, "config.set")) {
                var reader: std.Io.Reader = .fixed(self.text);
                var iter: @import("../../cli.zig").args.LineIterator = .init(&reader);
                try self.config.?.loadIter(alloc, &iter);
            }
            try self.config.?.finalize();
        }
        if (self.config.?._diagnostics.items().len > baseline_diagnostics) return error.InvalidConfiguration;
        if (self.path) |path| {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try (configpkg.FileFormatter{ .alloc = alloc, .config = &self.config.? }).format(&out.writer);
            const file = gio.File.newForPath(path);
            defer file.unref();
            var err: ?*glib.Error = null;
            defer if (err) |e| e.free();
            if (file.replaceContents(out.written().ptr, out.written().len, null, 0, .{ .replace_destination = true, .private = true }, null, null, &err) == 0) return error.ConfigurationPersistenceFailed;
        }
    }
    fn finish(data: ?*anyopaque) callconv(.c) c_int {
        const self: *ConfigJob = @ptrCast(@alignCast(data.?));
        self.thread.?.join();
        self.owner.config_job = null;
        defer self.destroy();
        if (self.failure) |err| {
            replyError(self.invocation, @errorName(err));
            return 0;
        }
        self.app.core().updateConfig(self.app.rt(), &self.config.?) catch |err| {
            replyError(self.invocation, @errorName(err));
            return 0;
        };
        resetTabsOrientations(self.app);
        self.invocation.returnValue(glib.Variant.new("(s)", @as([*:0]const u8, "{\"ok\":true,\"result\":{\"applied\":true}}")));
        return 0;
    }
    fn destroy(self: *ConfigJob) void {
        const alloc = self.app.allocator();
        if (self.config) |*c| c.deinit();
        self.arena.deinit();
        self.invocation.unref();
        alloc.destroy(self);
    }
};
