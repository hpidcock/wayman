// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! NetworkManager client over the system bus.
//!
//! Keeps a snapshot (`Model`) of the first Wi-Fi device: its state, the
//! visible networks (de-duplicated by SSID), which of them have a saved
//! profile, and which one is active. Connections created here are persisted
//! by NetworkManager's netplan integration.
const std = @import("std");
const c = @import("c");
const dbus = @import("dbus.zig");

const log = std.log.scoped(.nm);
const Allocator = std.mem.Allocator;

const dest = "org.freedesktop.NetworkManager";
const nm_path = "/org/freedesktop/NetworkManager";
const nm_iface = "org.freedesktop.NetworkManager";
const device_iface = nm_iface ++ ".Device";
const wireless_iface = nm_iface ++ ".Device.Wireless";
const ap_iface = nm_iface ++ ".AccessPoint";
const active_iface = nm_iface ++ ".Connection.Active";
const settings_iface = nm_iface ++ ".Settings";
const settings_conn_iface = settings_iface ++ ".Connection";

const device_type_wifi: u32 = 2;

// NM80211ApFlags / NM80211ApSecurityFlags
const ap_flag_privacy: u32 = 0x1;
const sec_key_mgmt_psk: u32 = 0x100;
const sec_key_mgmt_802_1x: u32 = 0x200;
const sec_key_mgmt_sae: u32 = 0x400;
const sec_key_mgmt_owe: u32 = 0x800;
const sec_key_mgmt_owe_tm: u32 = 0x1000;
const sec_key_mgmt_eap_suite_b_192: u32 = 0x2000;

/// NMDeviceState values we care about.
pub const DeviceState = struct {
    pub const unavailable: u32 = 20;
    pub const disconnected: u32 = 30;
    pub const prepare: u32 = 40;
    pub const secondaries: u32 = 90;
    pub const activated: u32 = 100;
    pub const deactivating: u32 = 110;
    pub const failed: u32 = 120;
};

/// NMDeviceStateReason values that indicate an authentication problem.
const reason_no_secrets: u32 = 7;
const reason_supplicant_timeout: u32 = 11;

pub const Security = enum {
    open,
    owe,
    wep,
    psk,
    sae,
    eap,

    pub fn needsPassword(s: Security) bool {
        return s == .psk or s == .sae;
    }

    pub fn isSecured(s: Security) bool {
        return s != .open and s != .owe;
    }

    /// Whether wayman can create a profile for this network itself.
    pub fn canAutoCreate(s: Security) bool {
        return switch (s) {
            .open, .owe, .psk, .sae => true,
            .wep, .eap => false,
        };
    }

    pub fn label(s: Security) []const u8 {
        return switch (s) {
            .open => "Open",
            .owe => "Enhanced open",
            .wep => "WEP",
            .psk => "WPA2",
            .sae => "WPA3",
            .eap => "Enterprise",
        };
    }

    fn keyMgmt(s: Security) ?[*:0]const u8 {
        return switch (s) {
            .open => null,
            .owe => "owe",
            .psk => "wpa-psk",
            .sae => "sae",
            .wep, .eap => null,
        };
    }
};

fn classify(flags: u32, wpa: u32, rsn: u32) Security {
    const all = wpa | rsn;
    if (all & sec_key_mgmt_psk != 0) return .psk;
    if (all & sec_key_mgmt_sae != 0) return .sae;
    if (all & (sec_key_mgmt_802_1x | sec_key_mgmt_eap_suite_b_192) != 0) return .eap;
    if (all & sec_key_mgmt_owe != 0) return .owe;
    if (all & sec_key_mgmt_owe_tm != 0) return .open;
    if (flags & ap_flag_privacy != 0) return .wep;
    return .open;
}

pub fn strengthToBars(strength: u8) u8 {
    if (strength >= 80) return 4;
    if (strength >= 55) return 3;
    if (strength >= 30) return 2;
    if (strength > 0) return 1;
    return 0;
}

