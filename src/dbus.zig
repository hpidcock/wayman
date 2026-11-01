// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! Thin, allocation-free helpers over libdbus-1.
//!
//! libdbus is used both as a client (NetworkManager on the system bus) and
//! as a server (the StatusNotifierItem object on the session bus).
const std = @import("std");
const c = @import("c");

const log = std.log.scoped(.dbus);

pub const CallError = error{DBusCall};
pub const TypeError = error{DBusType};

/// Layout-compatible mirror of `DBusError`. translate-c demotes the real
/// struct to an opaque type because it contains bitfields, so we declare our
/// own and cast at the boundary.
pub const Error = extern struct {
    name: [*c]const u8 = null,
    message: [*c]const u8 = null,
    dummy: c_uint = 0,
    padding1: ?*anyopaque = null,

    pub fn init() Error {
        var e: Error = .{};
        c.dbus_error_init(@ptrCast(&e));
        return e;
    }

    pub fn raw(e: *Error) ?*c.DBusError {
        return @ptrCast(e);
    }

    pub fn isSet(e: *Error) bool {
        return c.dbus_error_is_set(e.raw()) != 0;
    }

    pub fn free(e: *Error) void {
        c.dbus_error_free(e.raw());
    }

    pub fn text(e: *const Error) []const u8 {
        return if (e.message) |m| std.mem.span(m) else "unknown error";
    }

    pub fn nameText(e: *const Error) []const u8 {
        return if (e.name) |n| std.mem.span(n) else "?";
    }
};

pub const Bus = enum { system, session };

pub const Connection = struct {
    raw: *c.DBusConnection,

    pub fn open(bus: Bus) !Connection {
        var err = Error.init();
        defer err.free();
        const bus_type: c.DBusBusType = switch (bus) {
            .system => c.DBUS_BUS_SYSTEM,
            .session => c.DBUS_BUS_SESSION,
        };
        const raw = c.dbus_bus_get_private(bus_type, err.raw()) orelse {
            log.err("cannot connect to the {s} bus: {s}", .{ @tagName(bus), err.text() });
            return error.DBusConnect;
        };
        c.dbus_connection_set_exit_on_disconnect(raw, 0);
        return .{ .raw = raw };
    }

    pub fn close(self: Connection) void {
        c.dbus_connection_close(self.raw);
        c.dbus_connection_unref(self.raw);
    }

    pub fn fd(self: Connection) !std.posix.fd_t {
        var out: c_int = -1;
        if (c.dbus_connection_get_unix_fd(self.raw, &out) == 0) return error.NoFd;
        return out;
    }

    /// Read whatever is pending on the socket and dispatch every queued
    /// message to filters and object handlers. Never blocks.
    pub fn dispatch(self: Connection) void {
        _ = c.dbus_connection_read_write_dispatch(self.raw, 0);
        while (c.dbus_connection_get_dispatch_status(self.raw) == c.DBUS_DISPATCH_DATA_REMAINS) {
            _ = c.dbus_connection_dispatch(self.raw);
        }
    }

    pub fn flush(self: Connection) void {
        c.dbus_connection_flush(self.raw);
    }

    pub fn isConnected(self: Connection) bool {
        return c.dbus_connection_get_is_connected(self.raw) != 0;
    }

    /// Send a method call and block for the reply. Takes ownership of `msg`.
    pub fn call(self: Connection, msg: Message, timeout_ms: c_int) CallError!Reply {
        defer c.dbus_message_unref(msg.raw);
        var err = Error.init();
        defer err.free();
        const reply = c.dbus_connection_send_with_reply_and_block(self.raw, msg.raw, timeout_ms, err.raw()) orelse {
            log.warn("{s}.{s} failed: {s}: {s}", .{
                std.mem.span(c.dbus_message_get_interface(msg.raw)),
                std.mem.span(c.dbus_message_get_member(msg.raw)),
                err.nameText(),
                err.text(),
            });
            return error.DBusCall;
        };
        return .{ .raw = reply };
    }

    /// Queue a message (reply or signal) for sending. Takes ownership.
    pub fn send(self: Connection, msg: Message) void {
        defer c.dbus_message_unref(msg.raw);
        if (c.dbus_connection_send(self.raw, msg.raw, null) == 0) log.warn("send failed: out of memory", .{});
    }

    pub fn addMatch(self: Connection, rule: [*:0]const u8) !void {
        var err = Error.init();
        defer err.free();
        c.dbus_bus_add_match(self.raw, rule, err.raw());
        if (err.isSet()) {
            log.err("add match '{s}' failed: {s}", .{ rule, err.text() });
            return error.DBusMatch;
        }
    }

    pub fn addFilter(self: Connection, func: c.DBusHandleMessageFunction, ctx: ?*anyopaque) !void {
        if (c.dbus_connection_add_filter(self.raw, func, ctx, null) == 0) return error.OutOfMemory;
    }

    pub fn requestName(self: Connection, name: [*:0]const u8) !void {
        var err = Error.init();
        defer err.free();
        const result = c.dbus_bus_request_name(self.raw, name, c.DBUS_NAME_FLAG_DO_NOT_QUEUE, err.raw());
        if (err.isSet()) {
            log.err("request name '{s}' failed: {s}", .{ name, err.text() });
            return error.DBusName;
        }
        if (result != c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) return error.DBusNameTaken;
    }

    pub fn registerObject(self: Connection, path: [*:0]const u8, vtable: *const c.DBusObjectPathVTable, ctx: ?*anyopaque) !void {
        if (c.dbus_connection_register_object_path(self.raw, path, vtable, ctx) == 0) return error.DBusRegister;
    }
};

