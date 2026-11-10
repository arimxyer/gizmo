//! A presentation of Adw.TabView's pages, never a second tab model.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const ext = @import("ext.zig");
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const i18n = @import("../../os/main.zig").i18n;

const page_key = "gizmo-vertical-tab-page";
const index_key = "gizmo-tab-index";
const status_key = "gizmo-tab-status";

pub fn init(list: *gtk.ListBox, view: *adw.TabView, window: *Window) void {
    const pages = view.getPages();
    defer pages.unref();
    list.bindModel(pages.as(gio.ListModel), createRow, window, null);
    _ = gtk.ListBox.signals.row_selected.connect(list, *adw.TabView, rowSelected, view, .{});
    _ = gtk.ListBox.signals.row_activated.connect(list, *adw.TabView, rowActivated, view, .{});
    _ = gtk.SelectionModel.signals.selection_changed.connect(pages, *gtk.ListBox, selectionChanged, list, .{ .after = true });
    _ = gio.ListModel.signals.items_changed.connect(pages.as(gio.ListModel), *gtk.ListBox, itemsChanged, list, .{ .after = true });
    const keys = gtk.EventControllerKey.new();
    keys.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *gtk.ListBox, keyPressed, list, .{});
    list.as(gtk.Widget).addController(keys.as(gtk.EventController));
    // A list-level target also accepts drops after the last row and into empty windows.
    const drop = gtk.DropTarget.new(adw.TabPage.getGObjectType(), .{ .move = true });
    _ = gtk.DropTarget.signals.drop.connect(drop, *gtk.ListBox, dropped, list, .{});
    list.as(gtk.Widget).addController(drop.as(gtk.EventController));
    refreshIndices(list);
    syncSelection(list, view);
}

pub fn deinit(list: *gtk.ListBox, view: *adw.TabView) void {
    const pages = view.getPages();
    defer pages.unref();
    _ = gobject.signalHandlersDisconnectMatched(pages.as(gobject.Object), .{ .data = true }, 0, 0, null, null, list);
    _ = gobject.signalHandlersDisconnectMatched(list.as(gobject.Object), .{ .data = true }, 0, 0, null, null, view);
    list.bindModel(null, null, null, null);
}

pub fn syncSelection(list: *gtk.ListBox, view: *adw.TabView) void {
    const page = view.getSelectedPage() orelse {
        list.selectRow(null);
        return;
    };
    const row = list.getRowAtIndex(view.getPagePosition(page)) orelse return;
    // Notifications can precede the model insertion, reorder, or transfer.
    if (pageFor(row) != page) return;
    if (list.getSelectedRow() != row) list.selectRow(row);
}

pub fn focus(list: *gtk.ListBox) void {
    const row = list.getSelectedRow() orelse list.getRowAtIndex(0) orelse return;
    _ = row.as(gtk.Widget).grabFocus();
}

fn pageFor(row: *gtk.ListBoxRow) ?*adw.TabPage {
    return @ptrCast(@alignCast(row.as(gobject.Object).getData(page_key) orelse return null));
}

fn selectionChanged(_: *gtk.SelectionModel, _: c_uint, _: c_uint, list: *gtk.ListBox) callconv(.c) void {
    const window = ext.getAncestor(Window, list.as(gtk.Widget)) orelse return;
    syncSelection(list, window.getTabView());
}

fn itemsChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, list: *gtk.ListBox) callconv(.c) void {
    const window = ext.getAncestor(Window, list.as(gtk.Widget)) orelse return;
    refreshIndices(list);
    syncSelection(list, window.getTabView());
}

fn refreshIndices(list: *gtk.ListBox) void {
    var i: c_int = 0;
    while (list.getRowAtIndex(i)) |row| : (i += 1) {
        const label: *gtk.Label = @ptrCast(@alignCast(row.as(gobject.Object).getData(index_key) orelse continue));
        var buf: [16]u8 = undefined;
        const text = std.mem.printSentinel(&buf, "{d}", .{i + 1}, 0) catch unreachable;
        label.setLabel(text);
    }
}

