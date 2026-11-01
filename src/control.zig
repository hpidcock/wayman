// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! The daemon's control interface on the session bus, and the client side
//! used by `wayman toggle`, `wayman clock toggle` and `wayman quit`.
const std = @import("std");
const c = @import("c");
const dbus = @import("dbus.zig");

const log = std.log.scoped(.control);

pub const bus_name = "dev.wayman";
pub const path = "/dev/wayman";
pub const iface = "dev.wayman.Control";

pub const Action = enum { toggle_wifi, toggle_clock, quit };
pub const ActionFn = *const fn (?*anyopaque, Action) void;

const introspection =
    \\<node>
    \\  <interface name="dev.wayman.Control">
    \\    <method name="ToggleWifi"/>
    \\    <method name="ToggleClock"/>
    \\    <method name="Quit"/>
    \\  </interface>
    \\</node>
    \\
;

pub const Server = struct {
    conn: dbus.Connection,
    on_action: ActionFn,
    ctx: ?*anyopaque,

    const vtable: c.DBusObjectPathVTable = .{
        .unregister_function = null,
        .message_function = handleMessage,
    };

    pub fn init(self: *Server, conn: dbus.Connection, on_action: ActionFn, ctx: ?*anyopaque) !void {
        self.* = .{ .conn = conn, .on_action = on_action, .ctx = ctx };
        try conn.requestName(bus_name);
        try conn.registerObject(path, &vtable, self);
    }

    fn handleMessage(_: ?*c.DBusConnection, msg_opt: ?*c.DBusMessage, data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
        const self: *Server = @ptrCast(@alignCast(data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
        const msg = msg_opt orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        if (c.dbus_message_get_type(msg) != c.DBUS_MESSAGE_TYPE_METHOD_CALL) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        const member = std.mem.span(c.dbus_message_get_member(msg) orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED);
        const msg_iface: []const u8 = if (c.dbus_message_get_interface(msg)) |i| std.mem.span(i) else iface;

        if (std.mem.eql(u8, msg_iface, "org.freedesktop.DBus.Introspectable") and std.mem.eql(u8, member, "Introspect")) {
            const reply = dbus.Message.methodReturn(msg) catch return c.DBUS_HANDLER_RESULT_HANDLED;
            var w = reply.writer();
            w.string(introspection);
            self.conn.send(reply);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
        if (!std.mem.eql(u8, msg_iface, iface)) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

        const action: Action = if (std.mem.eql(u8, member, "ToggleWifi"))
            .toggle_wifi
        else if (std.mem.eql(u8, member, "ToggleClock"))
            .toggle_clock
        else if (std.mem.eql(u8, member, "Quit"))
            .quit
        else
            return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        if (c.dbus_message_get_no_reply(msg) == 0) {
            if (dbus.Message.methodReturn(msg)) |reply| self.conn.send(reply) else |_| {}
        }
        self.on_action(self.ctx, action);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
};

/// Asks the running daemon to perform an action. Returns false when no
/// daemon owns the control name.
pub fn send(action: Action) bool {
    const conn = dbus.Connection.open(.session) catch return false;
    defer conn.close();
    const member: [*:0]const u8 = switch (action) {
        .toggle_wifi => "ToggleWifi",
        .toggle_clock => "ToggleClock",
        .quit => "Quit",
    };
    const msg = dbus.Message.methodCall(bus_name, path, iface, member) catch return false;
    const reply = conn.call(msg, 5000) catch return false;
    reply.deinit();
    return true;
}
