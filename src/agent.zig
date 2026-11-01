// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! A NetworkManager secret agent.
//!
//! NetworkManager asks registered agents for secrets it does not have
//! (VPN passwords, one-time codes, a rejected Wi-Fi password). Each request
//! becomes a `Request` the UI turns into a prompt; the reply is sent later
//! with `respond` or `cancel`. Secrets the user typed are kept in memory for
//! the session so a reconnect does not ask again, except one-time codes.
const std = @import("std");
const c = @import("c");
const dbus = @import("dbus.zig");

const log = std.log.scoped(.agent);
const Allocator = std.mem.Allocator;

const agent_path = "/org/freedesktop/NetworkManager/SecretAgent";
const agent_iface = "org.freedesktop.NetworkManager.SecretAgent";
const nm_dest = "org.freedesktop.NetworkManager";
const manager_path = "/org/freedesktop/NetworkManager/AgentManager";
const manager_iface = "org.freedesktop.NetworkManager.AgentManager";
const agent_identifier = "wayman";

const err_no_secrets = "org.freedesktop.NetworkManager.SecretAgent.Error.NoSecrets";
const err_user_canceled = "org.freedesktop.NetworkManager.SecretAgent.Error.UserCanceled";
const err_agent_canceled = "org.freedesktop.NetworkManager.SecretAgent.Error.AgentCanceled";
const err_failed = "org.freedesktop.NetworkManager.SecretAgent.Error.Failed";

// NMSecretAgentGetSecretsFlags
const flag_allow_interaction: u32 = 0x1;
const flag_request_new: u32 = 0x2;

const introspection =
    \\<node>
    \\  <interface name="org.freedesktop.NetworkManager.SecretAgent">
    \\    <method name="GetSecrets">
    \\      <arg name="connection" type="a{sa{sv}}" direction="in"/>
    \\      <arg name="connection_path" type="o" direction="in"/>
    \\      <arg name="setting_name" type="s" direction="in"/>
    \\      <arg name="hints" type="as" direction="in"/>
    \\      <arg name="flags" type="u" direction="in"/>
    \\      <arg name="secrets" type="a{sa{sv}}" direction="out"/>
    \\    </method>
    \\    <method name="CancelGetSecrets">
    \\      <arg name="connection_path" type="o" direction="in"/>
    \\      <arg name="setting_name" type="s" direction="in"/>
    \\    </method>
    \\    <method name="SaveSecrets">
    \\      <arg name="connection" type="a{sa{sv}}" direction="in"/>
    \\      <arg name="connection_path" type="o" direction="in"/>
    \\    </method>
    \\    <method name="DeleteSecrets">
    \\      <arg name="connection" type="a{sa{sv}}" direction="in"/>
    \\      <arg name="connection_path" type="o" direction="in"/>
    \\    </method>
    \\  </interface>
    \\</node>
    \\
;

pub const Field = struct {
    /// Secret key as NetworkManager names it (`psk`, `password`, ...).
    key: [:0]const u8,
    /// Human label for the prompt.
    label: []const u8,
    masked: bool,
};

pub const Request = struct {
    id: u32,
    /// The GetSecrets call awaiting its reply (owned reference).
    msg: *c.DBusMessage,
    conn_path: [:0]u8,
    setting: [:0]u8,
    uuid: [:0]u8,
    /// Connection name, for the prompt title.
    title: [:0]u8,
    /// Message from the VPN plugin, if any.
    message: ?[:0]u8,
    fields: []Field,
    /// True when previous secrets were rejected and new ones are wanted.
    retry: bool,

    fn destroy(self: *Request, gpa: Allocator) void {
        c.dbus_message_unref(self.msg);
        gpa.free(self.conn_path);
        gpa.free(self.setting);
        gpa.free(self.uuid);
        gpa.free(self.title);
        if (self.message) |m| gpa.free(m);
        for (self.fields) |f| {
            gpa.free(f.key);
            gpa.free(f.label);
        }
        gpa.free(self.fields);
        gpa.destroy(self);
    }
};

pub const RequestFn = *const fn (?*anyopaque, *Request) void;

const Secret = struct { key: []u8, value: []u8 };