fn rowSelected(_: *gtk.ListBox, row_: ?*gtk.ListBoxRow, view: *adw.TabView) callconv(.c) void {
    const row = row_ orelse return;
    const page = pageFor(row) orelse return;
    // Ignore transient rows while bindModel is rebuilding a changed range.
    if (view.getPagePosition(page) != row.getIndex()) return;
    if (view.getSelectedPage() != page) view.setSelectedPage(page);
}

fn releasePage(data: ?*anyopaque) callconv(.c) void {
    const page: *adw.TabPage = @ptrCast(@alignCast(data orelse return));
    page.unref();
}

fn rowActivated(_: *gtk.ListBox, _: *gtk.ListBoxRow, view: *adw.TabView) callconv(.c) void {
    focusTerminal(view);
}

fn focusTerminal(view: *adw.TabView) void {
    const page = view.getSelectedPage() orelse return;
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
    const surface = tab.getActiveSurface() orelse return;
    surface.grabFocus();
}

fn createRow(item: *gobject.Object, data: ?*anyopaque) callconv(.c) *gtk.Widget {
    const window: *Window = @ptrCast(@alignCast(data.?));
    const page = gobject.ext.cast(adw.TabPage, item).?;
    const row = gtk.ListBoxRow.new();
    page.ref();
    row.as(gobject.Object).setDataFull(page_key, page, releasePage);
    row.as(gtk.Widget).addCssClass("gizmo-tab-row");
    _ = page.as(gobject.Object).bindProperty("tooltip", row.as(gobject.Object), "tooltip-text", .{ .sync_create = true });

    const content = gtk.Box.new(.horizontal, 4);
    const badge = gtk.Overlay.new();
    badge.as(gtk.Widget).setSizeRequest(28, 28);
    const index = gtk.Label.new(null);
    index.as(gtk.Widget).addCssClass("gizmo-tab-index");
    row.as(gobject.Object).setData(index_key, index);
    badge.setChild(index.as(gtk.Widget));
    const status = gtk.Image.new();
    status.setPixelSize(10);
    status.as(gtk.Widget).setHalign(.end);
    status.as(gtk.Widget).setValign(.end);
    status.as(gtk.Widget).addCssClass("gizmo-tab-status");
    row.as(gobject.Object).setData(status_key, status);
    badge.addOverlay(status.as(gtk.Widget));
    const compact_close = gtk.Button.new();
    compact_close.as(gtk.Widget).addCssClass("flat");
    compact_close.as(gtk.Widget).addCssClass("gizmo-tab-close");
    compact_close.as(gtk.Widget).addCssClass("gizmo-tab-close-compact");
    compact_close.as(gtk.Widget).setHalign(.end);
    compact_close.as(gtk.Widget).setValign(.start);
    compact_close.as(gtk.Widget).setTooltipText(i18n._("Close Tab"));
    compact_close.as(gtk.Accessible).updateProperty(.label, i18n._("Close Tab"), @as(c_int, -1));
    const close_icon = gtk.Image.newFromIconName("window-close-symbolic");
    close_icon.setPixelSize(8);
    compact_close.setChild(close_icon.as(gtk.Widget));
    _ = window.as(gobject.Object).bindProperty("sidebar-expanded", compact_close.as(gobject.Object), "visible", .{ .sync_create = true, .invert_boolean = true });
    _ = gtk.Button.signals.clicked.connect(compact_close, *gtk.ListBoxRow, closeClicked, row, .{});
    badge.addOverlay(compact_close.as(gtk.Widget));
    content.append(badge.as(gtk.Widget));

    const label = gtk.Label.new(null);
    label.setXalign(0);
    label.setEllipsize(.middle);
    label.setSingleLineMode(1);
    label.setWidthChars(1);
    label.setMaxWidthChars(16);
    label.as(gtk.Widget).setHexpand(1);
    _ = page.as(gobject.Object).bindProperty("title", label.as(gobject.Object), "label", .{ .sync_create = true });
    _ = window.as(gobject.Object).bindProperty("sidebar-expanded", label.as(gobject.Object), "visible", .{ .sync_create = true });
    content.append(label.as(gtk.Widget));

    const close = gtk.Button.newFromIconName("window-close-symbolic");
    close.as(gtk.Widget).addCssClass("flat");
    close.as(gtk.Widget).addCssClass("gizmo-tab-close");
    close.as(gtk.Widget).setTooltipText(i18n._("Close Tab"));
    close.as(gtk.Accessible).updateProperty(.label, i18n._("Close Tab"), @as(c_int, -1));
    _ = window.as(gobject.Object).bindProperty("sidebar-expanded", close.as(gobject.Object), "visible", .{ .sync_create = true });
    _ = gtk.Button.signals.clicked.connect(close, *gtk.ListBoxRow, closeClicked, row, .{});
    content.append(close.as(gtk.Widget));
    row.setChild(content.as(gtk.Widget));

    // Object-bound callbacks disconnect automatically when the row dies.
    _ = gobject.signalConnectObject(page.as(gobject.TypeInstance), "notify::needs-attention", @ptrCast(&updateStatus), row.as(gobject.Object), .{});
    const tab = gobject.ext.cast(Tab, page.getChild()).?;
    _ = gobject.signalConnectObject(tab.as(gobject.TypeInstance), "notify::program-status", @ptrCast(&updateStatus), row.as(gobject.Object), .{});
    _ = gobject.signalConnectObject(tab.as(gobject.TypeInstance), "notify::program-status-message", @ptrCast(&updateStatus), row.as(gobject.Object), .{});
    updateStatus(tab.as(gobject.Object), null, row);

    const click = gtk.GestureClick.new();
    click.as(gtk.GestureSingle).setButton(0);
    _ = gtk.GestureClick.signals.pressed.connect(click, *gtk.ListBoxRow, clicked, row, .{});
    row.as(gtk.Widget).addController(click.as(gtk.EventController));
    const drag = gtk.DragSource.new();
    drag.setActions(.{ .move = true });
    _ = gtk.DragSource.signals.prepare.connect(drag, *gtk.ListBoxRow, dragPrepare, row, .{});
    row.as(gtk.Widget).addController(drag.as(gtk.EventController));
    return row.as(gtk.Widget);
}

