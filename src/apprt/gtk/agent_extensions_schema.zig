//! Shared inert extension definitions, validation, state, and discovery contract.
const std = @import("std");
const store = @import("agent_extensions_store.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
pub const max_elements = 128;
pub const max_panels = 32;
const max_jobs = 64;
const max_output = 1024 * 1024;
pub const max_text = 16384;
pub const Kind = enum { label, entry, button, toggle, selection };
pub const Action = struct {
    id: []const u8,
    title: []const u8 = "",
    palette: bool = true,
    context: enum { caller, focused, explicit, none } = .caller,
    type: enum { terminal, workflow },
    params: Value = .null,
    argv: []const Value = &.{},
    cwd: ?[]const u8 = null,
    timeout_seconds: u32 = 300,
};
pub const Element = struct {
    id: []const u8,
    type: Kind,
    label: []const u8 = "",
    text: []const u8 = "",
    active: bool = false,
    options: []const []const u8 = &.{},
    selected: u32 = 0,
    action: ?[]const u8 = null,
};
pub const Definition = struct {
    id: []const u8,
    title: []const u8,
    actions: []const Action = &.{},
    elements: []const Element = &.{},
    panel: bool = false,
};

pub fn field(value: Value, name: []const u8) ?Value {
    return if (value == .object) value.object.get(name) else null;
}
pub fn string(value: Value) ![]const u8 {
    return if (value == .string) value.string else error.ExpectedString;
}
pub fn required(value: Value, name: []const u8) !Value {
    return field(value, name) orelse error.MissingParameter;
}
pub fn boolean(value: Value) !bool {
    return if (value == .bool) value.bool else error.ExpectedBoolean;
}

pub const Scope = enum { app, workspace };
pub fn parseScope(value: Value) !Scope {
    return std.meta.stringToEnum(Scope, try string(value)) orelse error.InvalidExtensionScope;
}
pub fn jsonValue(alloc: Allocator, value: anytype) !Value {
    const bytes = try std.json.Stringify.valueAlloc(alloc, value, .{});
    return (try std.json.parseFromSlice(Value, alloc, bytes, .{})).value;
}
pub fn parseDefinition(alloc: Allocator, value: Value) !Definition {
    const json = try std.json.Stringify.valueAlloc(alloc, value, .{});
    if (json.len > 512 * 1024) return error.DefinitionTooLarge;
    const parsed = try std.json.parseFromSlice(Definition, alloc, json, .{ .allocate = .alloc_always });
    try validate(parsed.value);
    return parsed.value;
}

fn element(def: Definition, id: []const u8) ?Element {
    for (def.elements) |item| {
        if (std.mem.eql(u8, item.id, id)) return item;
    }
    return null;
}

pub fn validateState(def: Definition, changes: Value) !void {
    if (changes != .object) return error.ExpectedStateObject;
    if (changes.object.count() > 2 * max_elements) return error.TooManyStateKeys;
    var custom: usize = 0;
    var it = changes.object.iterator();
    while (it.next()) |entry| {
        try validateStateValue(def, entry.key_ptr.*, entry.value_ptr.*);
        if (element(def, entry.key_ptr.*) == null) custom += 1;
    }
    if (custom > max_elements) return error.TooManyStateKeys;
}

pub fn validateDataValue(key: []const u8, value: Value) !void {
    if (!validId(key)) return error.InvalidStateKey;
    switch (value) {
        .string => |text| if (!validText(text, max_text)) return error.InvalidText,
        .bool, .integer, .null => {},
        else => return error.InvalidStateValue,
    }
}

pub fn validateStateValue(def: Definition, key: []const u8, value: Value) !void {
    const item = element(def, key) orelse return validateDataValue(key, value);
    switch (item.type) {
        .entry, .label => if (!validText(try string(value), max_text)) return error.InvalidText,
        .toggle => _ = try boolean(value),
        .selection => if (value != .integer or value.integer < 0 or @as(u64, @intCast(value.integer)) >= item.options.len) return error.InvalidSelection,
        .button => return error.ButtonHasNoState,
    }
}

pub fn defaultState(alloc: Allocator, def: Definition) !Value {
    var values: std.json.ObjectMap = .empty;
    for (def.elements) |item| {
        const value: Value = switch (item.type) {
            .entry, .label => .{ .string = item.text },
            .toggle => .{ .bool = item.active },
            .selection => .{ .integer = item.selected },
            .button => continue,
        };
        try values.put(alloc, item.id, value);
    }
    return .{ .object = values };
}

/// Definition edits retain exactly the values the live replacement accepts.
pub fn compatibleState(alloc: Allocator, def: Definition, previous: Value) !Value {
    var result = try defaultState(alloc, def);
    var custom: usize = 0;
    var it = previous.object.iterator();
    while (it.next()) |entry| {
        validateStateValue(def, entry.key_ptr.*, entry.value_ptr.*) catch continue;
        if (element(def, entry.key_ptr.*) == null) {
            if (custom == max_elements) continue;
            custom += 1;
        }
        try result.object.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    }
    return result;
}

/// Restore one slot using current defaults and compatible saved values.
/// Older workspace slots can predate a definition edit in another workspace.
pub fn restoredState(alloc: Allocator, def: Definition, entry: Value, workspace: ?[]const u8) !Value {
    const states = try required(entry, "states");
    if (states != .array or states.array.items.len > 64) return error.InvalidExtensionStore;
    for (states.array.items) |slot| {
        const key = try required(slot, "workspace");
        const matches = if (workspace) |path|
            key == .string and std.mem.eql(u8, key.string, path)
        else
            key == .null;
        if (!matches) continue;
        const saved = try required(slot, "state");
        if (saved != .object) return error.ExpectedStateObject;
        if (saved.object.count() > 2 * max_elements) return error.TooManyStateKeys;
        return compatibleState(alloc, def, saved);
    }
    return defaultState(alloc, def);
}

pub fn updateState(alloc: Allocator, def: Definition, previous: Value, changes: Value) !Value {
    try validateState(def, changes);
    var result = previous;
    var it = changes.object.iterator();
    while (it.next()) |entry| try result.object.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    // Live panels bound custom data separately from the defined UI fields.
    var custom: usize = 0;
    var values = result.object.iterator();
    while (values.next()) |entry| {
        if (element(def, entry.key_ptr.*) == null) custom += 1;
    }
    if (custom > max_elements) return error.TooManyStateKeys;
    return result;
}

pub fn validText(text: []const u8, limit: usize) bool {
    return text.len <= limit and std.mem.indexOfScalar(u8, text, 0) == null and std.unicode.utf8ValidateSlice(text);
}
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

pub fn validate(def: Definition) !void {
    if (!validId(def.id)) return error.InvalidExtensionId;
    if (!validText(def.title, 256)) return error.InvalidTitle;
    if (def.elements.len > max_elements) return error.TooManyElements;
    if (def.actions.len > max_elements) return error.TooManyActions;
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
        if (item.action) |id| {
            if (item.type != .button) return error.ActionsRequireButton;
            var found = false;
            for (def.actions) |action| {
                if (std.mem.eql(u8, action.id, id)) found = true;
            }
            if (!found) return error.UnknownAction;
        }
    }
    for (def.actions, 0..) |action, index| {
        if (!validId(action.id) or !validText(action.title, 256)) return error.InvalidActionId;
        for (def.actions[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, action.id)) return error.DuplicateActionId;
        }
        switch (action.type) {
            .terminal => {
                if (action.params != .object) return error.InvalidTerminalAction;
                const binding = try string(try required(action.params, "action"));
                if (!validText(binding, max_text)) return error.InvalidTerminalAction;
                _ = try @import("../../input.zig").Binding.Action.parse(binding);
                if (field(action.params, "surface") != null) return error.StoredSurfaceNotAllowed;
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
                        if (field(arg, "context")) |context| {
                            const name = try string(context);
                            if (!std.mem.eql(u8, name, "workspace") and !std.mem.eql(u8, name, "cwd") and !std.mem.eql(u8, name, "surface")) return error.InvalidArgumentContext;
                        } else if (field(arg, "state")) |key| {
                            if (!validId(try string(key))) return error.InvalidStateKey;
                        } else {
                            const target = try string(try required(arg, "element"));
                            var found = false;
                            for (def.elements) |other| {
                                if (std.mem.eql(u8, target, other.id) and other.type != .button) found = true;
                            }
                            if (!found) return error.InvalidArgumentElement;
                        }
                    } else return error.InvalidArgument;
                }
            },
        }
    }
}
pub fn mergePatch(alloc: Allocator, target: Value, patch: Value, depth: usize) error{ OutOfMemory, PatchTooDeep }!Value {
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
pub fn discover(alloc: Allocator) ![]const u8 {
    const example =
        \\{"method":"extensions.install","params":{"persist":true,"scope":"app","definition":{"id":"hello","title":"Gizmo tools","panel":true,"actions":[{"id":"run","title":"Say hello","type":"workflow","context":"none","argv":["/usr/bin/printf","Hello %s\\n",{"element":"name"}]},{"id":"split","title":"Split caller","type":"terminal","context":"caller","params":{"action":"new_split:right"}}],"elements":[{"id":"name","type":"entry","label":"Name","text":"Gizmo"},{"id":"run_button","type":"button","label":"Run","action":"run"}]}}}
    ;
    const installation = (try std.json.parseFromSlice(Value, alloc, example, .{})).value;
    const headless =
        \\{"method":"extensions.install","params":{"scope":"workspace","workspace":"/absolute/project","persist":true,"state":{"message":"workspace A"},"definition":{"id":"project","title":"Project tools","actions":[{"id":"report","type":"workflow","context":"none","argv":["/usr/bin/printf","%s: %s\\n",{"context":"workspace"},{"state":"message"}]}]}}}
    ;
    return std.json.Stringify.valueAlloc(alloc, .{
        .version = 1,
        .methods = .{
            .@"extensions.list" = "{}",
            .@"extensions.install" = "{definition,scope?:app|workspace,workspace?:absolute-directory,persist?:bool,state?:object,visible?:bool=false}",
            .@"extensions.inspect" = "{id:string} | {job:integer}",
            .@"extensions.update" = "{id,definition?:object,patch?:object,state?:object,visible?:bool}",
            .@"extensions.remove" = "{id:string}",
            .@"extensions.invoke" = "{id,action,context?:{surface:string}} | {job,operation:cancel|forget}",
            .@"extensions.context" = "{id,action?:string,context?:{surface:string}}",
            .@"extensions.save" = "{id,scope?:app|workspace,workspace?:absolute-directory}",
            .@"extensions.load" = "{id,workspace?:absolute-directory}",
            .@"extensions.export" = "{id}",
        },
        .workspace_selection = "Only install/load select a workspace. Save/update reject scope or workspace switches before changes; load the desired workspace first. Loading a missing slot resets defaults, never carries another workspace's values.",
        .definition = "{id,title,actions?:Action[],elements?:Element[],panel?:bool=false}. Actions are independent from optional elements and appear in the real command palette unless palette:false. Buttons reference action IDs.",
        .action = "{id,title?:string,palette?:bool=true,type:terminal|workflow,context?:caller|focused|explicit|none=caller,params?:{action:binding},argv?:Argument[],cwd?:absolute,timeout_seconds?:1..3600}",
        .persistence = "Explicit persist:true or extensions.save writes $XDG_DATA_HOME/gizmo/extensions/catalog.json (fallback ~/.local/share/gizmo/extensions). A stable lock covers each full read-modify-write transaction; replacement is atomic, files 0600, new directories 0700. Definition and states are separate. Workspace keys are explicit canonical directory paths, never inferred from reports or cwd. Restart restores definitions inertly only after agent opt-in; workspace state requires extensions.load with its workspace. Native field edits require save; persistent API updates save automatically. Remove deletes all saved states. Live export returns an install-compatible definition/state/scope envelope.",
        .saved_cli = "gizmo extensions discover/list/install/update/remove/inspect/export default to saved data without a running app. Install persists inert definitions. Updates retain other workspace slots. Inspect/export describe saved definition, scope, and states without runtime jobs or visibility. Saved writes never update a running app; use --live explicitly. Invoke/context/save/load remain live.",
        .limits = .{ .extensions = max_panels, .elements = max_elements, .actions = max_elements, .retained_jobs = max_jobs, .output_bytes_per_stream = max_output, .store_bytes = store.max_bytes, .workspace_states_per_definition = 64 },
        .element_types = [_][]const u8{ "label", "entry", "button", "toggle", "selection" },
        .state = "Map element IDs to strings (entry/label), booleans (toggle), or zero-based selection indices. Headless keys accept string, boolean, integer, null. Updates and reads never invoke actions.",
        .patch = "JSON Merge Patch; arrays replace. Compatible state survives definition edits.",
        .terminal_context = "Definitions cannot contain surface IDs. API callers pass context.surface at invocation, or actions resolve caller/focused. Native panels capture their caller before presentation. Palette captures its selected terminal before taking focus. Explicit requires a runtime target; none permits app actions and terminal-independent workflows. Existing new_tab and new_split:right bindings create terminals.",
        .workflow = "Absolute executable with explicit argv only. Each argument is literal, {element:ID}, {state:key}, or {context:workspace|cwd|surface}; each substitutes exactly one argument. No shell interpolation. Status reports are inspection data, never triggers or authorization.",
        .jobs = "GIO asynchronous stdout/stderr and wait, bounded output, deadline and process-group cancellation. Inspect exposes exit_code, signal, reason, truncated, UTF-8 and base64 streams. Removal/shutdown cancels jobs. Forget releases retained output. Descendants creating another process group are not tracked.",
        .install_example = installation,
        .headless_example = (try std.json.parseFromSlice(Value, alloc, headless, .{})).value,
        .invoke_example = .{ .method = "extensions.invoke", .params = .{ .id = "hello", .action = "run" } },
        .terminal_example = .{ .method = "extensions.invoke", .params = .{ .id = "hello", .action = "split", .context = .{ .surface = "ID from tree" } } },
        .workspace_load_example = .{ .method = "extensions.load", .params = .{ .id = "project", .workspace = "/absolute/project" } },
    }, .{});
}

test "stored terminal targets are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const params = (try std.json.parseFromSlice(Value, arena.allocator(), "{\"surface\":\"9\",\"action\":\"new_tab\"}", .{})).value;
    try std.testing.expectError(error.StoredSurfaceNotAllowed, validate(.{
        .id = "target",
        .title = "Target",
        .actions = &.{.{ .id = "tab", .type = .terminal, .params = params }},
    }));
}

