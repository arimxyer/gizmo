//! Reusable, inert extension definitions, optional GTK panels, and named actions.
//! Only explicit button, palette, or authenticated API invocations run actions.
//! `extensions.discover` describes the versioned contract and persistence.

const std = @import("std");
const Application = @import("class/application.zig").Application;
const control = @import("agent_control.zig");
const store = @import("agent_extensions_store.zig");
const schema = @import("agent_extensions_schema.zig");
const Action = schema.Action;
const Element = schema.Element;
const Definition = schema.Definition;
const validText = schema.validText;
const mergePatch = schema.mergePatch;
const discover = schema.discover;
const Surface = @import("class/surface.zig").Surface;
const WeakRef = @import("weak_ref.zig").WeakRef;
const n = @import("agent_extensions_native.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const gpa = std.heap.c_allocator;
const max_elements = schema.max_elements;
const max_panels = schema.max_panels;
const max_jobs = 64;
const max_output = 1024 * 1024;
const max_text = schema.max_text;

const ElementUI = struct {
    panel: *Panel,
    definition: *const Element,
    widget: *n.Widget,
};
const Panel = struct {
    arena: std.heap.ArenaAllocator,
    runtime: *Runtime,
    definition: Definition,
    elements: []ElementUI,
    window: ?*n.Widget,
    results: *n.Widget,
    status: *n.Widget,
    workspace: ?[]const u8 = null,
    persistent: bool = false,
    workspace_scoped: bool = false,
    data: Value = .{ .object = .empty },
    state_arena: std.heap.ArenaAllocator,
    caller: WeakRef(Surface) = .empty,
    last_error: ?[]const u8 = null,
    latest_job: ?u64 = null,

    fn destroy(self: *Panel) void {
        // Destroy widgets before freeing callback data in the arena.
        self.caller.deinit();
        if (self.window) |window| {
            n.gtk_window_destroy(window);
            n.g_object_unref(window);
        }
        for (self.elements) |item| n.g_object_unref(item.widget);
        n.g_object_unref(self.results);
        n.g_object_unref(self.status);
        self.state_arena.deinit();
        if (self.last_error) |message| gpa.free(message);
        if (self.workspace) |workspace| gpa.free(workspace);
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn element(self: *Panel, id: []const u8) !*ElementUI {
        for (self.elements) |*item| {
            if (std.mem.eql(u8, id, item.definition.id)) return item;
        }
        return error.UnknownElement;
    }

    fn action(self: *Panel, id: []const u8) !Action {
        for (self.definition.actions) |item| if (std.mem.eql(u8, item.id, id)) return item;
        return error.UnknownAction;
    }

    fn visible(self: *Panel) bool {
        return if (self.window) |window| n.gtk_widget_get_visible(window) != 0 else false;
    }

    fn show(self: *Panel, show_panel: bool) !void {
        if (show_panel) {
            const window = self.window orelse return error.ExtensionHasNoPanel;
            captureCaller(self);
            n.gtk_window_set_application(window, @ptrCast(self.runtime.app.as(@import("gtk").Application)));
            n.gtk_window_present(window);
        } else if (self.window) |window| {
            n.gtk_widget_set_visible(window, 0);
            n.gtk_window_set_application(window, null);
        }
    }

    fn setError(self: *Panel, message: []const u8) void {
        if (self.last_error) |old| gpa.free(old);
        self.last_error = gpa.dupe(u8, message) catch null;
        const text = gpa.dupeSentinel(u8, message, 0) catch return;
        defer gpa.free(text);
        n.gtk_label_set_text(self.status, text);
    }
};
const Runtime = struct {
    app: *Application,
    panels: std.ArrayList(*Panel) = .empty,
    jobs: std.ArrayList(*Job) = .empty,
    next_job: u64 = 1,

    fn panel(self: *Runtime, id: []const u8) !*Panel {
        for (self.panels.items) |p| {
            if (std.mem.eql(u8, id, p.definition.id)) return p;
        }
        return error.UnknownExtension;
    }

    fn job(self: *Runtime, id: u64) !*Job {
        for (self.jobs.items) |j| if (j.id == id) return j;
        return error.UnknownJob;
    }

    fn cancelPanel(self: *Runtime, id: []const u8) void {
        var index = self.jobs.items.len;
        while (index != 0) {
            index -= 1;
            const j = self.jobs.items[index];
            if (!std.mem.eql(u8, id, j.panel_id)) continue;
            _ = self.jobs.orderedRemove(index);
            j.stop("panel removed");
            j.release();
        }
    }
};
var runtimes: std.ArrayList(*Runtime) = .empty;

fn runtime(app: *Application) !*Runtime {
    for (runtimes.items) |r| if (r.app == app) return r;
    const r = try gpa.create(Runtime);
    errdefer gpa.destroy(r);
    r.* = .{ .app = app };
    try runtimes.append(gpa, r);
    return r;
}

/// Call on the GTK main thread before disposing the owning application.
/// Callback-owned jobs retain only their process, buffers, and output label.
pub fn deinit(app: *Application) void {
    for (runtimes.items, 0..) |r, index| {
        if (r.app != app) continue;
        _ = runtimes.orderedRemove(index);
        for (r.jobs.items) |j| {
            j.stop("application disposed");
            j.release();
        }
        r.jobs.deinit(gpa);
        for (r.panels.items) |p| p.destroy();
        r.panels.deinit(gpa);
        gpa.destroy(r);
        break;
    }
    if (runtimes.items.len == 0) {
        runtimes.deinit(gpa);
        runtimes = .empty;
    }
}

fn field(value: Value, name: []const u8) ?Value {
    return if (value == .object) value.object.get(name) else null;
}
fn string(value: Value) ![]const u8 {
    return if (value == .string) value.string else error.ExpectedString;
}
fn required(value: Value, name: []const u8) !Value {
    return field(value, name) orelse error.MissingParameter;
}
fn idParam(params: Value) ![]const u8 {
    return string(try required(params, "id"));
}
fn jobId(value: Value) !u64 {
    if (value != .integer or value.integer <= 0) return error.InvalidJobId;
    return @intCast(value.integer);
}
fn boolean(value: Value) !bool {
    return if (value == .bool) value.bool else error.ExpectedBoolean;
}

fn createPanel(r: *Runtime, value: Value) !*Panel {
    // Reparse a serialized value so the panel never borrows request storage.
    const p = try gpa.create(Panel);
    errdefer gpa.destroy(p);
    p.arena = std.heap.ArenaAllocator.init(gpa);
    errdefer p.arena.deinit();
    const alloc = p.arena.allocator();
    const def = try schema.parseDefinition(alloc, value);
    const ui = try alloc.alloc(ElementUI, def.elements.len);
    const app: *n.Object = @ptrCast(r.app.as(@import("gtk").Application));
    const parent = n.gtk_application_get_active_window(app);
    const window = if (def.panel) n.gtk_window_new() else null;
    if (window) |w| {
        _ = n.g_object_ref(w);
        // Hidden panels stay detached until explicit presentation.
        n.gtk_window_set_title(w, try alloc.dupeSentinel(u8, def.title, 0));
        n.gtk_window_set_default_size(w, 480, 480);
        n.gtk_window_set_hide_on_close(w, 1);
        n.gtk_window_set_transient_for(w, parent);
    }
    errdefer if (window) |w| {
        n.gtk_window_destroy(w);
        n.g_object_unref(w);
    };
    const box = n.gtk_box_new(1, 8); // GTK_ORIENTATION_VERTICAL
    _ = n.g_object_ref_sink(box);
    defer n.g_object_unref(box);
    n.gtk_widget_set_margin_top(box, 12);
    n.gtk_widget_set_margin_bottom(box, 12);
    n.gtk_widget_set_margin_start(box, 12);
    n.gtk_widget_set_margin_end(box, 12);
    if (window) |w| {
        const scroll = n.gtk_scrolled_window_new();
        n.gtk_scrolled_window_set_child(scroll, box);
        n.gtk_window_set_child(w, scroll);
    }
    const status = n.gtk_label_new("Gizmo extension · explicit actions only");
    _ = n.g_object_ref_sink(status);
    n.gtk_label_set_wrap(status, 1);
    const results = n.gtk_box_new(1, 8);
    _ = n.g_object_ref_sink(results);
    p.* = .{ .arena = p.arena, .state_arena = std.heap.ArenaAllocator.init(gpa), .runtime = r, .definition = def, .elements = ui[0..0], .window = window, .results = results, .status = status };
    errdefer {
        p.caller.deinit();
        p.state_arena.deinit();
        for (p.elements) |item| n.g_object_unref(item.widget);
        n.g_object_unref(status);
        n.g_object_unref(results);
    }
    if (window) |w| _ = n.g_signal_connect_data(w, "close-request", @ptrCast(&panelClose), p, null, 0);
    captureCaller(p);
    for (def.elements, ui, 0..) |*item, *element, index| {
        const label = try alloc.dupeSentinel(u8, item.label, 0);
        const widget = switch (item.type) {
            .label => blk: {
                const w = n.gtk_label_new(try alloc.dupeSentinel(u8, item.text, 0));
                n.gtk_label_set_xalign(w, 0);
                n.gtk_label_set_wrap(w, 1);
                n.gtk_label_set_selectable(w, 1);
                break :blk w;
            },
            .entry => blk: {
                const w = n.gtk_entry_new();
                n.gtk_entry_set_max_length(w, max_text);
                n.gtk_editable_set_text(w, try alloc.dupeSentinel(u8, item.text, 0));
                break :blk w;
            },
            .button => n.gtk_button_new_with_label(label),
            .toggle => blk: {
                const w = n.gtk_check_button_new_with_label(label);
                n.gtk_check_button_set_active(w, @intFromBool(item.active));
                break :blk w;
            },
            .selection => blk: {
                const options = try alloc.allocSentinel(?[*:0]const u8, item.options.len, null);
                for (item.options, options) |option, *out| out.* = (try alloc.dupeSentinel(u8, option, 0)).ptr;
                const w = n.gtk_drop_down_new_from_strings(options.ptr);
                n.gtk_drop_down_set_selected(w, item.selected);
                break :blk w;
            },
        };
        _ = n.g_object_ref_sink(widget);
        element.* = .{ .panel = p, .definition = item, .widget = widget };
        p.elements = ui[0 .. index + 1];
        if (item.type == .button) {
            _ = n.g_signal_connect_data(widget, "clicked", @ptrCast(&buttonClicked), element, null, 0);
        }
        if (item.label.len != 0 and (item.type == .entry or item.type == .selection)) {
            const caption = n.gtk_label_new(label);
            n.gtk_label_set_xalign(caption, 0);
            n.gtk_box_append(box, caption);
        }
        n.gtk_widget_set_hexpand(widget, 1);
        n.gtk_box_append(box, widget);
    }
    n.gtk_box_append(box, status);
    n.gtk_box_append(box, results);
    return p;
}

fn panelClose(_: *n.Widget, data: ?*anyopaque) callconv(.c) c_int {
    const p: *Panel = @ptrCast(@alignCast(data orelse return 0));
    p.show(false) catch {};
    return 1;
}

fn buttonClicked(_: *n.Widget, data: ?*anyopaque) callconv(.c) void {
    const item: *ElementUI = @ptrCast(@alignCast(data orelse return));
    _ = dispatchAction(item.panel, item.definition.action orelse return, .{ .object = .empty }) catch |err| {
        if (item.panel.last_error == null) item.panel.setError(@errorName(err));
        return;
    };
}

fn state(item: *const ElementUI, alloc: Allocator) !Value {
    return switch (item.definition.type) {
        .label => .{ .string = try alloc.dupe(u8, std.mem.span(n.gtk_label_get_text(item.widget))) },
        .entry => .{ .string = try alloc.dupe(u8, std.mem.span(n.gtk_editable_get_text(item.widget))) },
        .toggle => .{ .bool = n.gtk_check_button_get_active(item.widget) != 0 },
        .selection => .{ .integer = n.gtk_drop_down_get_selected(item.widget) },
        .button => .null,
    };
}
fn validateState(p: *Panel, changes: Value) !void {
    try schema.validateState(p.definition, changes);
}
fn applyState(p: *Panel, alloc: Allocator, changes: Value) !void {
    try validateState(p, changes);
    var next: std.json.ObjectMap = .empty;
    var previous = p.data.object.iterator();
    while (previous.next()) |entry| try next.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    var it = changes.object.iterator();
    while (it.next()) |entry| {
        const item = p.element(entry.key_ptr.*) catch {
            try next.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
            if (next.count() > max_elements) return error.TooManyStateKeys;
            continue;
        };
        const value = entry.value_ptr.*;
        switch (item.definition.type) {
            .entry => n.gtk_editable_set_text(item.widget, try alloc.dupeSentinel(u8, value.string, 0)),
            .label => n.gtk_label_set_text(item.widget, try alloc.dupeSentinel(u8, value.string, 0)),
            .toggle => n.gtk_check_button_set_active(item.widget, @intFromBool(value.bool)),
            .selection => n.gtk_drop_down_set_selected(item.widget, @intCast(value.integer)),
            .button => unreachable,
        }
    }
    const json = try std.json.Stringify.valueAlloc(alloc, Value{ .object = next }, .{});
    var replacement = std.heap.ArenaAllocator.init(gpa);
    errdefer replacement.deinit();
    const parsed = try std.json.parseFromSlice(Value, replacement.allocator(), json, .{ .allocate = .alloc_always });
    p.state_arena.deinit();
    p.state_arena = replacement;
    p.data = parsed.value;
}

fn stateSnapshot(p: *Panel, alloc: Allocator) !Value {
    var values: std.json.ObjectMap = .empty;
    var it = p.data.object.iterator();
    while (it.next()) |entry| try values.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    for (p.elements) |*item| {
        if (item.definition.type != .button) try values.put(alloc, item.definition.id, try state(item, alloc));
    }
    return .{ .object = values };
}

fn panelResponse(p: *Panel, alloc: Allocator) ![]const u8 {
    const values = try stateSnapshot(p, alloc);
    var job_ids: std.ArrayList(u64) = .empty;
    defer job_ids.deinit(alloc);
    for (p.runtime.jobs.items) |j| {
        if (std.mem.eql(u8, j.panel_id, p.definition.id)) try job_ids.append(alloc, j.id);
    }
    return std.json.Stringify.valueAlloc(alloc, .{
        .scope = if (p.workspace_scoped) "workspace" else "app",
        .workspace = p.workspace,
        .persistent = p.persistent,
        .definition = p.definition,
        .state = values,
        .visible = p.visible(),
        .last_error = p.last_error,
        .latest_job = p.latest_job,
        .jobs = job_ids.items,
    }, .{});
}

fn configureScope(p: *Panel, params: Value, alloc: Allocator, allow_switch: bool) !void {
    var workspace = p.workspace;
    var workspace_scoped = p.workspace_scoped;
    if (field(params, "scope")) |value| {
        switch (try schema.parseScope(value)) {
            .workspace => workspace_scoped = true,
            .app => {
                workspace_scoped = false;
                workspace = null;
            },
        }
    }
    if (field(params, "workspace")) |value| {
        workspace = try store.canonicalWorkspace(alloc, try string(value));
        workspace_scoped = true;
    }
    const key: Value = if (workspace) |value| .{ .string = value } else .null;
    if (!allow_switch and (workspace_scoped != p.workspace_scoped or !sameWorkspace(key, p.workspace))) return error.WorkspaceChangeRequiresLoad;
    if (workspace_scoped == p.workspace_scoped and sameWorkspace(key, p.workspace)) return;
    const owned_workspace = if (workspace) |value| try gpa.dupe(u8, value) else null;
    if (p.workspace) |old| gpa.free(old);
    p.workspace = owned_workspace;
    p.workspace_scoped = workspace_scoped;
}

fn jsonValue(alloc: Allocator, value: anytype) !Value {
    const bytes = try std.json.Stringify.valueAlloc(alloc, value, .{});
    return (try std.json.parseFromSlice(Value, alloc, bytes, .{})).value;
}

fn sameWorkspace(value: Value, workspace: ?[]const u8) bool {
    if (workspace) |key| return value == .string and std.mem.eql(u8, key, value.string);
    return value == .null;
}

fn persistPanel(p: *Panel, alloc: Allocator) !void {
    if (p.workspace_scoped and p.workspace == null) return error.WorkspaceRequired;
    var transaction = try store.Transaction.init(alloc);
    defer transaction.deinit();
    const catalog = transaction.catalog;
    const definitions = catalog.object.getPtr("definitions").?;
    var entry: ?*Value = null;
    for (definitions.array.items) |*item| {
        const definition = try required(item.*, "definition");
        if (std.mem.eql(u8, try string(try required(definition, "id")), p.definition.id)) {
            entry = item;
            break;
        }
    }
    if (entry == null) {
        if (definitions.array.items.len >= max_panels) return error.TooManyExtensions;
        try definitions.array.append(try jsonValue(alloc, .{ .definition = p.definition, .scope = if (p.workspace_scoped) "workspace" else "app", .states = [_]Value{} }));
        entry = &definitions.array.items[definitions.array.items.len - 1];
    }
    const item = entry.?;
    try item.object.put(alloc, "definition", try jsonValue(alloc, p.definition));
    try item.object.put(alloc, "scope", .{ .string = if (p.workspace_scoped) "workspace" else "app" });
    const states = item.object.getPtr("states") orelse return error.InvalidExtensionStore;
    if (states.* != .array or states.array.items.len > 64) return error.InvalidExtensionStore;
    const saved = try jsonValue(alloc, .{ .workspace = p.workspace, .state = try stateSnapshot(p, alloc) });
    var replaced = false;
    for (states.array.items) |*slot| {
        if (sameWorkspace(try required(slot.*, "workspace"), p.workspace)) {
            slot.* = saved;
            replaced = true;
            break;
        }
    }
    if (!replaced) {
        if (states.array.items.len >= 64) return error.TooManyWorkspaceStates;
        try states.array.append(saved);
    }
    try transaction.commit(alloc);
}

fn removeStored(id: []const u8, alloc: Allocator) !void {
    var transaction = try store.Transaction.init(alloc);
    defer transaction.deinit();
    const catalog = transaction.catalog;
    const definitions = catalog.object.getPtr("definitions").?;
    for (definitions.array.items, 0..) |entry, index| {
        const definition = try required(entry, "definition");
        if (!std.mem.eql(u8, id, try string(try required(definition, "id")))) continue;
        _ = definitions.array.orderedRemove(index);
        try transaction.commit(alloc);
        return;
    }
}

fn restoreState(p: *Panel, entry: Value, alloc: Allocator) !void {
    if (p.workspace_scoped and p.workspace == null) return;
    // Prepare and validate before discarding the currently loaded workspace.
    const restored = try schema.restoredState(alloc, p.definition, entry, p.workspace);
    // Never leak one workspace's values into another workspace.
    p.state_arena.deinit();
    p.state_arena = std.heap.ArenaAllocator.init(gpa);
    p.data = .{ .object = .empty };
    try applyState(p, alloc, restored);
}

/// Call only after explicit agent-control opt-in. No panels are presented.
/// Workspace state is loaded only with an explicit canonical workspace request.
pub fn restore(app: *Application) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const catalog = try store.read(alloc);
    const r = try runtime(app);
    for (catalog.object.get("definitions").?.array.items) |entry| {
        const p = try createPanel(r, try required(entry, "definition"));
        errdefer p.destroy();
        for (r.panels.items) |other| {
            if (std.mem.eql(u8, other.definition.id, p.definition.id)) return error.ExtensionAlreadyInstalled;
        }
        const scope = try string(try required(entry, "scope"));
        if (!std.mem.eql(u8, scope, "app") and !std.mem.eql(u8, scope, "workspace")) return error.InvalidExtensionScope;
        p.workspace_scoped = std.mem.eql(u8, scope, "workspace");
        p.persistent = true;
        try restoreState(p, entry, alloc);
        try r.panels.append(gpa, p);
    }
}

pub const PaletteAction = struct { extension: []const u8, action: []const u8, title: []const u8 };

/// The caller owns strings in its allocator; collecting never invokes actions.
pub fn paletteActions(app: *Application, alloc: Allocator) ![]PaletteAction {
    var actions: std.ArrayList(PaletteAction) = .empty;
    for (runtimes.items) |r| {
        if (r.app != app) continue;
        for (r.panels.items) |p| for (p.definition.actions) |action| {
            if (!action.palette) continue;
            try actions.append(alloc, .{
                .extension = try alloc.dupe(u8, p.definition.id),
                .action = try alloc.dupe(u8, action.id),
                .title = try alloc.print("{s}: {s}", .{ p.definition.title, if (action.title.len != 0) action.title else action.id }),
            });
        };
    }
    return actions.toOwnedSlice(alloc);
}

pub fn invokePalette(app: *Application, id: []const u8, action: []const u8, caller: ?*Surface) !void {
    if (app.agentControl() == null) return error.AgentFeatureDisabled;
    const p = try (try runtime(app)).panel(id);
    p.caller.set(caller);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var context = Value{ .object = .empty };
    if (caller) |surface| {
        p.caller.set(surface);
        if (surface.core()) |core| try context.object.put(alloc, "surface", .{ .string = try alloc.print("{d}", .{core.id}) });
    }
    _ = dispatchAction(p, action, context) catch |err| {
        p.setError(@errorName(err));
        return err;
    };
}

/// Returns a JSON payload (not an agent-control response envelope).
/// This function and all extension state run only on the GTK main thread.
/// `alloc` is the authenticated dispatcher's request-scoped arena allocator.
pub fn request(app: *Application, alloc: Allocator, value: Value) ![]const u8 {
    const method = try string(try required(value, "method"));
    const params = field(value, "params") orelse Value{ .object = .empty };
    if (params != .object) return error.ExpectedParametersObject;
    if (field(params, "persist_path") != null) return error.CustomPersistencePathNotAllowed;
    if (std.mem.eql(u8, method, "extensions.discover")) return discover(alloc);
    const r = try runtime(app);
    if (std.mem.eql(u8, method, "extensions.list")) {
        var summaries: std.ArrayList(Value) = .empty;
        defer summaries.deinit(alloc);
        for (r.panels.items) |p| {
            const encoded = try std.json.Stringify.valueAlloc(alloc, .{
                .id = p.definition.id,
                .title = p.definition.title,
                .visible = p.visible(),
                .scope = if (p.workspace_scoped) "workspace" else "app",
                .workspace = p.workspace,
                .persistent = p.persistent,
                .actions = p.definition.actions,
                .latest_job = p.latest_job,
            }, .{});
            try summaries.append(alloc, (try std.json.parseFromSlice(Value, alloc, encoded, .{})).value);
        }
        return std.json.Stringify.valueAlloc(alloc, .{ .extensions = summaries.items }, .{});
    }
    if (std.mem.eql(u8, method, "extensions.install")) {
        if (r.panels.items.len >= max_panels) return error.TooManyExtensions;
        try r.panels.ensureUnusedCapacity(gpa, 1);
        const visible = if (field(params, "visible")) |v| try boolean(v) else false;
        const p = try createPanel(r, try required(params, "definition"));
        errdefer p.destroy();
        for (r.panels.items) |other| {
            if (std.mem.eql(u8, other.definition.id, p.definition.id)) return error.ExtensionAlreadyInstalled;
        }
        try configureScope(p, params, alloc, true);
        if (p.workspace_scoped and p.workspace == null) return error.WorkspaceRequired;
        if (field(params, "state")) |changes| try applyState(p, alloc, changes);
        if (field(params, "persist")) |v| p.persistent = try boolean(v);
        if (p.persistent) try persistPanel(p, alloc);
        try p.show(visible);
        const response = try panelResponse(p, alloc);
        r.panels.appendAssumeCapacity(p);
        return response;
    }
    if (std.mem.eql(u8, method, "extensions.context")) {
        const p = try r.panel(try idParam(params));
        const action = if (field(params, "action")) |id| try p.action(try string(id)) else Action{ .id = "context", .type = .terminal };
        const resolved = try resolveContext(p, action, alloc, field(params, "context") orelse .{ .object = .empty });
        if (field(resolved, "surface") == null) return std.json.Stringify.valueAlloc(alloc, .{ .context = resolved, .program_status = [_]Value{} }, .{});
        const core = try control.findSurface(app, resolved);
        var snapshot = try core.programStatusSnapshot(alloc);
        defer snapshot.deinit(alloc);
        return std.json.Stringify.valueAlloc(alloc, .{ .context = resolved, .program_status = snapshot.records }, .{});
    }
    if (std.mem.eql(u8, method, "extensions.inspect")) {
        if (field(params, "job")) |id| return jobResponse(try r.job(try jobId(id)), alloc);
        return panelResponse(try r.panel(try idParam(params)), alloc);
    }
    if (std.mem.eql(u8, method, "extensions.remove")) {
        const p = try r.panel(try idParam(params));
        if (p.persistent) try removeStored(p.definition.id, alloc);
        r.cancelPanel(p.definition.id);
        for (r.panels.items, 0..) |other, index| {
            if (other == p) {
                _ = r.panels.orderedRemove(index);
                break;
            }
        }
        p.destroy();
        return std.json.Stringify.valueAlloc(alloc, .{ .removed = true }, .{});
    }
    if (std.mem.eql(u8, method, "extensions.update")) {
        const old = try r.panel(try idParam(params));
        try configureScope(old, params, alloc, false);
        const visible = if (field(params, "visible")) |v| try boolean(v) else old.visible();
        const definition = field(params, "definition");
        const patch = field(params, "patch");
        if (definition != null and patch != null) return error.DefinitionAndPatchAreExclusive;
        var p = old;
        if (definition != null or patch != null) {
            const replacement = definition orelse blk: {
                const encoded = try std.json.Stringify.valueAlloc(alloc, old.definition, .{});
                const original = (try std.json.parseFromSlice(Value, alloc, encoded, .{})).value;
                break :blk try mergePatch(alloc, original, patch.?, 0);
            };
            p = try createPanel(r, replacement);
            errdefer p.destroy();
            if (!std.mem.eql(u8, old.definition.id, p.definition.id)) return error.ExtensionIdCannotChange;
            p.workspace_scoped = old.workspace_scoped;
            p.persistent = old.persistent;
            if (old.workspace) |workspace| p.workspace = try gpa.dupe(u8, workspace);
            const previous_state = try stateSnapshot(old, alloc);
            // Keep keys that still match the new definition; drop obsolete UI keys.
            var it = previous_state.object.iterator();
            while (it.next()) |entry| {
                var one: std.json.ObjectMap = .empty;
                try one.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
                applyState(p, alloc, .{ .object = one }) catch continue;
            }
            if (field(params, "state")) |changes| try applyState(p, alloc, changes);
            // Retain both asynchronous jobs and their native output across edits.
            for (r.jobs.items) |j| {
                if (!std.mem.eql(u8, j.panel_id, p.definition.id)) continue;
                if (n.gtk_widget_get_parent(j.output_label)) |parent| n.gtk_box_remove(parent, j.output_label);
                n.gtk_box_append(p.results, j.output_label);
            }
            p.latest_job = old.latest_job;
            for (r.panels.items) |*slot| {
                if (slot.* == old) {
                    slot.* = p;
                    break;
                }
            }
            old.destroy();
        } else if (field(params, "state")) |changes| try applyState(p, alloc, changes);
        if (p.persistent) try persistPanel(p, alloc);
        try p.show(visible);
        return panelResponse(p, alloc);
    }
    if (std.mem.eql(u8, method, "extensions.invoke")) {
        if (field(params, "job")) |id| {
            const j = try r.job(try jobId(id));
            const operation = try string(try required(params, "operation"));
            if (std.mem.eql(u8, operation, "cancel")) {
                j.stop("cancelled");
                return jobResponse(j, alloc);
            }
            if (std.mem.eql(u8, operation, "forget")) {
                j.stop("forgotten");
                for (r.jobs.items, 0..) |other, index| {
                    if (other == j) {
                        _ = r.jobs.orderedRemove(index);
                        break;
                    }
                }
                j.release();
                return std.json.Stringify.valueAlloc(alloc, .{ .forgotten = true }, .{});
            }
            return error.UnknownJobOperation;
        }
        const p = try r.panel(try idParam(params));
        const action_id = try string(try required(params, "action"));
        const id = dispatchAction(p, action_id, field(params, "context") orelse .{ .object = .empty }) catch |err| {
            if (p.last_error == null) p.setError(@errorName(err));
            return err;
        };
        return std.json.Stringify.valueAlloc(alloc, .{ .invoked = true, .job = id }, .{});
    }
    if (std.mem.eql(u8, method, "extensions.export")) return panelResponse(try r.panel(try idParam(params)), alloc);
    if (std.mem.eql(u8, method, "extensions.save")) {
        const p = try r.panel(try idParam(params));
        try configureScope(p, params, alloc, false);
        try persistPanel(p, alloc);
        p.persistent = true;
        return panelResponse(p, alloc);
    }
    if (std.mem.eql(u8, method, "extensions.load")) {
        const catalog = try store.read(alloc);
        const id = try idParam(params);
        for (catalog.object.get("definitions").?.array.items) |entry| {
            const def = try required(entry, "definition");
            if (!std.mem.eql(u8, id, try string(try required(def, "id")))) continue;
            const p = try r.panel(id);
            if (field(params, "scope") != null) return error.LoadDoesNotChangeScope;
            try configureScope(p, params, alloc, true);
            if (p.workspace_scoped and p.workspace == null) return error.WorkspaceRequired;
            try restoreState(p, entry, alloc);
            return panelResponse(p, alloc);
        }
        return error.ExtensionNotSaved;
    }
    return error.UnknownExtensionMethod;
}

fn captureCaller(p: *Panel) void {
    const core = p.runtime.app.core().focusedSurface() orelse return;
    for (p.runtime.app.core().surfaces.items) |surface| {
        if (surface.core() == core) {
            p.caller.set(surface.gobj());
            return;
        }
    }
}

fn resolveContext(p: *Panel, action: Action, alloc: Allocator, context: Value) !Value {
    if (context != .object) return error.ExpectedContextObject;
    var params = Value{ .object = .empty };
    if (action.params == .object) {
        var it = action.params.object.iterator();
        while (it.next()) |entry| try params.object.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    }
    if (field(context, "surface")) |id| {
        try params.object.put(alloc, "surface", .{ .string = try string(id) });
        _ = try control.findSurface(p.runtime.app, params);
    } else switch (action.context) {
        .explicit => return error.RuntimeSurfaceRequired,
        .none => {},
        .focused => {
            const core = p.runtime.app.core().focusedSurface() orelse return error.NoFocusedTerminal;
            try params.object.put(alloc, "surface", .{ .string = try alloc.print("{d}", .{core.id}) });
        },
        .caller => {
            const caller = p.caller.get() orelse return error.RuntimeSurfaceRequired;
            defer caller.unref();
            const core = caller.core() orelse return error.RuntimeSurfaceRequired;
            try params.object.put(alloc, "surface", .{ .string = try alloc.print("{d}", .{core.id}) });
        },
    }
    if (field(params, "surface") != null) {
        const core = try control.findSurface(p.runtime.app, params);
        if (core.rt_surface.gobj().getPwd()) |cwd| try params.object.put(alloc, "cwd", .{ .string = cwd });
    }
    if (p.workspace) |workspace| try params.object.put(alloc, "workspace", .{ .string = workspace });
    return params;
}

fn dispatchAction(p: *Panel, id: []const u8, context: Value) !?u64 {
    if (p.runtime.app.agentControl() == null) return error.AgentFeatureDisabled;
    if (p.workspace_scoped and p.workspace == null) return error.WorkspaceRequired;
    const action = try p.action(id);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const resolved = try resolveContext(p, action, alloc, context);
    if (p.last_error) |old| gpa.free(old);
    p.last_error = null;
    switch (action.type) {
        .terminal => {
            if (!try control.performBinding(p.runtime.app, alloc, resolved)) return error.TerminalActionFailed;
            n.gtk_label_set_text(p.status, "Gizmo terminal action completed");
            return null;
        },
        .workflow => {
            const j = try startJob(p, action, resolved);
            p.latest_job = j.id;
            n.gtk_label_set_text(p.status, "Latest Gizmo workflow: inspect latest_job");
            return j.id;
        },
    }
}

const Pipe = struct {
    job: *Job,
    stream: *n.Object,
    bytes: std.ArrayList(u8) = .empty,
    done: bool = false,
};
const Job = struct {
    id: u64,
    panel_id: []const u8,
    process: *n.Object,
    process_group: ?c_int,
    cancellable: *n.Object,
    output_label: *n.Widget,
    pipes: [2]Pipe,
    refs: usize = 1,
    timer: c_uint = 0,
    exited: bool = false,
    exit_code: ?c_int = null,
    signal: ?c_int = null,
    reason: ?[]const u8 = null,
    truncated: bool = false,

    fn release(self: *Job) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        for (&self.pipes) |*pipe| pipe.bytes.deinit(gpa);
        if (n.gtk_widget_get_parent(self.output_label)) |parent| n.gtk_box_remove(parent, self.output_label);
        n.g_object_unref(self.output_label);
        n.g_object_unref(self.cancellable);
        n.g_object_unref(self.process);
        gpa.free(self.panel_id);
        if (self.reason) |reason| gpa.free(reason);
        gpa.destroy(self);
    }

    fn note(self: *Job, reason: []const u8) void {
        if (self.reason == null) self.reason = gpa.dupe(u8, reason) catch null;
    }

    fn stop(self: *Job, reason: []const u8) void {
        if (self.complete()) return;
        self.note(reason);
        if (self.timer != 0) {
            _ = n.g_source_remove(self.timer);
            self.timer = 0;
        }
        n.g_cancellable_cancel(self.cancellable);
        if (self.process_group) |pid| _ = n.kill(-pid, 9);
        if (!self.exited) n.g_subprocess_force_exit(self.process);
    }

    fn complete(self: *const Job) bool {
        return self.exited and self.pipes[0].done and self.pipes[1].done;
    }

    fn refresh(self: *Job) void {
        if (!self.complete()) return;
        if (self.timer != 0) {
            _ = n.g_source_remove(self.timer);
            self.timer = 0;
        }
        // The control API retains all bounded output. Keep the native summary
        // short enough for a responsive, usable panel, even with large output.
        const out = self.pipes[0].bytes.items;
        const err = self.pipes[1].bytes.items;
        const out_text = nativeOutput(out, "[binary stdout: inspect base64]");
        const err_text = nativeOutput(err, "[binary stderr: inspect base64]");
        const text = gpa.printSentinel("Gizmo job {d} finished · exit {any} · signal {any}\n{s}\nstdout:\n{s}\nstderr:\n{s}", .{ self.id, self.exit_code, self.signal, self.reason orelse "", out_text, err_text }, 0) catch return;
        defer gpa.free(text);
        n.gtk_label_set_text(self.output_label, text);
    }
};