pub const Network = struct {
    /// Display form: valid UTF-8, control characters replaced.
    ssid: [:0]const u8,
    /// Exact bytes as broadcast, used when creating a profile.
    raw_ssid: []const u8,
    /// Strongest access point for this SSID.
    ap_path: [:0]const u8,
    strength: u8,
    frequency: u32,
    security: Security,
    /// Settings connection path when NetworkManager has a usable profile.
    saved: ?[:0]const u8,
    /// True for the SSID of the device's active access point (connected or connecting).
    active: bool,

    pub fn bars(n: Network) u8 {
        return strengthToBars(n.strength);
    }
};

pub const Status = enum { no_device, disabled, disconnected, connecting, connected };

pub const Model = struct {
    status: Status = .no_device,
    wireless_enabled: bool = false,
    device_state: u32 = 0,
    active_ssid: ?[:0]const u8 = null,
    active_strength: u8 = 0,
    networks: []Network = &.{},
};

const Pending = struct {
    ssid: [:0]u8,
    /// Set when the profile was created by this attempt and should be
    /// removed again if authentication fails.
    added_path: ?[:0]u8,
};

pub const ChangeFn = *const fn (?*anyopaque) void;

pub const Client = struct {
    gpa: Allocator,
    conn: dbus.Connection,
    arena: std.heap.ArenaAllocator,
    model: Model = .{},
    device_path: ?[:0]u8 = null,
    device_dirty: bool = true,
    dirty: bool = true,
    dirty_since_ms: i64 = 0,
    pending: ?Pending = null,
    /// A profile to delete from the main loop (set by the signal filter).
    cleanup_path: ?[:0]u8 = null,
    last_error: ?[]u8 = null,
    on_change: ?ChangeFn = null,
    on_change_ctx: ?*anyopaque = null,

    /// How long to coalesce bursts of change signals before re-reading state.
    pub const coalesce_ms: i64 = 150;

    pub fn init(self: *Client, gpa: Allocator, conn: dbus.Connection) !void {
        self.* = .{
            .gpa = gpa,
            .conn = conn,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        try conn.addMatch("type='signal',sender='org.freedesktop.NetworkManager'");
        try conn.addFilter(filter, self);
    }

    pub fn deinit(self: *Client) void {
        self.clearPending();
        if (self.device_path) |p| self.gpa.free(p);
        if (self.cleanup_path) |p| self.gpa.free(p);
        if (self.last_error) |e| self.gpa.free(e);
        self.arena.deinit();
    }

    pub fn lastError(self: *const Client) ?[]const u8 {
        return self.last_error;
    }

    pub fn findNetwork(self: *const Client, ssid: []const u8) ?*const Network {
        for (self.model.networks) |*n| {
            if (std.mem.eql(u8, n.ssid, ssid)) return n;
        }
        return null;
    }

    fn markDirty(self: *Client, now_ms: i64) void {
        if (!self.dirty) {
            self.dirty = true;
            self.dirty_since_ms = now_ms;
        }
    }

    /// Milliseconds until the next scheduled refresh, or null when idle.
    pub fn nextDeadline(self: *const Client, now_ms: i64) ?i64 {
        if (!self.dirty) return null;
        return @max(0, self.dirty_since_ms + coalesce_ms - now_ms);
    }

    /// Called from the main loop; performs deferred work.
    pub fn poll(self: *Client, now_ms: i64) void {
        if (self.cleanup_path) |path| {
            self.cleanup_path = null;
            defer self.gpa.free(path);
            log.info("removing profile {s} after failed authentication", .{path});
            const msg = dbus.Message.methodCall(dest, path, settings_conn_iface, "Delete") catch return;
            if (self.conn.call(msg, 5000)) |reply| reply.deinit() else |_| {}
        }
        if (self.dirty and now_ms - self.dirty_since_ms >= coalesce_ms) self.refresh();
    }

    pub fn refresh(self: *Client) void {
        self.dirty = false;
        self.refreshInner() catch |err| {
            log.warn("refresh failed: {t}", .{err});
            self.model = .{};
        };
        if (self.on_change) |cb| cb(self.on_change_ctx);
    }

    fn setError(self: *Client, text: ?[]const u8) void {
        if (self.last_error) |e| self.gpa.free(e);
        self.last_error = if (text) |t| (self.gpa.dupe(u8, t) catch null) else null;
    }

    pub fn setErrorFmt(self: *Client, comptime fmt: []const u8, args: anytype) void {
        if (self.last_error) |e| self.gpa.free(e);
        self.last_error = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
    }

    pub fn clearError(self: *Client) void {
        self.setError(null);
    }

    fn clearPending(self: *Client) void {
        if (self.pending) |p| {
            self.gpa.free(p.ssid);
            if (p.added_path) |ap| self.gpa.free(ap);
            self.pending = null;
        }
    }

    // ---- signal handling -------------------------------------------------

    fn filter(_: ?*c.DBusConnection, msg_opt: ?*c.DBusMessage, data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
        const self: *Client = @ptrCast(@alignCast(data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
        const msg = msg_opt orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        if (c.dbus_message_get_type(msg) != c.DBUS_MESSAGE_TYPE_SIGNAL) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        self.handleSignal(msg);
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    fn handleSignal(self: *Client, msg: *c.DBusMessage) void {
        const iface = std.mem.span(c.dbus_message_get_interface(msg) orelse return);
        const member = std.mem.span(c.dbus_message_get_member(msg) orelse return);
        const path = std.mem.span(c.dbus_message_get_path(msg) orelse return);
        const now = nowMs();

        if (std.mem.eql(u8, iface, dbus.properties_iface)) {
            var r = dbus.Reader.init(msg);
            const changed = r.string() catch return;
            const interesting = [_][]const u8{ nm_iface, device_iface, wireless_iface, ap_iface, active_iface, settings_iface };
            for (interesting) |name| {
                if (std.mem.eql(u8, changed, name)) {
                    self.markDirty(now);
                    return;
                }
            }
        } else if (std.mem.eql(u8, iface, device_iface) and std.mem.eql(u8, member, "StateChanged")) {
            if (self.device_path) |dev| {
                if (std.mem.eql(u8, dev, path)) {
                    var r = dbus.Reader.init(msg);
                    const new_state = r.uint32() catch return;
                    _ = r.next();
                    _ = r.uint32() catch return;
                    _ = r.next();
                    const reason = r.uint32() catch return;
                    self.onDeviceState(new_state, reason);
                }
            }
            self.markDirty(now);
        } else if (std.mem.eql(u8, iface, wireless_iface)) {
            self.markDirty(now);
        } else if (std.mem.eql(u8, iface, nm_iface)) {
            if (std.mem.eql(u8, member, "DeviceAdded") or std.mem.eql(u8, member, "DeviceRemoved")) self.device_dirty = true;
            self.markDirty(now);
        } else if (std.mem.eql(u8, iface, settings_iface)) {
            self.markDirty(now);
        }
    }

    fn onDeviceState(self: *Client, new_state: u32, reason: u32) void {
        if (new_state == DeviceState.activated) {
            self.clearPending();
            self.setError(null);
            return;
        }
        const pending = self.pending orelse return;
        const auth_failure = reason >= reason_no_secrets and reason <= reason_supplicant_timeout;
        if (new_state == DeviceState.failed or (new_state == DeviceState.disconnected and auth_failure)) {
            log.info("activation of {s} failed (state {d}, reason {d})", .{ pending.ssid, new_state, reason });
            if (auth_failure) {
                self.setErrorFmt("Couldn't join {s}: check the password", .{pending.ssid});
            } else {
                self.setErrorFmt("Couldn't join {s}", .{pending.ssid});
            }
            if (pending.added_path) |added| {
                // The profile holds the rejected secret; drop it so the next
                // attempt asks again. Done from the main loop.
                if (self.cleanup_path) |old| self.gpa.free(old);
                self.cleanup_path = added;
                self.pending.?.added_path = null;
            }
            self.clearPending();
        }
    }

    // ---- state refresh ---------------------------------------------------

    fn findDevice(self: *Client) !void {
        if (self.device_path) |p| {
            self.gpa.free(p);
            self.device_path = null;
        }
        self.device_dirty = false;
        const reply = try dbus.getProperty(self.conn, dest, nm_path, nm_iface, "Devices");
        defer reply.deinit();
        var r = reply.reader();
        var v = try r.variant();
        var paths = try v.stringArray();
        while (paths.next()) |path| {
            const type_reply = dbus.getProperty(self.conn, dest, path, device_iface, "DeviceType") catch continue;
            defer type_reply.deinit();
            var tr = type_reply.reader();
            var tv = tr.variant() catch continue;
            const device_type = tv.uint32() catch continue;
            if (device_type == device_type_wifi) {
                self.device_path = try self.gpa.dupeSentinel(u8, path, 0);
                log.info("using Wi-Fi device {s}", .{path});
                return;
            }
        }
        log.warn("no Wi-Fi device found", .{});
    }

    fn refreshInner(self: *Client) !void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var m: Model = .{};

        m.wireless_enabled = blk: {
            const reply = try dbus.getProperty(self.conn, dest, nm_path, nm_iface, "WirelessEnabled");
            defer reply.deinit();
            var r = reply.reader();
            var v = try r.variant();
            break :blk try v.boolean();
        };

        if (self.device_dirty or self.device_path == null) try self.findDevice();
        const dev = self.device_path orelse {
            self.model = m;
            return;
        };

        // Device state and the profiles that can be activated right now.
        var available: std.ArrayList([:0]const u8) = .empty;
        {
            const reply = dbus.getAllProperties(self.conn, dest, dev, device_iface) catch |err| {
                // The device may have vanished; look again next time.
                self.device_dirty = true;
                return err;
            };
            defer reply.deinit();
            var r = reply.reader();
            var it = try r.dict();
            while (it.next()) |entry| {
                var v = entry.value;
                var val = v.variant() catch continue;
                if (std.mem.eql(u8, entry.key, "State")) {
                    m.device_state = val.uint32() catch 0;
                } else if (std.mem.eql(u8, entry.key, "AvailableConnections")) {
                    var paths = val.stringArray() catch continue;
                    while (paths.next()) |p| try available.append(a, try a.dupeSentinel(u8, p, 0));
                }
            }
        }

        var ap_paths: std.ArrayList([:0]const u8) = .empty;
        var active_ap: ?[:0]const u8 = null;
        {
            const reply = try dbus.getAllProperties(self.conn, dest, dev, wireless_iface);
            defer reply.deinit();
            var r = reply.reader();
            var it = try r.dict();
            while (it.next()) |entry| {
                var v = entry.value;
                var val = v.variant() catch continue;
                if (std.mem.eql(u8, entry.key, "AccessPoints")) {
                    var paths = val.stringArray() catch continue;
                    while (paths.next()) |p| try ap_paths.append(a, try a.dupeSentinel(u8, p, 0));
                } else if (std.mem.eql(u8, entry.key, "ActiveAccessPoint")) {
                    const p = val.string() catch continue;
                    if (!std.mem.eql(u8, p, "/")) active_ap = try a.dupeSentinel(u8, p, 0);
                }
            }
        }

        // Saved profiles, keyed by raw SSID bytes.
        var saved: std.StringHashMapUnmanaged([:0]const u8) = .empty;
        for (available.items) |conn_path| {
            const ssid = self.profileSsid(a, conn_path) catch continue;
            if (ssid) |s| try saved.put(a, s, conn_path);
        }

        var networks: std.ArrayList(Network) = .empty;
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        for (ap_paths.items) |ap_path| {
            const ap = self.readAccessPoint(a, ap_path) catch continue;
            if (ap.raw_ssid.len == 0) continue;
            const is_active = active_ap != null and std.mem.eql(u8, active_ap.?, ap_path);
            if (index.get(ap.raw_ssid)) |i| {
                const existing = &networks.items[i];
                if (ap.strength > existing.strength or is_active) {
                    existing.strength = ap.strength;
                    existing.ap_path = ap_path;
                    existing.frequency = ap.frequency;
                    existing.security = ap.security;
                }
                if (is_active) existing.active = true;
            } else {
                try index.put(a, ap.raw_ssid, networks.items.len);
                try networks.append(a, .{
                    .ssid = try sanitizeSsid(a, ap.raw_ssid),
                    .raw_ssid = ap.raw_ssid,
                    .ap_path = ap_path,
                    .strength = ap.strength,
                    .frequency = ap.frequency,
                    .security = ap.security,
                    .saved = saved.get(ap.raw_ssid),
                    .active = is_active,
                });
            }
            if (is_active) {
                m.active_ssid = networks.items[index.get(ap.raw_ssid).?].ssid;
                m.active_strength = ap.strength;
            }
        }

        // The active AP is occasionally missing from the list for a moment.
        if (active_ap != null and m.active_ssid == null) {
            if (self.readAccessPoint(a, active_ap.?)) |ap| {
                m.active_ssid = try sanitizeSsid(a, ap.raw_ssid);
                m.active_strength = ap.strength;
            } else |_| {}
        }

        std.mem.sort(Network, networks.items, {}, networkLessThan);
        m.networks = networks.items;

        m.status = if (!m.wireless_enabled)
            .disabled
        else if (m.device_state == DeviceState.activated)
            .connected
        else if (m.device_state >= DeviceState.prepare and m.device_state <= DeviceState.secondaries)
            .connecting
        else
            .disconnected;
        self.model = m;
    }

    fn networkLessThan(_: void, lhs: Network, rhs: Network) bool {
        if (lhs.active != rhs.active) return lhs.active;
        if ((lhs.saved != null) != (rhs.saved != null)) return lhs.saved != null;
        if (lhs.strength != rhs.strength) return lhs.strength > rhs.strength;
        return std.mem.lessThan(u8, lhs.ssid, rhs.ssid);
    }

    const AccessPoint = struct {
        raw_ssid: []const u8,
        strength: u8,
        frequency: u32,
        security: Security,
    };

    fn readAccessPoint(self: *Client, a: Allocator, path: [:0]const u8) !AccessPoint {
        const reply = try dbus.getAllProperties(self.conn, dest, path, ap_iface);
        defer reply.deinit();
        var ssid: []const u8 = &.{};
        var strength: u8 = 0;
        var frequency: u32 = 0;
        var flags: u32 = 0;
        var wpa: u32 = 0;
        var rsn: u32 = 0;
        var r = reply.reader();
        var it = try r.dict();
        while (it.next()) |entry| {
            var v = entry.value;
            var val = v.variant() catch continue;
            if (std.mem.eql(u8, entry.key, "Ssid")) {
                ssid = try a.dupe(u8, val.byteArray() catch continue);
            } else if (std.mem.eql(u8, entry.key, "Strength")) {
                strength = val.byte() catch 0;
            } else if (std.mem.eql(u8, entry.key, "Frequency")) {
                frequency = val.uint32() catch 0;
            } else if (std.mem.eql(u8, entry.key, "Flags")) {
                flags = val.uint32() catch 0;
            } else if (std.mem.eql(u8, entry.key, "WpaFlags")) {
                wpa = val.uint32() catch 0;
            } else if (std.mem.eql(u8, entry.key, "RsnFlags")) {
                rsn = val.uint32() catch 0;
            }
        }
        return .{ .raw_ssid = ssid, .strength = strength, .frequency = frequency, .security = classify(flags, wpa, rsn) };
    }

    /// The SSID of a saved profile, or null when it is not a Wi-Fi profile.
    fn profileSsid(self: *Client, a: Allocator, conn_path: [:0]const u8) !?[]const u8 {
        const msg = try dbus.Message.methodCall(dest, conn_path, settings_conn_iface, "GetSettings");
        const reply = try self.conn.call(msg, 5000);
        defer reply.deinit();
        var r = reply.reader();
        var sections = try r.dict();
        while (sections.next()) |section| {
            if (!std.mem.eql(u8, section.key, "802-11-wireless")) continue;
            var sv = section.value;
            var props = try sv.dict();
            while (props.next()) |prop| {
                if (!std.mem.eql(u8, prop.key, "ssid")) continue;
                var pv = prop.value;
                var val = try pv.variant();
                return try a.dupe(u8, try val.byteArray());
            }
        }
        return null;
    }

    // ---- actions ---------------------------------------------------------

    pub fn requestScan(self: *Client) void {
        const dev = self.device_path orelse return;
        const msg = dbus.Message.methodCall(dest, dev, wireless_iface, "RequestScan") catch return;
        var w = msg.writer();
        var opts = w.open(c.DBUS_TYPE_ARRAY, "{sv}");
        w.close(&opts);
        // NetworkManager rejects scans that follow another one too closely;
        // that is harmless, so the error is only logged at debug level.
        var err = dbus.Error.init();
        defer err.free();
        defer c.dbus_message_unref(msg.raw);
        if (c.dbus_connection_send_with_reply_and_block(self.conn.raw, msg.raw, 5000, err.raw())) |reply| {
            c.dbus_message_unref(reply);
        } else {
            log.debug("scan request declined: {s}", .{err.text()});
        }
    }

    pub const ConnectError = error{ UnknownNetwork, NoDevice, UnsupportedSecurity, PasswordRequired, OutOfMemory } || dbus.CallError || dbus.TypeError;

    /// Activate the saved profile for `ssid`, or create one. `password` is
    /// required for PSK/SAE networks without a saved profile.
    pub fn connect(self: *Client, ssid: []const u8, password: ?[]const u8) ConnectError!void {
        const net = self.findNetwork(ssid) orelse return error.UnknownNetwork;
        const dev = self.device_path orelse return error.NoDevice;
        self.clearPending();
        self.setError(null);

        var pending: Pending = .{ .ssid = try self.gpa.dupeSentinel(u8, ssid, 0), .added_path = null };
        errdefer self.gpa.free(pending.ssid);

        if (net.saved) |profile| {
            log.info("activating saved profile {s} for {s}", .{ profile, ssid });
            const msg = try dbus.Message.methodCall(dest, nm_path, nm_iface, "ActivateConnection");
            var w = msg.writer();
            w.objectPath(profile);
            w.objectPath(dev);
            w.objectPath(net.ap_path);
            const reply = try self.conn.call(msg, 15000);
            reply.deinit();
        } else {
            if (!net.security.canAutoCreate()) return error.UnsupportedSecurity;
            if (net.security.needsPassword() and password == null) return error.PasswordRequired;
            log.info("creating profile for {s} ({s})", .{ ssid, net.security.label() });

            const psk: ?[:0]u8 = if (password) |p| try self.gpa.dupeSentinel(u8, p, 0) else null;
            defer if (psk) |p| {
                @memset(p, 0);
                self.gpa.free(p);
            };

            const msg = try dbus.Message.methodCall(dest, nm_path, nm_iface, "AddAndActivateConnection");
            var w = msg.writer();
            var settings = w.open(c.DBUS_TYPE_ARRAY, "{sa{sv}}");
            {
                var section = settings.open(c.DBUS_TYPE_DICT_ENTRY, null);
                section.string("connection");
                var props = section.open(c.DBUS_TYPE_ARRAY, "{sv}");
                props.dictString("id", pending.ssid);
                props.dictString("type", "802-11-wireless");
                section.close(&props);
                settings.close(&section);
            }
            {
                var section = settings.open(c.DBUS_TYPE_DICT_ENTRY, null);
                section.string("802-11-wireless");
                var props = section.open(c.DBUS_TYPE_ARRAY, "{sv}");
                props.dictByteArray("ssid", net.raw_ssid);
                props.dictString("mode", "infrastructure");
                section.close(&props);
                settings.close(&section);
            }
            if (net.security.keyMgmt()) |key_mgmt| {
                var section = settings.open(c.DBUS_TYPE_DICT_ENTRY, null);
                section.string("802-11-wireless-security");
                var props = section.open(c.DBUS_TYPE_ARRAY, "{sv}");
                props.dictString("key-mgmt", key_mgmt);
                if (psk) |p| props.dictString("psk", p);
                section.close(&props);
                settings.close(&section);
            }
            w.close(&settings);
            w.objectPath(dev);
            w.objectPath(net.ap_path);

            const reply = try self.conn.call(msg, 15000);
            defer reply.deinit();
            var r = reply.reader();
            const added = try r.string();
            pending.added_path = try self.gpa.dupeSentinel(u8, added, 0);
        }
        self.pending = pending;
        self.markDirty(nowMs());
    }

    /// Deactivate whatever the Wi-Fi device is doing. NetworkManager blocks
    /// autoconnect for that profile until it is activated by hand again.
    pub fn disconnect(self: *Client) !void {
        const dev = self.device_path orelse return error.NoDevice;
        self.clearPending();
        const active = blk: {
            const reply = try dbus.getProperty(self.conn, dest, dev, device_iface, "ActiveConnection");
            defer reply.deinit();
            var r = reply.reader();
            var v = try r.variant();
            const p = try v.string();
            if (std.mem.eql(u8, p, "/")) return;
            break :blk try self.gpa.dupeSentinel(u8, p, 0);
        };
        defer self.gpa.free(active);
        log.info("deactivating {s}", .{active});
        const msg = try dbus.Message.methodCall(dest, nm_path, nm_iface, "DeactivateConnection");
        var w = msg.writer();
        w.objectPath(active);
        const reply = try self.conn.call(msg, 15000);
        reply.deinit();
        self.markDirty(nowMs());
    }

    pub fn setWirelessEnabled(self: *Client, enabled: bool) !void {
        const msg = try dbus.Message.methodCall(dest, nm_path, dbus.properties_iface, "Set");
        var w = msg.writer();
        w.string(nm_iface);
        w.string("WirelessEnabled");
        w.variantBool(enabled);
        const reply = try self.conn.call(msg, 5000);
        reply.deinit();
        self.markDirty(nowMs());
    }

    /// Delete the saved profile for `ssid`.
    pub fn forget(self: *Client, ssid: []const u8) !void {
        const net = self.findNetwork(ssid) orelse return error.UnknownNetwork;
        const profile = net.saved orelse return;
        log.info("deleting profile {s} for {s}", .{ profile, ssid });
        const msg = try dbus.Message.methodCall(dest, profile, settings_conn_iface, "Delete");
        const reply = try self.conn.call(msg, 5000);
        reply.deinit();
        self.markDirty(nowMs());
    }
};

/// Make an SSID safe to hand to Pango: valid UTF-8 without control characters.
fn sanitizeSsid(a: Allocator, raw: []const u8) ![:0]const u8 {
    const out = try a.dupeSentinel(u8, raw, 0);
    const valid = std.unicode.utf8ValidateSlice(out);
    for (out) |*b| {
        if (b.* < 0x20 or b.* == 0x7f or (!valid and b.* >= 0x80)) b.* = '?';
    }
    return out;
}

pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

test "security classification" {
    try std.testing.expectEqual(Security.open, classify(0, 0, 0));
    try std.testing.expectEqual(Security.wep, classify(ap_flag_privacy, 0, 0));
    try std.testing.expectEqual(Security.psk, classify(ap_flag_privacy, 0, 0x588));
    try std.testing.expectEqual(Security.sae, classify(ap_flag_privacy, 0, 0x488));
    try std.testing.expectEqual(Security.eap, classify(ap_flag_privacy, 0, 0x288));
    try std.testing.expectEqual(Security.owe, classify(ap_flag_privacy, 0, 0x888));
}

test "signal bars" {
    try std.testing.expectEqual(@as(u8, 0), strengthToBars(0));
    try std.testing.expectEqual(@as(u8, 1), strengthToBars(10));
    try std.testing.expectEqual(@as(u8, 2), strengthToBars(40));
    try std.testing.expectEqual(@as(u8, 3), strengthToBars(60));
    try std.testing.expectEqual(@as(u8, 4), strengthToBars(95));
}

test "ssid sanitizing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try sanitizeSsid(arena.allocator(), "caf\xc3\xa9\x01");
    try std.testing.expectEqualStrings("café?", s);
    const bad = try sanitizeSsid(arena.allocator(), "a\xffb");
    try std.testing.expectEqualStrings("a?b", bad);
}