test "extension definitions reject automatic actions and invalid argv" {
    const testing = std.testing;
    try testing.expectError(error.ActionsRequireButton, validate(.{
        .id = "tools",
        .title = "Gizmo tools",
        .elements = &.{.{ .id = "input", .type = .entry, .action = "run" }},
    }));
    try testing.expectError(error.ExecutableMustBeAbsolute, validate(.{
        .id = "tools",
        .title = "Gizmo tools",
        .actions = &.{.{ .id = "run", .type = .workflow, .argv = &.{.{ .string = "printf" }} }},
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

test "state defaults and compatible edits share live restoration semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const def = Definition{
        .id = "tools",
        .title = "Tools",
        .elements = &.{
            .{ .id = "name", .type = .entry, .text = "default" },
            .{ .id = "flag", .type = .toggle, .active = true },
            .{ .id = "choice", .type = .selection, .options = &.{ "one", "two" }, .selected = 1 },
            .{ .id = "run", .type = .button, .action = "run" },
        },
        .actions = &.{.{ .id = "run", .type = .workflow, .argv = &.{.{ .string = "/usr/bin/true" }} }},
    };
    const previous = (try std.json.parseFromSlice(Value, alloc, "{\"name\":\"saved\",\"flag\":\"obsolete type\",\"choice\":9,\"data\":null}", .{})).value;
    const state = try compatibleState(alloc, def, previous);
    try std.testing.expectEqualStrings("saved", state.object.get("name").?.string);
    try std.testing.expect(state.object.get("flag").?.bool);
    try std.testing.expectEqual(@as(i64, 1), state.object.get("choice").?.integer);
    try std.testing.expect(state.object.get("run") == null);
    try std.testing.expect(state.object.get("data").? == .null);
    try std.testing.expectError(error.ButtonHasNoState, validateStateValue(def, "run", .{ .string = "never execute" }));
}

test "restored workspace slots migrate obsolete field types without changing saved data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entry = (try std.json.parseFromSlice(Value, alloc,
        \\{"states":[{"workspace":"/one","state":{"flag":"old entry text","message":"one"}},{"workspace":"/two","state":{"flag":false,"message":"two"}}]}
    , .{})).value;
    const def = Definition{ .id = "tools", .title = "Tools", .elements = &.{.{ .id = "flag", .type = .toggle, .active = true }} };
    const state = try restoredState(alloc, def, entry, "/one");
    try validateState(def, state);
    try std.testing.expect(state.object.get("flag").?.bool);
    try std.testing.expectEqualStrings("one", state.object.get("message").?.string);
    const slots = entry.object.get("states").?.array.items;
    try std.testing.expectEqualStrings("old entry text", slots[0].object.get("state").?.object.get("flag").?.string);
    try std.testing.expectEqualStrings("two", slots[1].object.get("state").?.object.get("message").?.string);
}