fn nativeOutput(bytes: []const u8, binary: []const u8) []const u8 {
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return binary;
    var end = @min(bytes.len, 8192);
    while (end < bytes.len and end > 0 and bytes[end] & 0xc0 == 0x80) end -= 1;
    return bytes[0..end];
}

fn startJob(p: *Panel, action: Action, context: Value) !*Job {
    const r = p.runtime;
    if (r.jobs.items.len >= max_jobs) return error.TooManyJobsForgetCompletedJobs;
    if (r.next_job > std.math.maxInt(i64)) return error.JobIdsExhausted;
    try r.jobs.ensureUnusedCapacity(gpa, 1);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const values = try stateSnapshot(p, alloc);
    const argv = try alloc.allocSentinel(?[*:0]const u8, action.argv.len, null);
    for (action.argv, argv) |arg, *output| {
        const text = if (arg == .string) arg.string else blk: {
            if (field(arg, "context")) |key| {
                const name = try string(key);
                break :blk try string(field(context, name) orelse return error.ContextValueUnavailable);
            }
            if (field(arg, "state")) |key| {
                const value = values.object.get(try string(key)) orelse return error.StateValueUnavailable;
                break :blk switch (value) {
                    .string => value.string,
                    .bool => if (value.bool) "true" else "false",
                    .integer => try alloc.print("{d}", .{value.integer}),
                    else => return error.InvalidArgumentState,
                };
            }
            const item = try p.element(try string(try required(arg, "element")));
            const current = try state(item, alloc);
            break :blk switch (current) {
                .string => current.string,
                .bool => if (current.bool) "true" else "false",
                .integer => item.definition.options[@intCast(current.integer)],
                else => return error.InvalidArgumentElement,
            };
        };
        if (!validText(text, max_text)) return error.InvalidArgument;
        output.* = (try alloc.dupeSentinel(u8, text, 0)).ptr;
    }
    const j = try gpa.create(Job);
    errdefer gpa.destroy(j);
    const panel_id = try gpa.dupe(u8, p.definition.id);
    errdefer gpa.free(panel_id);
    // G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE.
    // Without STDIN_PIPE or STDIN_INHERIT, GIO redirects stdin to /dev/null.
    const launcher = n.g_subprocess_launcher_new(4 | 16);
    defer n.g_object_unref(launcher);
    n.g_subprocess_launcher_set_child_setup(launcher, &childSetup, null, null);
    if (action.cwd) |cwd| n.g_subprocess_launcher_set_cwd(launcher, try alloc.dupeSentinel(u8, cwd, 0));
    var failure: ?*n.Error = null;
    const process = n.g_subprocess_launcher_spawnv(launcher, argv.ptr, &failure) orelse {
        if (failure) |err| {
            defer n.g_error_free(err);
            p.setError(std.mem.span(err.message));
        }
        return error.WorkflowSpawnFailed;
    };
    const label = n.gtk_label_new("Gizmo workflow running…");
    _ = n.g_object_ref_sink(label);
    n.gtk_label_set_xalign(label, 0);
    n.gtk_label_set_wrap(label, 1);
    n.gtk_label_set_selectable(label, 1);
    n.gtk_box_append(p.results, label);
    j.* = .{
        .id = r.next_job,
        .panel_id = panel_id,
        .process = process,
        .process_group = if (n.g_subprocess_get_identifier(process)) |pid| std.fmt.parseInt(c_int, std.mem.span(pid), 10) catch null else null,
        .cancellable = n.g_cancellable_new(),
        .output_label = label,
        .pipes = .{
            .{ .job = j, .stream = n.g_subprocess_get_stdout_pipe(process).? },
            .{ .job = j, .stream = n.g_subprocess_get_stderr_pipe(process).? },
        },
        .refs = 4, // Registry, stdout reader, stderr reader, process waiter.
    };
    r.next_job += 1;
    r.jobs.appendAssumeCapacity(j);
    j.timer = n.g_timeout_add_seconds(action.timeout_seconds, &jobTimeout, j);
    for (&j.pipes) |*pipe| readPipe(pipe);
    n.g_subprocess_wait_async(process, null, &processReady, j);
    return j;
}

