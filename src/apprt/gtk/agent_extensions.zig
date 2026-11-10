//! Gizmo's opt-in, session-local extension panels.
//!
//! Only the authenticated local agent-control dispatcher calls `request`.
//! Definitions are inert: installing/updating a panel never runs an action.
//! Buttons run actions only after a native click or `extensions.invoke`.
//!
//! Request parameters:
//! - list: {}
//! - install: {definition: Definition, visible?: bool}
//! - inspect: {id: string} or {job: integer}
//! - update: {id: string, definition?: Definition, patch?: object,
//!            state?: {element_id: string|bool|integer}, visible?: bool}
//!   `patch` is JSON Merge Patch applied to the stored definition. Definition
//!   changes rebuild the panel; provide state explicitly to restore edited values.
//! - remove: {id: string}; cancels this panel's jobs.
//! - invoke: {id: string, element: string} or
//!           {job: integer, operation: "cancel"|"forget"}
//!
//! Definition: {id, title, elements: [{id, type, label?, text?, active?,
//!                                  options?, selected?, action?}]}.
//! Types: label, entry, button, toggle, selection. Entry state is a string,
//! toggle state is a boolean, selection state is its zero-based integer index.
//! Button actions: {type:"terminal", params:{surface:ID,action:"..."}} or
//! {type:"workflow", argv:["/absolute/executable", "literal", {element:"id"}],
//!  cwd?:"/absolute/directory", timeout_seconds?:300}.
//! Element arguments replace ONE argv item, never shell-interpolate. Toggle
//! arguments are "true"/"false"; selection arguments use the selected text.
//! Executables and cwd must be absolute. Tools inherit the user's environment
//! and get a closed stdin. Cancellation kills the tool's process group.
//! Descendants that create another session or process group are not tracked.
//! Each stream is limited to 1 MiB; reaching the limit terminates the tool.
//! Jobs use GIO async pipe reads/waits, with a 1..3600 second deadline.
//! Inspect exposes UTF-8 stdout/stderr when valid, plus lossless base64 output.
//! No state is written to disk; callers can save/reinstall definitions themselves.
//! Closing a panel hides it; jobs continue until completion, deadline, or removal.
//! Removal forgets retained jobs. `forget` releases one job and its output widget.