fn updateStatus(_: *gobject.Object, _: ?*gobject.ParamSpec, row: *gtk.ListBoxRow) callconv(.c) void {
    const page = pageFor(row) orelse return;
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
    const image: *gtk.Image = @ptrCast(@alignCast(row.as(gobject.Object).getData(status_key).?));
    var value = gobject.ext.Value.new(?[*:0]const u8);
    defer value.unset();
    tab.as(gobject.Object).getProperty("program-status", &value);
    const state = std.mem.span(value.getString() orelse "none");
    const icon: ?[*:0]const u8 = if (std.mem.eql(u8, state, "blocked")) "dialog-warning-symbolic" else if (std.mem.eql(u8, state, "error")) "dialog-error-symbolic" else if (std.mem.eql(u8, state, "done")) "emblem-ok-symbolic" else if (std.mem.eql(u8, state, "working")) "content-loading-symbolic" else if (std.mem.eql(u8, state, "idle")) "media-playback-pause-symbolic" else if (page.getNeedsAttention() != 0) "dialog-information-symbolic" else null;
    image.setFromIconName(icon);
    image.as(gtk.Widget).setVisible(@intFromBool(icon != null));
    inline for (.{ "blocked", "error", "done", "working", "idle" }) |name| {
        if (std.mem.eql(u8, state, name)) image.as(gtk.Widget).addCssClass(name) else image.as(gtk.Widget).removeCssClass(name);
    }
    if (page.getNeedsAttention() != 0) row.as(gtk.Widget).addCssClass("needs-attention") else row.as(gtk.Widget).removeCssClass("needs-attention");
    var message = gobject.ext.Value.new(?[*:0]const u8);
    defer message.unset();
    tab.as(gobject.Object).getProperty("program-status-message", &message);
    const status_text = value.getString() orelse "none";
    const message_text = message.getString() orelse "";
    image.as(gtk.Widget).setTooltipText(if (message_text[0] != 0) message_text else status_text);
    image.as(gtk.Accessible).updateProperty(.label, status_text, @as(c_int, -1));
}

fn closeClicked(_: *gtk.Button, row: *gtk.ListBoxRow) callconv(.c) void {
    const window = ext.getAncestor(Window, row.as(gtk.Widget)) orelse return;
    operate(window, pageFor(row) orelse return, "close");
}

