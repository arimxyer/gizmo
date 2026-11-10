//! A second presentation of Adw.TabView's pages, not a second tab model.
//! Binding the list to getPages() also handles transfers and reordering.
const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");
const ext = @import("ext.zig");
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const i18n = @import("../../os/main.zig").i18n;

const page_key = "gizmo-vertical-tab-page";

pub fn init(list: *gtk.ListBox, view: *adw.TabView) void {
    const pages = view.getPages();
    defer pages.unref();
    list.bindModel(pages.as(gio.ListModel), createRow, null, null);
    _ = gtk.ListBox.signals.row_selected.connect(list, *adw.TabView, rowSelected, view, .{});
    _ = gtk.ListBox.signals.row_activated.connect(list, *adw.TabView, rowActivated, view, .{});
    _ = gtk.SelectionModel.signals.selection_changed.connect(pages, *gtk.ListBox, selectionChanged, list, .{ .after = true });
    _ = gio.ListModel.signals.items_changed.connect(pages.as(gio.ListModel), *gtk.ListBox, itemsChanged, list, .{ .after = true });
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
    // selected-page can notify before the list model publishes an insertion.
    // Never let an old row at the new index change TabView's selection.
    if (row.as(gobject.Object).getData(page_key) != @as(*anyopaque, @ptrCast(page))) return;
    if (list.getSelectedRow() != row) list.selectRow(row);
}

fn selectionChanged(_: *gtk.SelectionModel, _: c_uint, _: c_uint, list: *gtk.ListBox) callconv(.c) void {
    const window = ext.getAncestor(Window, list.as(gtk.Widget)) orelse return;
    syncSelection(list, window.getTabView());
}

fn itemsChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, list: *gtk.ListBox) callconv(.c) void {
    const window = ext.getAncestor(Window, list.as(gtk.Widget)) orelse return;
    syncSelection(list, window.getTabView());
}

fn rowSelected(_: *gtk.ListBox, row_: ?*gtk.ListBoxRow, view: *adw.TabView) callconv(.c) void {
    const row = row_ orelse return;
    const page: *adw.TabPage = @ptrCast(@alignCast(row.as(gobject.Object).getData(page_key) orelse return));
    if (view.getPagePosition(page) < 0) return;
    if (view.getSelectedPage() != page) view.setSelectedPage(page);
}

fn releasePage(data: ?*anyopaque) callconv(.c) void {
    const page: *adw.TabPage = @ptrCast(@alignCast(data orelse return));
    page.unref();
}

fn rowActivated(_: *gtk.ListBox, _: *gtk.ListBoxRow, view: *adw.TabView) callconv(.c) void {
    const page = view.getSelectedPage() orelse return;
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
    const surface = tab.getActiveSurface() orelse return;
    surface.grabFocus();
}

fn createRow(item: *gobject.Object, _: ?*anyopaque) callconv(.c) *gtk.Widget {
    const page = gobject.ext.cast(adw.TabPage, item).?;
    const row = gtk.ListBoxRow.new();
    // Button closures use this reference until the row and its children die.
    page.ref();
    row.as(gobject.Object).setDataFull(page_key, page, releasePage);
    const content = gtk.Box.new(.vertical, 2);
    content.as(gtk.Widget).setMarginTop(6);
    content.as(gtk.Widget).setMarginBottom(6);
    content.as(gtk.Widget).setMarginStart(6);
    content.as(gtk.Widget).setMarginEnd(6);
    const heading = gtk.Box.new(.horizontal, 4);
    const label = gtk.Label.new(null);
    label.setXalign(0);
    label.setEllipsize(.end);
    label.setMaxWidthChars(24);
    label.as(gtk.Widget).setHexpand(1);
    _ = page.as(gobject.Object).bindProperty("title", label.as(gobject.Object), "label", .{ .sync_create = true });
    _ = page.as(gobject.Object).bindProperty("tooltip", label.as(gobject.Object), "tooltip-text", .{ .sync_create = true });
    heading.append(label.as(gtk.Widget));
    heading.append(button("window-close-symbolic", i18n._("Close Tab"), close, page).as(gtk.Widget));
    content.append(heading.as(gtk.Widget));
    const controls = gtk.Box.new(.horizontal, 2);
    controls.append(button("go-up-symbolic", i18n._("Move Tab Up"), moveUp, page).as(gtk.Widget));
    controls.append(button("go-down-symbolic", i18n._("Move Tab Down"), moveDown, page).as(gtk.Widget));
    controls.append(button("document-edit-symbolic", i18n._("Change Tab Title"), rename, page).as(gtk.Widget));
    controls.append(button("window-new-symbolic", i18n._("Move Tab to New Window"), detach, page).as(gtk.Widget));
    content.append(controls.as(gtk.Widget));
    row.setChild(content.as(gtk.Widget));
    return row.as(gtk.Widget);
}

fn button(icon: [*:0]const u8, label: [*:0]const u8, callback: *const fn (*gtk.Button, *adw.TabPage) callconv(.c) void, page: *adw.TabPage) *gtk.Button {
    const result = gtk.Button.newFromIconName(icon);
    result.as(gtk.Widget).addCssClass("flat");
    result.as(gtk.Widget).setTooltipText(label);
    result.as(gtk.Accessible).updateProperty(.label, label, @as(c_int, -1));
    _ = gtk.Button.signals.clicked.connect(result, *adw.TabPage, callback, page, .{});
    return result;
}

fn viewFor(button_: *gtk.Button, page: *adw.TabPage) ?*adw.TabView {
    const window = ext.getAncestor(Window, button_.as(gtk.Widget)) orelse return null;
    const view = window.getTabView();
    return if (view.getPagePosition(page) >= 0) view else null;
}

fn close(button_: *gtk.Button, page: *adw.TabPage) callconv(.c) void {
    const view = viewFor(button_, page) orelse return;
    view.closePage(page);
}

fn moveUp(button_: *gtk.Button, page: *adw.TabPage) callconv(.c) void {
    const view = viewFor(button_, page) orelse return;
    const position = view.getPagePosition(page);
    if (position > 0) _ = view.reorderPage(page, position - 1);
}

fn moveDown(button_: *gtk.Button, page: *adw.TabPage) callconv(.c) void {
    const view = viewFor(button_, page) orelse return;
    const position = view.getPagePosition(page);
    if (position + 1 < view.getNPages()) _ = view.reorderPage(page, position + 1);
}

fn rename(button_: *gtk.Button, page: *adw.TabPage) callconv(.c) void {
    _ = viewFor(button_, page) orelse return;
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
    tab.promptTabTitle();
}

fn detach(button_: *gtk.Button, page: *adw.TabPage) callconv(.c) void {
    const view = viewFor(button_, page) orelse return;
    view.setSelectedPage(page);
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
    const surface = tab.getActiveSurface() orelse return;
    const window = ext.getAncestor(Window, button_.as(gtk.Widget)) orelse return;
    _ = window.moveTabToNewWindow(surface);
}