pub const Agent = struct {
    gpa: Allocator,
    conn: dbus.Connection,
    requests: std.ArrayList(*Request) = .empty,
    /// Session cache: "uuid/setting" -> secrets.
    cache: std.StringHashMapUnmanaged([]Secret) = .empty,
    next_id: u32 = 1,
    registered: bool = false,
    on_request: ?RequestFn = null,
    on_cancel: ?RequestFn = null,
    ctx: ?*anyopaque = null,

    const vtable: c.DBusObjectPathVTable = .{
        .unregister_function = null,
        .message_function = handleMessage,
    };

    pub fn init(self: *Agent, gpa: Allocator, conn: dbus.Connection) !void {
        self.* = .{ .gpa = gpa, .conn = conn };
        try conn.registerObject(agent_path, &vtable, self);
        const msg = try dbus.Message.methodCall(nm_dest, manager_path, manager_iface, "Register");
        var w = msg.writer();
        w.string(agent_identifier);
        if (conn.call(msg, 5000)) |reply| {
            reply.deinit();
            self.registered = true;
            log.info("registered as a NetworkManager secret agent", .{});
        } else |_| {
            log.warn("could not register as a secret agent; VPNs that ask for credentials will not work", .{});
        }
    }

    pub fn deinit(self: *Agent) void {
        for (self.requests.items) |req| {
            self.conn.send(dbus.Message.errorReply(req.msg, err_agent_canceled, "wayman is exiting") catch continue);
            req.destroy(self.gpa);
        }
        self.requests.deinit(self.gpa);
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            freeSecrets(self.gpa, entry.value_ptr.*);
        }
        self.cache.deinit(self.gpa);
        if (self.registered) {
            if (dbus.Message.methodCall(nm_dest, manager_path, manager_iface, "Unregister")) |msg| {
                if (self.conn.call(msg, 2000)) |reply| reply.deinit() else |_| {}
            } else |_| {}
        }
    }

    fn freeSecrets(gpa: Allocator, secrets: []Secret) void {
        for (secrets) |s| {
            @memset(s.value, 0);
            gpa.free(s.key);
            gpa.free(s.value);
        }
        gpa.free(secrets);
    }

    // ---- replies ---------------------------------------------------------

    /// Answer a request with one value per field. Takes care of the request.
    pub fn respond(self: *Agent, req: *Request, values: []const []const u8) void {
        defer self.remove(req);
        self.remember(req, values);
        const reply = dbus.Message.methodReturn(req.msg) catch return;
        var w = reply.writer();
        var settings = w.open(c.DBUS_TYPE_ARRAY, "{sa{sv}}");
        var section = settings.open(c.DBUS_TYPE_DICT_ENTRY, null);
        section.string(req.setting);
        var props = section.open(c.DBUS_TYPE_ARRAY, "{sv}");
        if (std.mem.eql(u8, req.setting, "vpn")) {
            var entry = props.open(c.DBUS_TYPE_DICT_ENTRY, null);
            entry.string("secrets");
            var variant = entry.open(c.DBUS_TYPE_VARIANT, "a{ss}");
            var dict = variant.open(c.DBUS_TYPE_ARRAY, "{ss}");
            for (req.fields, 0..) |f, i| {
                const valz = self.gpa.dupeSentinel(u8, values[i], 0) catch continue;
                defer {
                    @memset(valz, 0);
                    self.gpa.free(valz);
                }
                var kv = dict.open(c.DBUS_TYPE_DICT_ENTRY, null);
                kv.string(f.key);
                kv.string(valz);
                dict.close(&kv);
            }
            variant.close(&dict);
            entry.close(&variant);
            props.close(&entry);
        } else {
            for (req.fields, 0..) |f, i| {
                const valz = self.gpa.dupeSentinel(u8, values[i], 0) catch continue;
                defer {
                    @memset(valz, 0);
                    self.gpa.free(valz);
                }
                props.dictString(f.key, valz);
            }
        }
        section.close(&props);
        settings.close(&section);
        w.close(&settings);
        self.conn.send(reply);
        log.info("provided {s} secrets for {s}", .{ req.setting, req.title });
    }

    /// Tell NetworkManager the user declined. Takes care of the request.
    pub fn cancel(self: *Agent, req: *Request) void {
        defer self.remove(req);
        self.conn.send(dbus.Message.errorReply(req.msg, err_user_canceled, "Cancelled by the user") catch return);
        log.info("secret request for {s} cancelled", .{req.title});
    }

    fn remove(self: *Agent, req: *Request) void {
        for (self.requests.items, 0..) |r, i| {
            if (r == req) {
                _ = self.requests.swapRemove(i);
                break;
            }
        }
        req.destroy(self.gpa);
    }

    fn cacheKey(gpa: Allocator, uuid: []const u8, setting: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ uuid, setting });
    }

    fn remember(self: *Agent, req: *Request, values: []const []const u8) void {
        var list: std.ArrayList(Secret) = .empty;
        for (req.fields, 0..) |f, i| {
            // One-time codes are never reusable.
            if (std.mem.eql(u8, f.key, "challenge-response")) continue;
            const key = self.gpa.dupe(u8, f.key) catch continue;
            const value = self.gpa.dupe(u8, values[i]) catch {
                self.gpa.free(key);
                continue;
            };
            list.append(self.gpa, .{ .key = key, .value = value }) catch {
                self.gpa.free(key);
                self.gpa.free(value);
            };
        }
        if (list.items.len == 0) {
            list.deinit(self.gpa);
            return;
        }
        const key = cacheKey(self.gpa, req.uuid, req.setting) catch {
            freeSecrets(self.gpa, list.toOwnedSlice(self.gpa) catch return);
            return;
        };
        const secrets = list.toOwnedSlice(self.gpa) catch {
            self.gpa.free(key);
            return;
        };
        if (self.cache.fetchRemove(key)) |old| {
            self.gpa.free(old.key);
            freeSecrets(self.gpa, old.value);
        }
        self.cache.put(self.gpa, key, secrets) catch {
            self.gpa.free(key);
            freeSecrets(self.gpa, secrets);
        };
    }

    fn cached(self: *Agent, uuid: []const u8, setting: []const u8) ?[]Secret {
        const key = cacheKey(self.gpa, uuid, setting) catch return null;
        defer self.gpa.free(key);
        return self.cache.get(key);
    }

    fn forget(self: *Agent, uuid: []const u8) void {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.gpa);
        var it = self.cache.keyIterator();
        while (it.next()) |k| {
            if (std.mem.startsWith(u8, k.*, uuid)) keys.append(self.gpa, k.*) catch {};
        }
        for (keys.items) |k| {
            if (self.cache.fetchRemove(k)) |old| {
                self.gpa.free(old.key);
                freeSecrets(self.gpa, old.value);
            }
        }
    }

    // ---- D-Bus object ------------------------------------------------------

    fn handleMessage(_: ?*c.DBusConnection, msg_opt: ?*c.DBusMessage, data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
        const self: *Agent = @ptrCast(@alignCast(data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
        const msg = msg_opt orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        if (c.dbus_message_get_type(msg) != c.DBUS_MESSAGE_TYPE_METHOD_CALL) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        return self.handleCall(msg) catch |err| {
            log.warn("while handling an agent call: {t}", .{err});
            self.conn.send(dbus.Message.errorReply(msg, err_failed, "internal error") catch return c.DBUS_HANDLER_RESULT_HANDLED);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        };
    }

    fn handleCall(self: *Agent, msg: *c.DBusMessage) !c.DBusHandlerResult {
        const iface: []const u8 = if (c.dbus_message_get_interface(msg)) |i| std.mem.span(i) else agent_iface;
        const member = std.mem.span(c.dbus_message_get_member(msg) orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED);

        if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Introspectable") and std.mem.eql(u8, member, "Introspect")) {
            const reply = try dbus.Message.methodReturn(msg);
            var w = reply.writer();
            w.string(introspection);
            self.conn.send(reply);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
        if (!std.mem.eql(u8, iface, agent_iface)) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

        if (std.mem.eql(u8, member, "GetSecrets")) {
            try self.getSecrets(msg);
        } else if (std.mem.eql(u8, member, "CancelGetSecrets")) {
            var r = dbus.Reader.init(msg);
            const conn_path = try r.string();
            _ = r.next();
            const setting = try r.string();
            self.cancelRequest(conn_path, setting);
            self.conn.send(try dbus.Message.methodReturn(msg));
        } else if (std.mem.eql(u8, member, "SaveSecrets")) {
            var r = dbus.Reader.init(msg);
            self.saveSecrets(&r) catch |err| log.debug("SaveSecrets ignored: {t}", .{err});
            self.conn.send(try dbus.Message.methodReturn(msg));
        } else if (std.mem.eql(u8, member, "DeleteSecrets")) {
            var r = dbus.Reader.init(msg);
            const info = try readConnectionInfo(self.gpa, &r);
            defer info.deinit(self.gpa);
            self.forget(info.uuid);
            self.conn.send(try dbus.Message.methodReturn(msg));
        } else {
            return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        }
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }

    fn cancelRequest(self: *Agent, conn_path: []const u8, setting: []const u8) void {
        for (self.requests.items) |req| {
            if (std.mem.eql(u8, req.conn_path, conn_path) and std.mem.eql(u8, req.setting, setting)) {
                log.info("NetworkManager withdrew the secret request for {s}", .{req.title});
                if (self.on_cancel) |cb| cb(self.ctx, req);
                self.conn.send(dbus.Message.errorReply(req.msg, err_agent_canceled, "Cancelled") catch return);
                self.remove(req);
                return;
            }
        }
    }

    const ConnectionInfo = struct {
        id: [:0]u8,
        uuid: [:0]u8,
        kind: [:0]u8,
        /// `vpn.service-type` when present.
        service: ?[:0]u8,
        /// `vpn.data` key/value pairs (owned).
        vpn_data: []Secret,

        fn deinit(self: ConnectionInfo, gpa: Allocator) void {
            gpa.free(self.id);
            gpa.free(self.uuid);
            gpa.free(self.kind);
            if (self.service) |s| gpa.free(s);
            freeSecrets(gpa, self.vpn_data);
        }

        fn data(self: ConnectionInfo, key: []const u8) ?[]const u8 {
            for (self.vpn_data) |d| {
                if (std.mem.eql(u8, d.key, key)) return d.value;
            }
            return null;
        }
    };

    /// Reads the `a{sa{sv}}` connection argument the reader is positioned on.
    fn readConnectionInfo(gpa: Allocator, r: *dbus.Reader) !ConnectionInfo {
        var info: ConnectionInfo = .{
            .id = try gpa.dupeSentinel(u8, "", 0),
            .uuid = try gpa.dupeSentinel(u8, "", 0),
            .kind = try gpa.dupeSentinel(u8, "", 0),
            .service = null,
            .vpn_data = &.{},
        };
        errdefer info.deinit(gpa);
        var vpn_data: std.ArrayList(Secret) = .empty;
        errdefer freeSecrets(gpa, vpn_data.toOwnedSlice(gpa) catch &.{});

        var sections = try r.dict();
        while (sections.next()) |section| {
            var sv = section.value;
            var props = sv.dict() catch continue;
            if (std.mem.eql(u8, section.key, "connection")) {
                while (props.next()) |prop| {
                    var pv = prop.value;
                    var val = pv.variant() catch continue;
                    const str = val.string() catch continue;
                    if (std.mem.eql(u8, prop.key, "id")) {
                        gpa.free(info.id);
                        info.id = try gpa.dupeSentinel(u8, str, 0);
                    } else if (std.mem.eql(u8, prop.key, "uuid")) {
                        gpa.free(info.uuid);
                        info.uuid = try gpa.dupeSentinel(u8, str, 0);
                    } else if (std.mem.eql(u8, prop.key, "type")) {
                        gpa.free(info.kind);
                        info.kind = try gpa.dupeSentinel(u8, str, 0);
                    }
                }
            } else if (std.mem.eql(u8, section.key, "vpn")) {
                while (props.next()) |prop| {
                    var pv = prop.value;
                    var val = pv.variant() catch continue;
                    if (std.mem.eql(u8, prop.key, "service-type")) {
                        info.service = try gpa.dupeSentinel(u8, val.string() catch continue, 0);
                    } else if (std.mem.eql(u8, prop.key, "data")) {
                        var pairs = val.dict() catch continue;
                        while (pairs.next()) |pair| {
                            var value_reader = pair.value;
                            const value = value_reader.string() catch continue;
                            try vpn_data.append(gpa, .{
                                .key = try gpa.dupe(u8, pair.key),
                                .value = try gpa.dupe(u8, value),
                            });
                        }
                    }
                }
            }
        }
        info.vpn_data = try vpn_data.toOwnedSlice(gpa);
        return info;
    }

    fn getSecrets(self: *Agent, msg: *c.DBusMessage) !void {
        var r = dbus.Reader.init(msg);
        const info = try readConnectionInfo(self.gpa, &r);
        defer info.deinit(self.gpa);
        _ = r.next();
        const conn_path = try r.string();
        _ = r.next();
        const setting = try r.string();
        _ = r.next();
        var hints: std.ArrayList([]const u8) = .empty;
        defer hints.deinit(self.gpa);
        var hint_iter = try r.stringArray();
        while (hint_iter.next()) |h| try hints.append(self.gpa, h);
        _ = r.next();
        const flags = try r.uint32();

        const allow_interaction = flags & flag_allow_interaction != 0;
        const request_new = flags & flag_request_new != 0;
        log.info("secrets requested for {s} ({s}), {d} hints, flags {x}", .{ info.id, setting, hints.items.len, flags });

        if (!request_new) {
            if (self.cached(info.uuid, setting)) |secrets| {
                try self.replyCached(msg, setting, secrets);
                return;
            }
        }
        if (!allow_interaction) {
            self.conn.send(try dbus.Message.errorReply(msg, err_no_secrets, "No stored secrets"));
            return;
        }

        const req = try self.gpa.create(Request);
        errdefer self.gpa.destroy(req);
        var fields: std.ArrayList(Field) = .empty;
        errdefer {
            for (fields.items) |f| {
                self.gpa.free(f.key);
                self.gpa.free(f.label);
            }
            fields.deinit(self.gpa);
        }
        var message: ?[:0]u8 = null;
        errdefer if (message) |m| self.gpa.free(m);

        for (hints.items) |hint| {
            if (std.mem.startsWith(u8, hint, "x-vpn-message:")) {
                if (message == null) message = try self.gpa.dupeSentinel(u8, hint["x-vpn-message:".len..], 0);
            } else if (std.mem.startsWith(u8, hint, "x-dynamic-challenge-echo:")) {
                try self.addField(&fields, hint["x-dynamic-challenge-echo:".len..], false);
            } else if (std.mem.startsWith(u8, hint, "x-dynamic-challenge:")) {
                try self.addField(&fields, hint["x-dynamic-challenge:".len..], true);
            } else if (!std.mem.startsWith(u8, hint, "x-")) {
                try self.addField(&fields, hint, !std.mem.eql(u8, hint, "username"));
            }
        }
        if (fields.items.len == 0) try self.inferFields(&fields, setting, info);
        if (fields.items.len == 0) {
            // Nothing we know how to ask for; let NetworkManager carry on.
            self.conn.send(try dbus.Message.errorReply(msg, err_no_secrets, "No secrets to provide"));
            return;
        }

        req.* = .{
            .id = self.next_id,
            .msg = c.dbus_message_ref(msg) orelse return error.OutOfMemory,
            .conn_path = try self.gpa.dupeSentinel(u8, conn_path, 0),
            .setting = try self.gpa.dupeSentinel(u8, setting, 0),
            .uuid = try self.gpa.dupeSentinel(u8, info.uuid, 0),
            .title = try self.gpa.dupeSentinel(u8, info.id, 0),
            .message = message,
            .fields = try fields.toOwnedSlice(self.gpa),
            .retry = request_new,
        };
        self.next_id += 1;
        try self.requests.append(self.gpa, req);
        if (self.on_request) |cb| cb(self.ctx, req) else self.cancel(req);
    }

    fn addField(self: *Agent, fields: *std.ArrayList(Field), key: []const u8, masked: bool) !void {
        for (fields.items) |f| {
            if (std.mem.eql(u8, f.key, key)) return;
        }
        const label = labelFor(key);
        try fields.append(self.gpa, .{
            .key = try self.gpa.dupeSentinel(u8, key, 0),
            .label = try self.gpa.dupe(u8, label),
            .masked = masked,
        });
    }

    /// Without hints, work out which secrets the setting needs.
    fn inferFields(self: *Agent, fields: *std.ArrayList(Field), setting: []const u8, info: ConnectionInfo) !void {
        if (std.mem.eql(u8, setting, "802-11-wireless-security")) {
            try self.addField(fields, "psk", true);
        } else if (std.mem.eql(u8, setting, "802-1x")) {
            try self.addField(fields, "password", true);
        } else if (std.mem.eql(u8, setting, "vpn")) {
            const openvpn = if (info.service) |s| std.mem.endsWith(u8, s, ".openvpn") else false;
            if (openvpn) {
                const kind = info.data("connection-type") orelse "tls";
                if (std.mem.eql(u8, kind, "password") or std.mem.eql(u8, kind, "password-tls")) {
                    if (!flagNotRequired(info.data("password-flags"))) try self.addField(fields, "password", true);
                }
                if (flagAsks(info.data("cert-pass-flags"))) try self.addField(fields, "cert-pass", true);
                if (info.data("proxy-server") != null and flagAsks(info.data("http-proxy-password-flags"))) {
                    try self.addField(fields, "http-proxy-password", true);
                }
            } else {
                for (info.vpn_data) |d| {
                    if (!std.mem.endsWith(u8, d.key, "-flags")) continue;
                    if (!flagAsks(d.value)) continue;
                    const name = d.key[0 .. d.key.len - "-flags".len];
                    if (std.mem.eql(u8, name, "challenge-response")) continue;
                    try self.addField(fields, name, true);
                }
                if (fields.items.len == 0) try self.addField(fields, "password", true);
            }
        } else {
            try self.addField(fields, "password", true);
        }
    }

    /// NMSettingSecretFlags: 1 agent-owned, 2 not saved, 4 not required.
    fn flagAsks(value: ?[]const u8) bool {
        const v = std.fmt.parseInt(u32, value orelse return false, 10) catch return false;
        return v & 3 != 0 and v & 4 == 0;
    }

    fn flagNotRequired(value: ?[]const u8) bool {
        const v = std.fmt.parseInt(u32, value orelse return false, 10) catch return false;
        return v & 4 != 0;
    }

    fn labelFor(key: []const u8) []const u8 {
        const table = [_]struct { key: []const u8, label: []const u8 }{
            .{ .key = "psk", .label = "Password" },
            .{ .key = "password", .label = "Password" },
            .{ .key = "username", .label = "Username" },
            .{ .key = "cert-pass", .label = "Certificate password" },
            .{ .key = "private-key-password", .label = "Private key password" },
            .{ .key = "http-proxy-password", .label = "Proxy password" },
            .{ .key = "challenge-response", .label = "One-time code" },
            .{ .key = "wep-key0", .label = "WEP key" },
            .{ .key = "leap-password", .label = "Password" },
            .{ .key = "private-key", .label = "Private key" },
            .{ .key = "preshared-key", .label = "Pre-shared key" },
        };
        for (table) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.label;
        }
        return key;
    }

    fn replyCached(self: *Agent, msg: *c.DBusMessage, setting: []const u8, secrets: []Secret) !void {
        const reply = try dbus.Message.methodReturn(msg);
        var w = reply.writer();
        var settings = w.open(c.DBUS_TYPE_ARRAY, "{sa{sv}}");
        var section = settings.open(c.DBUS_TYPE_DICT_ENTRY, null);
        const settingz = try self.gpa.dupeSentinel(u8, setting, 0);
        defer self.gpa.free(settingz);
        section.string(settingz);
        var props = section.open(c.DBUS_TYPE_ARRAY, "{sv}");
        const is_vpn = std.mem.eql(u8, setting, "vpn");
        var entry: dbus.Writer = undefined;
        var variant: dbus.Writer = undefined;
        var dict: dbus.Writer = undefined;
        if (is_vpn) {
            entry = props.open(c.DBUS_TYPE_DICT_ENTRY, null);
            entry.string("secrets");
            variant = entry.open(c.DBUS_TYPE_VARIANT, "a{ss}");
            dict = variant.open(c.DBUS_TYPE_ARRAY, "{ss}");
        }
        for (secrets) |s| {
            const keyz = try self.gpa.dupeSentinel(u8, s.key, 0);
            defer self.gpa.free(keyz);
            const valz = try self.gpa.dupeSentinel(u8, s.value, 0);
            defer {
                @memset(valz, 0);
                self.gpa.free(valz);
            }
            if (is_vpn) {
                var kv = dict.open(c.DBUS_TYPE_DICT_ENTRY, null);
                kv.string(keyz);
                kv.string(valz);
                dict.close(&kv);
            } else {
                props.dictString(keyz, valz);
            }
        }
        if (is_vpn) {
            variant.close(&dict);
            entry.close(&variant);
            props.close(&entry);
        }
        section.close(&props);
        settings.close(&section);
        w.close(&settings);
        self.conn.send(reply);
        log.info("provided cached {s} secrets", .{setting});
    }

    /// NetworkManager hands back the connection with its secrets after a
    /// successful activation; keep the ones we may be asked for again.
    fn saveSecrets(self: *Agent, r: *dbus.Reader) !void {
        // Walk the connection ourselves: we need the secret values, which
        // readConnectionInfo does not keep for non-VPN settings.
        var uuid: ?[]u8 = null;
        defer if (uuid) |u| self.gpa.free(u);
        var found: std.ArrayList(struct { setting: []u8, secrets: []Secret }) = .empty;
        defer {
            for (found.items) |f| {
                self.gpa.free(f.setting);
                freeSecrets(self.gpa, f.secrets);
            }
            found.deinit(self.gpa);
        }
        const secret_keys = [_][]const u8{ "psk", "password", "private-key-password", "wep-key0", "leap-password", "private-key" };

        var sections = try r.dict();
        while (sections.next()) |section| {
            var sv = section.value;
            var props = sv.dict() catch continue;
            var list: std.ArrayList(Secret) = .empty;
            errdefer freeSecrets(self.gpa, list.toOwnedSlice(self.gpa) catch &.{});
            while (props.next()) |prop| {
                var pv = prop.value;
                var val = pv.variant() catch continue;
                if (std.mem.eql(u8, section.key, "connection")) {
                    if (std.mem.eql(u8, prop.key, "uuid")) uuid = try self.gpa.dupe(u8, val.string() catch continue);
                } else if (std.mem.eql(u8, section.key, "vpn") and std.mem.eql(u8, prop.key, "secrets")) {
                    var pairs = val.dict() catch continue;
                    while (pairs.next()) |pair| {
                        if (std.mem.eql(u8, pair.key, "challenge-response")) continue;
                        var vr = pair.value;
                        const value = vr.string() catch continue;
                        try list.append(self.gpa, .{ .key = try self.gpa.dupe(u8, pair.key), .value = try self.gpa.dupe(u8, value) });
                    }
                } else {
                    for (secret_keys) |k| {
                        if (!std.mem.eql(u8, prop.key, k)) continue;
                        const value = val.string() catch continue;
                        try list.append(self.gpa, .{ .key = try self.gpa.dupe(u8, k), .value = try self.gpa.dupe(u8, value) });
                    }
                }
            }
            if (list.items.len > 0) {
                try found.append(self.gpa, .{ .setting = try self.gpa.dupe(u8, section.key), .secrets = try list.toOwnedSlice(self.gpa) });
            } else {
                list.deinit(self.gpa);
            }
        }
        const u = uuid orelse return;
        for (found.items) |*f| {
            const key = try cacheKey(self.gpa, u, f.setting);
            if (self.cache.fetchRemove(key)) |old| {
                self.gpa.free(old.key);
                freeSecrets(self.gpa, old.value);
            }
            try self.cache.put(self.gpa, key, f.secrets);
            f.secrets = &.{};
        }
    }
};

test "secret flag helpers" {
    try std.testing.expect(Agent.flagAsks("2"));
    try std.testing.expect(Agent.flagAsks("1"));
    try std.testing.expect(!Agent.flagAsks("0"));
    try std.testing.expect(!Agent.flagAsks("4"));
    try std.testing.expect(!Agent.flagAsks(null));
    try std.testing.expect(Agent.flagNotRequired("4"));
    try std.testing.expectEqualStrings("One-time code", Agent.labelFor("challenge-response"));
    try std.testing.expectEqualStrings("foo", Agent.labelFor("foo"));
}