fn clicked(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, row: *gtk.ListBoxRow) callconv(.c) void {
    switch (gesture.as(gtk.GestureSingle).getCurrentButton()) {
        2 => {
            _ = gesture.as(gtk.Gesture).setState(.claimed);
            const window = ext.getAncestor(Window, row.as(gtk.Widget)) orelse return;
            operate(window, pageFor(row) orelse return, "close");
        },
        3 => {
            _ = gesture.as(gtk.Gesture).setState(.claimed);
            showMenu(row);
        },
        else => {},
    }
}

fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, mods: gdk.ModifierType, list: *gtk.ListBox) callconv(.c) c_int {
    const window = ext.getAncestor(Window, list.as(gtk.Widget)) orelse return 0;
    // Capture only row shortcuts; buttons and popover items own their keys.
    const focused = window.as(gtk.Window).getFocus() orelse return 0;
    const row = gobject.ext.cast(gtk.ListBoxRow, focused) orelse return 0;
    if (row.as(gtk.Widget).getParent() != list.as(gtk.Widget)) return 0;
    const view = window.getTabView();
    const page = pageFor(row) orelse return 0;
    switch (key) {
        gdk.KEY_Return, gdk.KEY_KP_Enter, gdk.KEY_Escape => {
            if (key == gdk.KEY_Escape and window.getSidebarExpanded()) window.setSidebarState(.compact);
            focusTerminal(view);
        },
        gdk.KEY_Menu => showMenu(row),
        gdk.KEY_F10 => {
            if (!mods.shift_mask) return 0;
            showMenu(row);
        },
        gdk.KEY_F2 => operate(window, page, "rename"),
        gdk.KEY_Delete, gdk.KEY_KP_Delete => operate(window, page, "close"),
        // Let GtkListBox handle arrows, Home, End, and focus/selection natively.
        else => return 0,
    }
    return 1;
}

pub fn operate(window: *Window, page: *adw.TabPage, operation: []const u8) void {
    const view = window.getTabView();
    const position = view.getPagePosition(page);
    if (position < 0) return;
    // Reorder/transfer/close can synchronously destroy the originating row.
    page.ref();
    defer page.unref();
    view.ref();
    defer view.unref();
    if (std.mem.eql(u8, operation, "close")) {
        view.closePage(page);
    } else if (std.mem.eql(u8, operation, "close-other")) {
        view.closeOtherPages(page);
    } else if (std.mem.eql(u8, operation, "up")) {
        if (position > 0) _ = view.reorderPage(page, position - 1);
    } else if (std.mem.eql(u8, operation, "down")) {
        if (position + 1 < view.getNPages()) _ = view.reorderPage(page, position + 1);
    } else if (std.mem.eql(u8, operation, "rename")) {
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
        tab.promptTabTitle();
    } else if (std.mem.eql(u8, operation, "detach")) {
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
        const surface = tab.getActiveSurface() orelse return;
        _ = window.moveTabToNewWindow(surface);
    }
}

fn showMenu(row: *gtk.ListBoxRow) void {
    const page = pageFor(row) orelse return;
    const menu = gio.Menu.new();
    defer menu.unref();
    const group = gio.SimpleActionGroup.new();
    defer group.unref();
    const popover = gtk.PopoverMenu.newFromModel(menu.as(gio.MenuModel));
    inline for (.{ "rename", "up", "down", "detach", "close", "close-other" }) |name| {
        const label = if (comptime std.mem.eql(u8, name, "rename")) i18n._("Change Tab Title…") else if (comptime std.mem.eql(u8, name, "up")) i18n._("Move Tab Up") else if (comptime std.mem.eql(u8, name, "down")) i18n._("Move Tab Down") else if (comptime std.mem.eql(u8, name, "detach")) i18n._("Move Tab to New Window") else if (comptime std.mem.eql(u8, name, "close")) i18n._("Close Tab") else i18n._("Close Other Tabs");
        const action = gio.SimpleAction.new(name, null);
        defer action.unref();
        // The menu closes before activation. Keep the page alive on the action,
        // independent of the popover's parent and lifetime.
        page.ref();
        action.as(gobject.Object).setDataFull(page_key, page, releasePage);
        _ = gio.SimpleAction.signals.activate.connect(action, *adw.TabPage, menuAction, page, .{});
        group.as(gio.ActionMap).addAction(action.as(gio.Action));
        menu.append(label, "tab." ++ name);
    }
    popover.as(gtk.Widget).insertActionGroup("tab", group.as(gio.ActionGroup));
    popover.as(gtk.Widget).setParent(row.as(gtk.Widget));
    _ = gtk.Popover.signals.closed.connect(popover.as(gtk.Popover), ?*anyopaque, menuClosed, null, .{});
    // Removing a row during reorder/transfer must close and unparent its menu.
    _ = gobject.signalConnectObject(row.as(gobject.TypeInstance), "unmap", @ptrCast(&rowUnmapped), popover.as(gobject.Object), .{});
    popover.as(gtk.Popover).popup();
}