test "restored complete snapshots allow separate defined and custom state limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const elements = try alloc.alloc(Element, max_elements);
    for (elements, 0..) |*item, index| item.* = .{
        .id = try alloc.print("field{d}", .{index}),
        .type = .entry,
        .text = "default",
    };
    const def = Definition{ .id = "full", .title = "Full", .elements = elements };
    var saved = try defaultState(alloc, def);
    try saved.object.put(alloc, "custom", .{ .string = "saved" });
    const entry = try jsonValue(alloc, .{ .states = .{.{ .workspace = @as(?[]const u8, null), .state = saved }} });
    var restored = try restoredState(alloc, def, entry, null);
    try std.testing.expectEqual(@as(usize, max_elements + 1), restored.object.count());
    try validateState(def, restored);
    try std.testing.expectEqualStrings("saved", restored.object.get("custom").?.string);
    for (0..max_elements - 1) |index| try restored.object.put(alloc, try alloc.print("custom{d}", .{index}), .null);
    try validateState(def, restored);
    try std.testing.expectEqual(@as(usize, 2 * max_elements), restored.object.count());
    var custom_only = Value{ .object = .empty };
    for (0..max_elements + 1) |index| try custom_only.object.put(alloc, try alloc.print("custom{d}", .{index}), .null);
    try std.testing.expectError(error.TooManyStateKeys, validateState(def, custom_only));
}