const std = @import("std");
const Application = @import("class/application.zig").Application;
const control = @import("agent_control.zig");
const n = @import("agent_extensions_native.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const gpa = std.heap.c_allocator;
const max_elements = 128;
const max_panels = 32;
const max_jobs = 64;
const max_output = 1024 * 1024;
const max_text = 16384;

const Kind = enum { label, entry, button, toggle, selection };
const Action = struct {
    type: enum { terminal, workflow },
    params: Value = .null,
    argv: []const Value = &.{},
    cwd: ?[]const u8 = null,
    timeout_seconds: u32 = 300,
};
const Element = struct {
    id: []const u8,
    type: Kind,
    label: []const u8 = "",
    text: []const u8 = "",
    active: bool = false,
    options: []const []const u8 = &.{},
    selected: u32 = 0,
    action: ?Action = null,
};
const Definition = struct {
    id: []const u8,
    title: []const u8,
    elements: []const Element,
};
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
    window: *n.Widget,
    results: *n.Widget,
    status: *n.Widget,
    last_error: ?[]const u8 = null,
    latest_job: ?u64 = null,

    fn destroy(self: *Panel) void {
        // Destroy widgets before freeing callback data in the arena.
        n.gtk_window_destroy(self.window);
        n.g_object_unref(self.window);
        if (self.last_error) |message| gpa.free(message);
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn element(self: *Panel, id: []const u8) !*ElementUI {
        for (self.elements) |*item| {
            if (std.mem.eql(u8, id, item.definition.id)) return item;
        }
        return error.UnknownElement;
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
fn validText(text: []const u8, limit: usize) bool {
    return text.len <= limit and std.mem.indexOfScalar(u8, text, 0) == null and std.unicode.utf8ValidateSlice(text);
}
fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

fn validate(def: Definition) !void {
    if (!validId(def.id)) return error.InvalidExtensionId;
    if (!validText(def.title, 256)) return error.InvalidTitle;
    if (def.elements.len > max_elements) return error.TooManyElements;
    for (def.elements, 0..) |item, index| {
        if (!validId(item.id)) return error.InvalidElementId;
        for (def.elements[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, item.id)) return error.DuplicateElementId;
        }
        if (!validText(item.label, max_text) or !validText(item.text, max_text)) return error.InvalidText;
        if (item.options.len > max_elements) return error.TooManyOptions;
        for (item.options) |option| if (!validText(option, max_text)) return error.InvalidOption;
        if (item.type == .selection and (item.options.len == 0 or item.selected >= item.options.len)) return error.InvalidSelection;
        if (item.type == .button and item.action == null) return error.MissingButtonAction;
        if (item.action) |action| {
            if (item.type != .button) return error.ActionsRequireButton;
            switch (action.type) {
                .terminal => {
                    if (action.params != .object) return error.InvalidTerminalAction;
                    _ = try string(try required(action.params, "action"));
                },
                .workflow => {
                    if (action.argv.len == 0 or action.argv.len > 128) return error.InvalidArgv;
                    const executable = try string(action.argv[0]);
                    if (!std.fs.path.isAbsolute(executable)) return error.ExecutableMustBeAbsolute;
                    if (action.timeout_seconds == 0 or action.timeout_seconds > 3600) return error.InvalidTimeout;
                    if (action.cwd) |cwd| {
                        if (!validText(cwd, max_text) or !std.fs.path.isAbsolute(cwd)) return error.InvalidWorkingDirectory;
                    }
                    for (action.argv) |arg| {
                        if (arg == .string) {
                            if (!validText(arg.string, max_text)) return error.InvalidArgument;
                        } else if (arg == .object and arg.object.count() == 1) {
                            const target = try string(try required(arg, "element"));
                            var found = false;
                            for (def.elements) |other| {
                                if (std.mem.eql(u8, target, other.id) and other.type != .button) found = true;
                            }
                            if (!found) return error.InvalidArgumentElement;
                        } else return error.InvalidArgument;
                    }
                },
            }
        }
    }
}

fn createPanel(r: *Runtime, value: Value) !*Panel {
    // Reparse a serialized value so the panel never borrows request storage.
    const p = try gpa.create(Panel);
    errdefer gpa.destroy(p);
    p.arena = std.heap.ArenaAllocator.init(gpa);
    errdefer p.arena.deinit();
    const alloc = p.arena.allocator();
    const json = try std.json.Stringify.valueAlloc(alloc, value, .{});
    if (json.len > 512 * 1024) return error.DefinitionTooLarge;
    const parsed = try std.json.parseFromSlice(Definition, alloc, json, .{ .allocate = .alloc_always });
    const def = parsed.value;
    try validate(def);
    const ui = try alloc.alloc(ElementUI, def.elements.len);
    const app: *n.Object = @ptrCast(r.app.as(@import("gtk").Application));
    const parent = n.gtk_application_get_active_window(app);
    const window = n.gtk_application_window_new(app);
    _ = n.g_object_ref(window);
    errdefer {
        n.gtk_window_destroy(window);
        n.g_object_unref(window);
    }
    n.gtk_window_set_title(window, try alloc.dupeSentinel(u8, def.title, 0));
    n.gtk_window_set_default_size(window, 480, 480);
    n.gtk_window_set_hide_on_close(window, 1);
    n.gtk_window_set_transient_for(window, parent);
    const box = n.gtk_box_new(1, 8); // GTK_ORIENTATION_VERTICAL
    n.gtk_widget_set_margin_top(box, 12);
    n.gtk_widget_set_margin_bottom(box, 12);
    n.gtk_widget_set_margin_start(box, 12);
    n.gtk_widget_set_margin_end(box, 12);
    const scroll = n.gtk_scrolled_window_new();
    n.gtk_scrolled_window_set_child(scroll, box);
    n.gtk_window_set_child(window, scroll);
    const status = n.gtk_label_new("Gizmo extension · session only");
    n.gtk_label_set_wrap(status, 1);
    const results = n.gtk_box_new(1, 8);
    p.* = .{ .arena = p.arena, .runtime = r, .definition = def, .elements = ui, .window = window, .results = results, .status = status };
    for (def.elements, ui) |*item, *element| {
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
        element.* = .{ .panel = p, .definition = item, .widget = widget };
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

fn buttonClicked(_: *n.Widget, data: ?*anyopaque) callconv(.c) void {
    const item: *ElementUI = @ptrCast(@alignCast(data orelse return));
    _ = invoke(item) catch |err| {
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
    if (changes != .object) return error.ExpectedStateObject;
    var it = changes.object.iterator();
    while (it.next()) |entry| {
        const item = try p.element(entry.key_ptr.*);
        const value = entry.value_ptr.*;
        switch (item.definition.type) {
            .entry, .label => if (!validText(try string(value), max_text)) return error.InvalidText,
            .toggle => _ = try boolean(value),
            .selection => if (value != .integer or value.integer < 0 or @as(u64, @intCast(value.integer)) >= item.definition.options.len) return error.InvalidSelection,
            .button => return error.ButtonHasNoState,
        }
    }
}
fn applyState(p: *Panel, alloc: Allocator, changes: Value) !void {
    try validateState(p, changes);
    var it = changes.object.iterator();
    while (it.next()) |entry| {
        const item = try p.element(entry.key_ptr.*);
        const value = entry.value_ptr.*;
        switch (item.definition.type) {
            .entry => n.gtk_editable_set_text(item.widget, try alloc.dupeSentinel(u8, value.string, 0)),
            .label => n.gtk_label_set_text(item.widget, try alloc.dupeSentinel(u8, value.string, 0)),
            .toggle => n.gtk_check_button_set_active(item.widget, @intFromBool(value.bool)),
            .selection => n.gtk_drop_down_set_selected(item.widget, @intCast(value.integer)),
            .button => unreachable,
        }
    }
}

fn panelResponse(p: *Panel, alloc: Allocator) ![]const u8 {
    var values: std.json.ObjectMap = .empty;
    for (p.elements) |*item| try values.put(alloc, item.definition.id, try state(item, alloc));
    var job_ids: std.ArrayList(u64) = .empty;
    defer job_ids.deinit(alloc);
    for (p.runtime.jobs.items) |j| {
        if (std.mem.eql(u8, j.panel_id, p.definition.id)) try job_ids.append(alloc, j.id);
    }
    return std.json.Stringify.valueAlloc(alloc, .{
        .scope = "session",
        .definition = p.definition,
        .state = Value{ .object = values },
        .visible = n.gtk_widget_get_visible(p.window) != 0,
        .last_error = p.last_error,
        .latest_job = p.latest_job,
        .jobs = job_ids.items,
    }, .{});
}

fn mergePatch(alloc: Allocator, target: Value, patch: Value, depth: usize) error{ OutOfMemory, PatchTooDeep }!Value {
    if (depth > 32) return error.PatchTooDeep;
    if (patch != .object) return patch;
    var result = if (target == .object) target else Value{ .object = .empty };
    var it = patch.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .null) {
            _ = result.object.swapRemove(entry.key_ptr.*);
        } else {
            const old = result.object.get(entry.key_ptr.*) orelse .null;
            try result.object.put(alloc, entry.key_ptr.*, try mergePatch(alloc, old, entry.value_ptr.*, depth + 1));
        }
    }
    return result;
}

/// Returns a JSON payload (not an agent-control response envelope).
/// This function and all extension state run only on the GTK main thread.
/// `alloc` is the authenticated dispatcher's request-scoped arena allocator.
pub fn request(app: *Application, alloc: Allocator, value: Value) ![]const u8 {
    const method = try string(try required(value, "method"));
    const params = field(value, "params") orelse Value{ .object = .empty };
    if (params != .object) return error.ExpectedParametersObject;
    if (field(params, "persist") != null or field(params, "persist_path") != null or field(params, "persistent") != null) return error.ExtensionsAreSessionOnly;
    if (std.mem.eql(u8, method, "extensions.discover")) return discover(alloc);
    const r = try runtime(app);
    if (std.mem.eql(u8, method, "extensions.list")) {
        var summaries: std.ArrayList(Value) = .empty;
        defer summaries.deinit(alloc);
        for (r.panels.items) |p| {
            const encoded = try std.json.Stringify.valueAlloc(alloc, .{
                .id = p.definition.id,
                .title = p.definition.title,
                .visible = n.gtk_widget_get_visible(p.window) != 0,
                .latest_job = p.latest_job,
            }, .{});
            try summaries.append(alloc, (try std.json.parseFromSlice(Value, alloc, encoded, .{})).value);
        }
        return std.json.Stringify.valueAlloc(alloc, .{ .scope = "session", .extensions = summaries.items }, .{});
    }
    if (std.mem.eql(u8, method, "extensions.install")) {
        if (r.panels.items.len >= max_panels) return error.TooManyExtensions;
        try r.panels.ensureUnusedCapacity(gpa, 1);
        const visible = if (field(params, "visible")) |v| try boolean(v) else true;
        const p = try createPanel(r, try required(params, "definition"));
        errdefer p.destroy();
        for (r.panels.items) |other| {
            if (std.mem.eql(u8, other.definition.id, p.definition.id)) return error.ExtensionAlreadyInstalled;
        }
        if (visible) n.gtk_window_present(p.window);
        const response = try panelResponse(p, alloc);
        r.panels.appendAssumeCapacity(p);
        return response;
    }
    if (std.mem.eql(u8, method, "extensions.inspect")) {
        if (field(params, "job")) |id| return jobResponse(try r.job(try jobId(id)), alloc);
        return panelResponse(try r.panel(try idParam(params)), alloc);
    }
    if (std.mem.eql(u8, method, "extensions.remove")) {
        const p = try r.panel(try idParam(params));
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
        const visible = if (field(params, "visible")) |v| try boolean(v) else n.gtk_widget_get_visible(old.window) != 0;
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
        if (visible) n.gtk_window_present(p.window) else n.gtk_widget_set_visible(p.window, 0);
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
        const item = try p.element(try string(try required(params, "element")));
        const id = invoke(item) catch |err| {
            if (p.last_error == null) p.setError(@errorName(err));
            return err;
        };
        return std.json.Stringify.valueAlloc(alloc, .{ .invoked = true, .job = id }, .{});
    }
    return error.UnknownExtensionMethod;
}

fn invoke(item: *ElementUI) !?u64 {
    if (item.definition.type != .button) return error.ElementIsNotButton;
    const action = item.definition.action orelse return error.MissingButtonAction;
    const p = item.panel;
    if (p.last_error) |old| gpa.free(old);
    p.last_error = null;
    switch (action.type) {
        .terminal => {
            if (!try control.performBinding(p.runtime.app, gpa, action.params)) return error.TerminalActionFailed;
            n.gtk_label_set_text(p.status, "Gizmo terminal action completed");
            return null;
        },
        .workflow => {
            const j = try startJob(p, action);
            p.latest_job = j.id;
            n.gtk_label_set_text(p.status, "Latest Gizmo workflow: see results below or inspect latest_job");
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

fn startJob(p: *Panel, action: Action) !*Job {
    const r = p.runtime;
    if (r.jobs.items.len >= max_jobs) return error.TooManyJobsForgetCompletedJobs;
    if (r.next_job > std.math.maxInt(i64)) return error.JobIdsExhausted;
    try r.jobs.ensureUnusedCapacity(gpa, 1);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try alloc.allocSentinel(?[*:0]const u8, action.argv.len, null);
    for (action.argv, argv) |arg, *output| {
        const text = if (arg == .string) arg.string else blk: {
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

fn discover(alloc: Allocator) ![]const u8 {
    const example =
        \\{"method":"extensions.install","params":{"definition":{"id":"hello","title":"Gizmo tools","elements":[{"id":"intro","type":"label","text":"Run a tool without shell interpolation."},{"id":"name","type":"entry","label":"Name","text":"Gizmo"},{"id":"verbose","type":"toggle","label":"Verbose"},{"id":"mode","type":"selection","label":"Mode","options":["short","long"]},{"id":"run","type":"button","label":"Run","action":{"type":"workflow","argv":["/usr/bin/printf","Hello %s\\n",{"element":"name"}]}}]}}}
    ;
    const installation = (try std.json.parseFromSlice(Value, alloc, example, .{})).value;
    return std.json.Stringify.valueAlloc(alloc, .{
        .scope = "session",
        .persistence = false,
        .methods = .{
            .@"extensions.list" = "{}",
            .@"extensions.install" = "{definition,visible?:bool}",
            .@"extensions.inspect" = "{id:string} | {job:integer}",
            .@"extensions.update" = "{id,definition?:object,patch?:object,state?:object,visible?:bool}",
            .@"extensions.remove" = "{id:string}",
            .@"extensions.invoke" = "{id,element} | {job,operation:cancel|forget}",
        },
        .limits = .{ .panels = max_panels, .elements = max_elements, .retained_jobs = max_jobs, .output_bytes_per_stream = max_output },
        .element_types = [_][]const u8{ "label", "entry", "button", "toggle", "selection" },
        .state = "Map element IDs to strings (entry/label), booleans (toggle), or zero-based integer indices (selection). State changes never execute actions.",
        .patch = "JSON Merge Patch of definition; arrays replace. Definition rebuilds reset edits unless state is supplied.",
        .terminal_action = .{ .type = "terminal", .params = .{ .surface = "ID from tree", .action = "copy_to_clipboard" } },
        .workflow = "Explicit absolute executable argv. Each argument is a literal string or {element:ID}, substituted as one argument. Optional absolute cwd and timeout_seconds (1..3600, default 300). No install-time execution.",
        .jobs = "Inspect exposes running/completed status, exit_code, signal, reason, truncated, stdout/stderr UTF-8 or null, and lossless stdout_base64/stderr_base64. Cancel kills the tool's process group; forget also releases retained results. Removal cancels and forgets panel jobs. Descendants that create another session or process group are not tracked.",
        .install_example = installation,
        .invoke_example = .{ .method = "extensions.invoke", .params = .{ .id = "hello", .element = "run" } },
        .inspect_job_example = .{ .method = "extensions.inspect", .params = .{ .job = 1 } },
    }, .{});
}

test "extension definitions reject automatic actions and invalid argv" {
    const testing = std.testing;
    try testing.expectError(error.ActionsRequireButton, validate(.{
        .id = "tools",
        .title = "Gizmo tools",
        .elements = &.{.{ .id = "input", .type = .entry, .action = .{ .type = .workflow, .argv = &.{} } }},
    }));
    try testing.expectError(error.ExecutableMustBeAbsolute, validate(.{
        .id = "tools",
        .title = "Gizmo tools",
        .elements = &.{.{ .id = "run", .type = .button, .action = .{ .type = .workflow, .argv = &.{.{ .string = "printf" }} } }},
    }));
}

test "extension definitions require unique IDs and valid selection" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateElementId, validate(.{
        .id = "tools",
        .title = "Gizmo tools",
        .elements = &.{ .{ .id = "same", .type = .entry }, .{ .id = "same", .type = .label } },
    }));
    try testing.expectError(error.InvalidSelection, validate(.{
        .id = "tools",
        .title = "Gizmo tools",
        .elements = &.{.{ .id = "select", .type = .selection, .options = &.{"one"}, .selected = 1 }},
    }));
}

test "extension merge patch replaces arrays and removes fields" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const original = (try std.json.parseFromSlice(Value, alloc, "{\"title\":\"old\",\"elements\":[1,2],\"remove\":true}", .{})).value;
    const patch = (try std.json.parseFromSlice(Value, alloc, "{\"title\":\"new\",\"elements\":[3],\"remove\":null}", .{})).value;
    const result = try mergePatch(alloc, original, patch, 0);
    try testing.expectEqualStrings("new", result.object.get("title").?.string);
    try testing.expectEqual(@as(usize, 1), result.object.get("elements").?.array.items.len);
    try testing.expectEqual(@as(i64, 3), result.object.get("elements").?.array.items[0].integer);
    try testing.expect(result.object.get("remove") == null);
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