fn menuAction(action: *gio.SimpleAction, _: ?*glib.Variant, page: *adw.TabPage) callconv(.c) void {
    const window = ext.getAncestor(Window, page.getChild()) orelse return;
    operate(window, page, std.mem.span(action.as(gio.Action).getName()));
}

fn rowUnmapped(_: *gtk.Widget, popover: *gtk.PopoverMenu) callconv(.c) void {
    popover.ref();
    defer popover.unref();
    popover.as(gtk.Popover).popdown();
    if (popover.as(gtk.Widget).getParent() != null) popover.as(gtk.Widget).unparent();
}

fn menuClosed(popover: *gtk.Popover, _: ?*anyopaque) callconv(.c) void {
    // Model buttons close the popover before activating its action group.
    // Keep that group attached until activation has finished.
    popover.ref();
    _ = glib.idleAdd(menuClosedIdle, popover);
}

fn menuClosedIdle(data: ?*anyopaque) callconv(.c) c_int {
    const popover: *gtk.Popover = @ptrCast(@alignCast(data orelse return 0));
    defer popover.unref();
    if (popover.as(gtk.Widget).getParent() != null) popover.as(gtk.Widget).unparent();
    return 0;
}

fn dragPrepare(_: *gtk.DragSource, _: f64, _: f64, row: *gtk.ListBoxRow) callconv(.c) ?*gdk.ContentProvider {
    const page = pageFor(row) orelse return null;
    var value = gobject.ext.Value.newFrom(page);
    defer value.unset();
    return gdk.ContentProvider.newForValue(&value);
}

fn dropped(_: *gtk.DropTarget, value: *gobject.Value, _: f64, y: f64, list: *gtk.ListBox) callconv(.c) c_int {
    const page = gobject.ext.Value.get(value, ?*adw.TabPage) orelse return 0;
    const source = ext.getAncestor(adw.TabView, page.getChild()) orelse return 0;
    const window = ext.getAncestor(Window, list.as(gtk.Widget)) orelse return 0;
    const target = window.getTabView();
    var position = target.getNPages();
    if (list.getRowAtY(@intFromFloat(y))) |row| {
        position = row.getIndex();
        var allocation: gtk.Allocation = undefined;
        row.as(gtk.Widget).getAllocation(&allocation);
        if (y >= @as(f64, @floatFromInt(allocation.f_y)) + @as(f64, @floatFromInt(allocation.f_height)) / 2) position += 1;
    }
    // Keep both views and the page alive across model and window callbacks.
    source.ref();
    defer source.unref();
    target.ref();
    defer target.unref();
    page.ref();
    defer page.unref();
    if (source == target) {
        _ = target.reorderPage(page, reorderPosition(position, source.getPagePosition(page), target.getNPages()));
    } else {
        source.transferPage(page, target, position);
        target.setSelectedPage(page);
    }
    return 1;
}

/// Convert an insertion slot to an index after removing the source page.
fn reorderPosition(slot: c_int, old: c_int, count: c_int) c_int {
    return @min(if (slot > old) slot - 1 else slot, count - 1);
}

test "sidebar drop slots preserve adjacent and endpoint positions" {
    const testing = std.testing;
    try testing.expectEqual(@as(c_int, 0), reorderPosition(0, 2, 4));
    try testing.expectEqual(@as(c_int, 3), reorderPosition(4, 0, 4));
    try testing.expectEqual(@as(c_int, 2), reorderPosition(2, 2, 4));
    try testing.expectEqual(@as(c_int, 2), reorderPosition(3, 2, 4));
    try testing.expectEqual(@as(c_int, 0), reorderPosition(1, 0, 1));
}