fn readPipe(pipe: *Pipe) void {
    n.g_input_stream_read_bytes_async(pipe.stream, 8192, 0, pipe.job.cancellable, &pipeReady, pipe);
}
fn pipeReady(_: ?*n.Object, result: *n.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const pipe: *Pipe = @ptrCast(@alignCast(data orelse return));
    const j = pipe.job;
    var failure: ?*n.Error = null;
    const bytes = n.g_input_stream_read_bytes_finish(pipe.stream, result, &failure);
    if (failure) |err| {
        j.note(std.mem.span(err.message));
        n.g_error_free(err);
    }
    var again = false;
    if (bytes) |chunk| {
        defer n.g_bytes_unref(chunk);
        var len: usize = 0;
        if (n.g_bytes_get_data(chunk, &len)) |ptr| {
            if (len != 0) {
                const keep = @min(len, max_output - pipe.bytes.items.len);
                pipe.bytes.appendSlice(gpa, ptr[0..keep]) catch {
                    j.stop("output allocation failed");
                    pipe.done = true;
                    j.refresh();
                    j.release();
                    return;
                };
                if (keep != len or pipe.bytes.items.len == max_output) {
                    j.truncated = true;
                    j.stop("output limit reached");
                } else again = true;
            }
        }
    }
    if (again) {
        readPipe(pipe);
    } else {
        pipe.done = true;
        j.refresh();
        j.release();
    }
}
fn processReady(_: ?*n.Object, result: *n.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const j: *Job = @ptrCast(@alignCast(data orelse return));
    var failure: ?*n.Error = null;
    if (n.g_subprocess_wait_finish(j.process, result, &failure) == 0) {
        if (failure) |err| {
            j.note(std.mem.span(err.message));
            n.g_error_free(err);
        }
    } else {
        if (n.g_subprocess_get_if_exited(j.process) != 0) j.exit_code = n.g_subprocess_get_exit_status(j.process);
        if (n.g_subprocess_get_if_signaled(j.process) != 0) j.signal = n.g_subprocess_get_term_sig(j.process);
    }
    // Finish cleanup of the original group, then discard its identifier.
    // Later cancellation must not signal a group ID the kernel can reuse.
    if (j.process_group) |pid| _ = n.kill(-pid, 9);
    j.process_group = null;
    j.exited = true;
    j.refresh();
    j.release();
}
fn jobTimeout(data: ?*anyopaque) callconv(.c) c_int {
    const j: *Job = @ptrCast(@alignCast(data orelse return 0));
    j.timer = 0;
    j.stop("timeout");
    return 0;
}
fn base64(alloc: Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const result = try alloc.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(result, bytes);
}
fn jobResponse(j: *Job, alloc: Allocator) ![]const u8 {
    const out = j.pipes[0].bytes.items;
    const err = j.pipes[1].bytes.items;
    return std.json.Stringify.valueAlloc(alloc, .{
        .job = j.id,
        .extension = j.panel_id,
        .status = if (j.complete()) "completed" else if (j.reason != null) "stopping" else "running",
        .exit_code = j.exit_code,
        .signal = j.signal,
        .reason = j.reason,
        .truncated = j.truncated,
        .stdout = if (std.unicode.utf8ValidateSlice(out)) out else null,
        .stderr = if (std.unicode.utf8ValidateSlice(err)) err else null,
        .stdout_base64 = try base64(alloc, out),
        .stderr_base64 = try base64(alloc, err),
    }, .{});
}

fn childSetup(_: ?*anyopaque) callconv(.c) void {
    // Only async-signal-safe C calls are permitted between fork and exec.
    if (n.setsid() < 0) n._exit(127);
}

test "native workflow output truncation preserves UTF-8" {
    const testing = std.testing;
    const bytes = try testing.allocator.alloc(u8, 8194);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'a');
    @memcpy(bytes[8191..8194], "€");
    const text = nativeOutput(bytes, "binary");
    try testing.expectEqual(@as(usize, 8191), text.len);
    try testing.expect(std.unicode.utf8ValidateSlice(text));
    try testing.expectEqualStrings("binary", nativeOutput("a\x00b", "binary"));
}
