// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! A StatusNotifierItem served on the session bus, which waybar's tray
//! module (and any other StatusNotifierHost) displays.
const std = @import("std");
const c = @import("c");
const dbus = @import("dbus.zig");

const log = std.log.scoped(.sni);
const Allocator = std.mem.Allocator;

const item_iface = "org.kde.StatusNotifierItem";
const item_path = "/StatusNotifierItem";
const watcher_name = "org.kde.StatusNotifierWatcher";
const watcher_path = "/StatusNotifierWatcher";

const introspection =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\  <interface name="org.freedesktop.DBus.Introspectable">
    \\    <method name="Introspect"><arg name="data" type="s" direction="out"/></method>
    \\  </interface>
    \\  <interface name="org.freedesktop.DBus.Properties">
    \\    <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
    \\    <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
    \\    <method name="Set"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/></method>
    \\  </interface>
    \\  <interface name="org.kde.StatusNotifierItem">
    \\    <property name="Category" type="s" access="read"/>
    \\    <property name="Id" type="s" access="read"/>
    \\    <property name="Title" type="s" access="read"/>
    \\    <property name="Status" type="s" access="read"/>
    \\    <property name="WindowId" type="i" access="read"/>
    \\    <property name="IconThemePath" type="s" access="read"/>
    \\    <property name="IconName" type="s" access="read"/>
    \\    <property name="IconPixmap" type="a(iiay)" access="read"/>
    \\    <property name="OverlayIconName" type="s" access="read"/>
    \\    <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    \\    <property name="AttentionIconName" type="s" access="read"/>
    \\    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    \\    <property name="AttentionMovieName" type="s" access="read"/>
    \\    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    \\    <property name="ItemIsMenu" type="b" access="read"/>
    \\    <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\    <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\    <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\    <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
    \\    <method name="ProvideXdgActivationToken"><arg name="token" type="s" direction="in"/></method>
    \\    <signal name="NewTitle"/>
    \\    <signal name="NewIcon"/>
    \\    <signal name="NewAttentionIcon"/>
    \\    <signal name="NewOverlayIcon"/>
    \\    <signal name="NewToolTip"/>
    \\    <signal name="NewStatus"><arg name="status" type="s"/></signal>
    \\  </interface>
    \\</node>
    \\
;

pub const Pixmap = struct {
    size: u32,
    /// ARGB32, network byte order, `size * size * 4` bytes.
    data: []u8,
};

pub const ActivateFn = *const fn (?*anyopaque) void;