pub const Reply = struct {
    raw: *c.DBusMessage,

    pub fn deinit(r: Reply) void {
        c.dbus_message_unref(r.raw);
    }

    pub fn reader(r: Reply) Reader {
        return Reader.init(r.raw);
    }
};

pub const Message = struct {
    raw: *c.DBusMessage,

    pub fn methodCall(dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, member: [*:0]const u8) !Message {
        const raw = c.dbus_message_new_method_call(dest, path, iface, member) orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn signal(path: [*:0]const u8, iface: [*:0]const u8, member: [*:0]const u8) !Message {
        const raw = c.dbus_message_new_signal(path, iface, member) orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn methodReturn(call: *c.DBusMessage) !Message {
        const raw = c.dbus_message_new_method_return(call) orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn errorReply(call: *c.DBusMessage, name: [*:0]const u8, text: [*:0]const u8) !Message {
        const raw = c.dbus_message_new_error(call, name, text) orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn writer(m: Message) Writer {
        var w: Writer = .{ .it = undefined };
        c.dbus_message_iter_init_append(m.raw, &w.it);
        return w;
    }
};

/// Appends arguments to a message. Containers are opened with `open` and
/// must be closed with `close` on the parent.
pub const Writer = struct {
    it: c.DBusMessageIter,

    fn basic(w: *Writer, kind: c_int, value: *const anyopaque) void {
        if (c.dbus_message_iter_append_basic(&w.it, kind, value) == 0) @panic("dbus: out of memory");
    }

    pub fn string(w: *Writer, s: [*:0]const u8) void {
        const p: [*c]const u8 = s;
        w.basic(c.DBUS_TYPE_STRING, @ptrCast(&p));
    }

    pub fn objectPath(w: *Writer, s: [*:0]const u8) void {
        const p: [*c]const u8 = s;
        w.basic(c.DBUS_TYPE_OBJECT_PATH, @ptrCast(&p));
    }

    pub fn uint32(w: *Writer, v: u32) void {
        w.basic(c.DBUS_TYPE_UINT32, @ptrCast(&v));
    }

    pub fn int32(w: *Writer, v: i32) void {
        w.basic(c.DBUS_TYPE_INT32, @ptrCast(&v));
    }

    pub fn boolean(w: *Writer, v: bool) void {
        const b: c.dbus_bool_t = @intFromBool(v);
        w.basic(c.DBUS_TYPE_BOOLEAN, @ptrCast(&b));
    }

    pub fn byteArray(w: *Writer, bytes: []const u8) void {
        var sub = w.open(c.DBUS_TYPE_ARRAY, "y");
        const p: [*c]const u8 = bytes.ptr;
        if (c.dbus_message_iter_append_fixed_array(&sub.it, c.DBUS_TYPE_BYTE, @ptrCast(&p), @intCast(bytes.len)) == 0) @panic("dbus: out of memory");
        w.close(&sub);
    }

    pub fn open(w: *Writer, kind: c_int, signature: ?[*:0]const u8) Writer {
        var sub: Writer = .{ .it = undefined };
        if (c.dbus_message_iter_open_container(&w.it, kind, signature, &sub.it) == 0) @panic("dbus: out of memory");
        return sub;
    }

    pub fn close(w: *Writer, sub: *Writer) void {
        if (c.dbus_message_iter_close_container(&w.it, &sub.it) == 0) @panic("dbus: out of memory");
    }

    pub fn variantString(w: *Writer, s: [*:0]const u8) void {
        var v = w.open(c.DBUS_TYPE_VARIANT, "s");
        v.string(s);
        w.close(&v);
    }

    pub fn variantBool(w: *Writer, b: bool) void {
        var v = w.open(c.DBUS_TYPE_VARIANT, "b");
        v.boolean(b);
        w.close(&v);
    }

    /// Appends a `{sv}` entry holding a string. The writer must be inside an `a{sv}`.
    pub fn dictString(w: *Writer, key: [*:0]const u8, value: [*:0]const u8) void {
        var e = w.open(c.DBUS_TYPE_DICT_ENTRY, null);
        e.string(key);
        e.variantString(value);
        w.close(&e);
    }

    pub fn dictBool(w: *Writer, key: [*:0]const u8, value: bool) void {
        var e = w.open(c.DBUS_TYPE_DICT_ENTRY, null);
        e.string(key);
        e.variantBool(value);
        w.close(&e);
    }

    pub fn dictUint32(w: *Writer, key: [*:0]const u8, value: u32) void {
        var e = w.open(c.DBUS_TYPE_DICT_ENTRY, null);
        e.string(key);
        var v = e.open(c.DBUS_TYPE_VARIANT, "u");
        v.uint32(value);
        e.close(&v);
        w.close(&e);
    }

    pub fn dictInt32(w: *Writer, key: [*:0]const u8, value: i32) void {
        var e = w.open(c.DBUS_TYPE_DICT_ENTRY, null);
        e.string(key);
        var v = e.open(c.DBUS_TYPE_VARIANT, "i");
        v.int32(value);
        e.close(&v);
        w.close(&e);
    }

    /// Appends a `{sv}` entry holding an `as`.
    pub fn dictStringArray(w: *Writer, key: [*:0]const u8, values: []const [*:0]const u8) void {
        var e = w.open(c.DBUS_TYPE_DICT_ENTRY, null);
        e.string(key);
        var v = e.open(c.DBUS_TYPE_VARIANT, "as");
        var arr = v.open(c.DBUS_TYPE_ARRAY, "s");
        for (values) |s| arr.string(s);
        v.close(&arr);
        e.close(&v);
        w.close(&e);
    }

    pub fn dictByteArray(w: *Writer, key: [*:0]const u8, bytes: []const u8) void {
        var e = w.open(c.DBUS_TYPE_DICT_ENTRY, null);
        e.string(key);
        var v = e.open(c.DBUS_TYPE_VARIANT, "ay");
        v.byteArray(bytes);
        e.close(&v);
        w.close(&e);
    }
};

/// Reads arguments from a message. Each getter reads the current argument
/// without advancing; call `next` to move on.
pub const Reader = struct {
    it: c.DBusMessageIter,

    pub fn init(msg: *c.DBusMessage) Reader {
        var r: Reader = .{ .it = undefined };
        _ = c.dbus_message_iter_init(msg, &r.it);
        return r;
    }

    pub fn argType(r: *Reader) c_int {
        return c.dbus_message_iter_get_arg_type(&r.it);
    }

    pub fn atEnd(r: *Reader) bool {
        return r.argType() == c.DBUS_TYPE_INVALID;
    }

    pub fn next(r: *Reader) bool {
        return c.dbus_message_iter_next(&r.it) != 0;
    }

    pub fn recurse(r: *Reader) Reader {
        var sub: Reader = .{ .it = undefined };
        c.dbus_message_iter_recurse(&r.it, &sub.it);
        return sub;
    }

    fn expect(r: *Reader, kind: c_int) TypeError!void {
        if (r.argType() != kind) return error.DBusType;
    }

    /// Valid for as long as the message is alive.
    pub fn string(r: *Reader) TypeError![:0]const u8 {
        const t = r.argType();
        if (t != c.DBUS_TYPE_STRING and t != c.DBUS_TYPE_OBJECT_PATH and t != c.DBUS_TYPE_SIGNATURE) return error.DBusType;
        var p: [*c]const u8 = null;
        c.dbus_message_iter_get_basic(&r.it, @ptrCast(&p));
        return std.mem.span(p);
    }

    pub fn uint32(r: *Reader) TypeError!u32 {
        try r.expect(c.DBUS_TYPE_UINT32);
        var v: u32 = 0;
        c.dbus_message_iter_get_basic(&r.it, @ptrCast(&v));
        return v;
    }

    pub fn int32(r: *Reader) TypeError!i32 {
        try r.expect(c.DBUS_TYPE_INT32);
        var v: i32 = 0;
        c.dbus_message_iter_get_basic(&r.it, @ptrCast(&v));
        return v;
    }

    pub fn byte(r: *Reader) TypeError!u8 {
        try r.expect(c.DBUS_TYPE_BYTE);
        var v: u8 = 0;
        c.dbus_message_iter_get_basic(&r.it, @ptrCast(&v));
        return v;
    }

    pub fn boolean(r: *Reader) TypeError!bool {
        try r.expect(c.DBUS_TYPE_BOOLEAN);
        var v: c.dbus_bool_t = 0;
        c.dbus_message_iter_get_basic(&r.it, @ptrCast(&v));
        return v != 0;
    }

    /// Reads an `ay`. Valid for as long as the message is alive.
    pub fn byteArray(r: *Reader) TypeError![]const u8 {
        try r.expect(c.DBUS_TYPE_ARRAY);
        if (c.dbus_message_iter_get_element_type(&r.it) != c.DBUS_TYPE_BYTE) return error.DBusType;
        var sub = r.recurse();
        var p: [*c]const u8 = null;
        var n: c_int = 0;
        c.dbus_message_iter_get_fixed_array(&sub.it, @ptrCast(&p), &n);
        if (n <= 0 or p == null) return &.{};
        return p[0..@intCast(n)];
    }

    pub fn variant(r: *Reader) TypeError!Reader {
        try r.expect(c.DBUS_TYPE_VARIANT);
        return r.recurse();
    }

    /// Iterates the entries of an `a{sv}` (or any dict array).
    pub fn dict(r: *Reader) TypeError!DictIterator {
        try r.expect(c.DBUS_TYPE_ARRAY);
        if (c.dbus_message_iter_get_element_type(&r.it) != c.DBUS_TYPE_DICT_ENTRY) return error.DBusType;
        return .{ .entries = r.recurse() };
    }

    /// Iterates an `ao` / `as`.
    pub fn stringArray(r: *Reader) TypeError!StringIterator {
        try r.expect(c.DBUS_TYPE_ARRAY);
        const et = c.dbus_message_iter_get_element_type(&r.it);
        if (et != c.DBUS_TYPE_OBJECT_PATH and et != c.DBUS_TYPE_STRING) return error.DBusType;
        return .{ .items = r.recurse() };
    }
};

pub const DictEntry = struct {
    key: [:0]const u8,
    /// Positioned on the value (usually a variant).
    value: Reader,
};

pub const DictIterator = struct {
    entries: Reader,

    pub fn next(self: *DictIterator) ?DictEntry {
        if (self.entries.argType() != c.DBUS_TYPE_DICT_ENTRY) return null;
        defer _ = self.entries.next();
        var entry = self.entries.recurse();
        const key = entry.string() catch return null;
        _ = entry.next();
        return .{ .key = key, .value = entry };
    }
};

pub const StringIterator = struct {
    items: Reader,

    pub fn next(self: *StringIterator) ?[:0]const u8 {
        if (self.items.atEnd()) return null;
        defer _ = self.items.next();
        return self.items.string() catch null;
    }
};

pub const properties_iface = "org.freedesktop.DBus.Properties";

/// `org.freedesktop.DBus.Properties.Get`. The reply's reader is positioned on the variant.
pub fn getProperty(conn: Connection, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, name: [*:0]const u8) !Reply {
    const msg = try Message.methodCall(dest, path, properties_iface, "Get");
    var w = msg.writer();
    w.string(iface);
    w.string(name);
    return conn.call(msg, 5000);
}

/// `org.freedesktop.DBus.Properties.GetAll`. The reply's reader is positioned on the `a{sv}`.
pub fn getAllProperties(conn: Connection, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8) !Reply {
    const msg = try Message.methodCall(dest, path, properties_iface, "GetAll");
    var w = msg.writer();
    w.string(iface);
    return conn.call(msg, 5000);
}