pub const Item = struct {
    gpa: Allocator,
    conn: dbus.Connection,
    bus_name: [:0]u8,
    pixmaps: []Pixmap = &.{},
    tooltip_title: [:0]u8,
    tooltip_text: [:0]u8,
    registered: bool = false,
    on_activate: ActivateFn,
    on_activate_ctx: ?*anyopaque,
    /// Called on ContextMenu (right click). Optional.
    on_context_menu: ?ActivateFn = null,

    const vtable: c.DBusObjectPathVTable = .{
        .unregister_function = null,
        .message_function = handleMessage,
    };

    pub fn init(self: *Item, gpa: Allocator, conn: dbus.Connection, on_activate: ActivateFn, ctx: ?*anyopaque) !void {
        const pid = c.getpid();
        self.* = .{
            .gpa = gpa,
            .conn = conn,
            .bus_name = try std.fmt.allocPrintSentinel(gpa, "org.kde.StatusNotifierItem-{d}-1", .{pid}, 0),
            .tooltip_title = try gpa.dupeSentinel(u8, "Wi-Fi", 0),
            .tooltip_text = try gpa.dupeSentinel(u8, "", 0),
            .on_activate = on_activate,
            .on_activate_ctx = ctx,
        };
        errdefer gpa.free(self.bus_name);
        try conn.requestName(self.bus_name);
        try conn.registerObject(item_path, &vtable, self);
        // Re-register whenever a StatusNotifierWatcher (i.e. the bar) (re)starts.
        try conn.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ watcher_name ++ "'");
        try conn.addFilter(filter, self);
        self.register();
    }

    pub fn deinit(self: *Item) void {
        self.freePixmaps();
        self.gpa.free(self.bus_name);
        self.gpa.free(self.tooltip_title);
        self.gpa.free(self.tooltip_text);
    }

    fn register(self: *Item) void {
        const msg = dbus.Message.methodCall(watcher_name, watcher_path, watcher_name, "RegisterStatusNotifierItem") catch return;
        var w = msg.writer();
        w.string(self.bus_name);
        if (self.conn.call(msg, 5000)) |reply| {
            reply.deinit();
            self.registered = true;
            log.info("registered {s} with the StatusNotifierWatcher", .{self.bus_name});
        } else |_| {
            self.registered = false;
            log.info("no StatusNotifierWatcher available yet; will register when one appears", .{});
        }
    }

    fn filter(_: ?*c.DBusConnection, msg_opt: ?*c.DBusMessage, data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
        const self: *Item = @ptrCast(@alignCast(data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
        const msg = msg_opt orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        if (c.dbus_message_is_signal(msg, "org.freedesktop.DBus", "NameOwnerChanged") != 0) {
            var r = dbus.Reader.init(msg);
            const name = r.string() catch return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
            _ = r.next();
            _ = r.next();
            const new_owner = r.string() catch return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
            if (std.mem.eql(u8, name, watcher_name)) {
                if (new_owner.len > 0) {
                    log.info("StatusNotifierWatcher appeared ({s})", .{new_owner});
                    self.register();
                } else {
                    self.registered = false;
                }
            }
        }
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    fn freePixmaps(self: *Item) void {
        for (self.pixmaps) |p| self.gpa.free(p.data);
        self.gpa.free(self.pixmaps);
        self.pixmaps = &.{};
    }

    /// Takes ownership of `pixmaps` and their data.
    pub fn setIcon(self: *Item, pixmaps: []Pixmap) void {
        self.freePixmaps();
        self.pixmaps = pixmaps;
        self.emit("NewIcon");
    }

    pub fn setTooltip(self: *Item, title: []const u8, text: []const u8) !void {
        if (std.mem.eql(u8, self.tooltip_title, title) and std.mem.eql(u8, self.tooltip_text, text)) return;
        const new_title = try self.gpa.dupeSentinel(u8, title, 0);
        errdefer self.gpa.free(new_title);
        const new_text = try self.gpa.dupeSentinel(u8, text, 0);
        self.gpa.free(self.tooltip_title);
        self.gpa.free(self.tooltip_text);
        self.tooltip_title = new_title;
        self.tooltip_text = new_text;
        self.emit("NewToolTip");
    }

    fn emit(self: *Item, member: [*:0]const u8) void {
        const msg = dbus.Message.signal(item_path, item_iface, member) catch return;
        self.conn.send(msg);
    }

    // ---- object implementation ------------------------------------------

    fn handleMessage(_: ?*c.DBusConnection, msg_opt: ?*c.DBusMessage, data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
        const self: *Item = @ptrCast(@alignCast(data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
        const msg = msg_opt orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        if (c.dbus_message_get_type(msg) != c.DBUS_MESSAGE_TYPE_METHOD_CALL) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        return self.handleCall(msg) catch |err| {
            log.warn("while handling a method call: {t}", .{err});
            return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        };
    }

    fn handleCall(self: *Item, msg: *c.DBusMessage) !c.DBusHandlerResult {
        const iface: []const u8 = if (c.dbus_message_get_interface(msg)) |i| std.mem.span(i) else item_iface;
        const member = std.mem.span(c.dbus_message_get_member(msg) orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED);

        if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Introspectable") and std.mem.eql(u8, member, "Introspect")) {
            const reply = try dbus.Message.methodReturn(msg);
            var w = reply.writer();
            w.string(introspection);
            self.conn.send(reply);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }

        if (std.mem.eql(u8, iface, dbus.properties_iface)) {
            var r = dbus.Reader.init(msg);
            const target = r.string() catch "";
            if (!std.mem.eql(u8, target, item_iface)) {
                self.conn.send(try dbus.Message.errorReply(msg, "org.freedesktop.DBus.Error.UnknownInterface", "No such interface"));
                return c.DBUS_HANDLER_RESULT_HANDLED;
            }
            if (std.mem.eql(u8, member, "Get")) {
                _ = r.next();
                const name = r.string() catch "";
                const reply = try dbus.Message.methodReturn(msg);
                var w = reply.writer();
                if (!self.writeProperty(&w, name)) {
                    c.dbus_message_unref(reply.raw);
                    self.conn.send(try dbus.Message.errorReply(msg, "org.freedesktop.DBus.Error.UnknownProperty", "No such property"));
                    return c.DBUS_HANDLER_RESULT_HANDLED;
                }
                self.conn.send(reply);
                return c.DBUS_HANDLER_RESULT_HANDLED;
            }
            if (std.mem.eql(u8, member, "GetAll")) {
                const reply = try dbus.Message.methodReturn(msg);
                var w = reply.writer();
                var dict = w.open(c.DBUS_TYPE_ARRAY, "{sv}");
                for (property_names) |name| {
                    var entry = dict.open(c.DBUS_TYPE_DICT_ENTRY, null);
                    entry.string(name);
                    _ = self.writeProperty(&entry, name);
                    dict.close(&entry);
                }
                w.close(&dict);
                self.conn.send(reply);
                return c.DBUS_HANDLER_RESULT_HANDLED;
            }
            if (std.mem.eql(u8, member, "Set")) {
                self.conn.send(try dbus.Message.errorReply(msg, "org.freedesktop.DBus.Error.PropertyReadOnly", "Properties are read-only"));
                return c.DBUS_HANDLER_RESULT_HANDLED;
            }
            return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        }

        if (std.mem.eql(u8, iface, item_iface)) {
            const activates = std.mem.eql(u8, member, "Activate") or std.mem.eql(u8, member, "SecondaryActivate");
            const context_menu = std.mem.eql(u8, member, "ContextMenu");
            const known = activates or context_menu or std.mem.eql(u8, member, "Scroll") or std.mem.eql(u8, member, "ProvideXdgActivationToken");
            if (!known) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
            if (c.dbus_message_get_no_reply(msg) == 0) self.conn.send(try dbus.Message.methodReturn(msg));
            if (activates) self.on_activate(self.on_activate_ctx);
            if (context_menu) {
                if (self.on_context_menu) |cb| cb(self.on_activate_ctx);
            }
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    const property_names = [_][:0]const u8{
        "Category",           "Id",                "Title",             "Status",
        "WindowId",           "IconThemePath",     "IconName",          "IconPixmap",
        "OverlayIconName",    "OverlayIconPixmap", "AttentionIconName", "AttentionIconPixmap",
        "AttentionMovieName", "ToolTip",           "ItemIsMenu",
    };

    /// Appends the property as a variant. Returns false for unknown names.
    fn writeProperty(self: *Item, w: *dbus.Writer, name: []const u8) bool {
        const eq = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.mem.eql(u8, a, b);
            }
        }.f;
        if (eq(name, "Category")) {
            w.variantString("Hardware");
        } else if (eq(name, "Id")) {
            w.variantString("wayman");
        } else if (eq(name, "Title")) {
            w.variantString("Wayman");
        } else if (eq(name, "Status")) {
            w.variantString("Active");
        } else if (eq(name, "WindowId")) {
            var v = w.open(c.DBUS_TYPE_VARIANT, "i");
            v.int32(0);
            w.close(&v);
        } else if (eq(name, "IconThemePath") or eq(name, "IconName") or eq(name, "OverlayIconName") or
            eq(name, "AttentionIconName") or eq(name, "AttentionMovieName"))
        {
            w.variantString("");
        } else if (eq(name, "IconPixmap")) {
            var v = w.open(c.DBUS_TYPE_VARIANT, "a(iiay)");
            writePixmaps(&v, self.pixmaps);
            w.close(&v);
        } else if (eq(name, "OverlayIconPixmap") or eq(name, "AttentionIconPixmap")) {
            var v = w.open(c.DBUS_TYPE_VARIANT, "a(iiay)");
            writePixmaps(&v, &.{});
            w.close(&v);
        } else if (eq(name, "ToolTip")) {
            var v = w.open(c.DBUS_TYPE_VARIANT, "(sa(iiay)ss)");
            var s = v.open(c.DBUS_TYPE_STRUCT, null);
            s.string("");
            writePixmaps(&s, &.{});
            s.string(self.tooltip_title);
            s.string(self.tooltip_text);
            v.close(&s);
            w.close(&v);
        } else if (eq(name, "ItemIsMenu")) {
            // No Menu property: hosts then send ContextMenu on right click
            // instead of looking for a dbusmenu.
            w.variantBool(false);
        } else {
            return false;
        }
        return true;
    }

    fn writePixmaps(w: *dbus.Writer, pixmaps: []const Pixmap) void {
        var arr = w.open(c.DBUS_TYPE_ARRAY, "(iiay)");
        for (pixmaps) |p| {
            var s = arr.open(c.DBUS_TYPE_STRUCT, null);
            s.int32(@intCast(p.size));
            s.int32(@intCast(p.size));
            s.byteArray(p.data);
            arr.close(&s);
        }
        w.close(&arr);
    }
};
