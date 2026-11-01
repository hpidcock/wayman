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
const settings_path = nm_path ++ "/Settings";
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

pub const VpnState = enum { off, connecting, on, disconnecting };

/// A VPN profile (NetworkManager type `vpn` or `wireguard`).
pub const Vpn = struct {
    id: [:0]const u8,
    uuid: [:0]const u8,
    /// Settings connection path.
    path: [:0]const u8,
    wireguard: bool,
    state: VpnState,
    /// Active connection path while connecting, on or disconnecting.
    active_path: ?[:0]const u8,
};

/// NMActiveConnectionStateReason values.
const active_reason_user_disconnected: u32 = 2;
const active_reason_connect_timeout: u32 = 6;
const active_reason_no_secrets: u32 = 9;
const active_reason_login_failed: u32 = 10;

pub const Model = struct {
    status: Status = .no_device,
    wireless_enabled: bool = false,
    device_state: u32 = 0,
    active_ssid: ?[:0]const u8 = null,
    active_strength: u8 = 0,
    networks: []Network = &.{},
    vpns: []Vpn = &.{},
    /// Name of the first VPN that is fully connected.
    vpn_on: ?[:0]const u8 = null,
    vpn_on_count: usize = 0,
};

const Pending = struct {
    ssid: [:0]u8,
    /// Set when the profile was created by this attempt and should be
    /// removed again if authentication fails.
    added_path: ?[:0]u8,
};

const PendingVpn = struct {
    id: [:0]u8,
    active_path: [:0]u8,
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
    pending_vpn: ?PendingVpn = null,
    /// Set when the user cancelled a secret prompt, so the resulting
    /// activation failure is not reported as an error.
    suppress_vpn_failure: bool = false,
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
        self.clearPendingVpn();
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

    fn clearPendingVpn(self: *Client) void {
        if (self.pending_vpn) |p| {
            self.gpa.free(p.id);
            self.gpa.free(p.active_path);
            self.pending_vpn = null;
        }
    }

    /// The user cancelled a credentials prompt; the activation that is
    /// about to fail because of it should not be reported.
    pub fn suppressNextVpnFailure(self: *Client) void {
        if (self.pending_vpn != null) self.suppress_vpn_failure = true;
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
        } else if (std.mem.eql(u8, iface, active_iface) and std.mem.eql(u8, member, "StateChanged")) {
            var r = dbus.Reader.init(msg);
            const state = r.uint32() catch return;
            _ = r.next();
            const reason = r.uint32() catch return;
            self.onActiveState(path, state, reason);
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

    fn onActiveState(self: *Client, path: []const u8, state: u32, reason: u32) void {
        const pending = self.pending_vpn orelse return;
        if (!std.mem.eql(u8, pending.active_path, path)) return;
        if (state == 2) {
            self.clearPendingVpn();
            self.suppress_vpn_failure = false;
            self.setError(null);
        } else if (state == 4) {
            log.info("VPN {s} deactivated (reason {d})", .{ pending.id, reason });
            if (self.suppress_vpn_failure) {
                self.suppress_vpn_failure = false;
            } else switch (reason) {
                active_reason_user_disconnected => {},
                active_reason_no_secrets => self.setErrorFmt("{s} needs credentials", .{pending.id}),
                active_reason_login_failed => self.setErrorFmt("Login to {s} failed", .{pending.id}),
                active_reason_connect_timeout => self.setErrorFmt("Connecting to {s} timed out", .{pending.id}),
                else => self.setErrorFmt("Couldn't connect {s}", .{pending.id}),
            }
            self.clearPendingVpn();
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

        try self.readVpns(a, &m);

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

    const ActiveInfo = struct { path: [:0]const u8, state: u32 };

    /// Fills `m.vpns` from every `vpn`/`wireguard` profile and the list of
    /// active connections.
    fn readVpns(self: *Client, a: Allocator, m: *Model) !void {
        var active: std.StringHashMapUnmanaged(ActiveInfo) = .empty;
        {
            const reply = try dbus.getProperty(self.conn, dest, nm_path, nm_iface, "ActiveConnections");
            defer reply.deinit();
            var r = reply.reader();
            var v = try r.variant();
            var paths = try v.stringArray();
            while (paths.next()) |p| {
                const active_path = try a.dupeSentinel(u8, p, 0);
                const info = dbus.getAllProperties(self.conn, dest, active_path, active_iface) catch continue;
                defer info.deinit();
                var ir = info.reader();
                var it = ir.dict() catch continue;
                var conn_path: ?[:0]const u8 = null;
                var state: u32 = 0;
                while (it.next()) |entry| {
                    var ev = entry.value;
                    var val = ev.variant() catch continue;
                    if (std.mem.eql(u8, entry.key, "Connection")) {
                        conn_path = try a.dupeSentinel(u8, val.string() catch continue, 0);
                    } else if (std.mem.eql(u8, entry.key, "State")) {
                        state = val.uint32() catch 0;
                    }
                }
                if (conn_path) |cp| try active.put(a, cp, .{ .path = active_path, .state = state });
            }
        }

        var vpns: std.ArrayList(Vpn) = .empty;
        {
            const msg = try dbus.Message.methodCall(dest, settings_path, settings_iface, "ListConnections");
            const reply = try self.conn.call(msg, 5000);
            defer reply.deinit();
            var r = reply.reader();
            var paths = try r.stringArray();
            while (paths.next()) |p| {
                const path = try a.dupeSentinel(u8, p, 0);
                const profile = self.readProfile(a, path) catch continue;
                const wireguard = std.mem.eql(u8, profile.kind, "wireguard");
                if (!wireguard and !std.mem.eql(u8, profile.kind, "vpn")) continue;
                const act = active.get(path);
                try vpns.append(a, .{
                    .id = profile.id,
                    .uuid = profile.uuid,
                    .path = path,
                    .wireguard = wireguard,
                    .state = if (act) |x| switch (x.state) {
                        1 => .connecting,
                        2 => .on,
                        3 => .disconnecting,
                        else => .off,
                    } else .off,
                    .active_path = if (act) |x| x.path else null,
                });
            }
        }
        std.mem.sort(Vpn, vpns.items, {}, vpnLessThan);
        m.vpns = vpns.items;
        for (vpns.items) |v| {
            if (v.state == .on) {
                m.vpn_on_count += 1;
                if (m.vpn_on == null) m.vpn_on = v.id;
            }
        }
    }

    fn vpnLessThan(_: void, lhs: Vpn, rhs: Vpn) bool {
        return std.ascii.lessThanIgnoreCase(lhs.id, rhs.id);
    }

    const Profile = struct { kind: []const u8, id: [:0]const u8, uuid: [:0]const u8 };

    /// The `connection` section of a profile.
    fn readProfile(self: *Client, a: Allocator, conn_path: [:0]const u8) !Profile {
        const msg = try dbus.Message.methodCall(dest, conn_path, settings_conn_iface, "GetSettings");
        const reply = try self.conn.call(msg, 5000);
        defer reply.deinit();
        var profile: Profile = .{ .kind = "", .id = "", .uuid = "" };
        var r = reply.reader();
        var sections = try r.dict();
        while (sections.next()) |section| {
            if (!std.mem.eql(u8, section.key, "connection")) continue;
            var sv = section.value;
            var props = try sv.dict();
            while (props.next()) |prop| {
                var pv = prop.value;
                var val = pv.variant() catch continue;
                if (std.mem.eql(u8, prop.key, "type")) {
                    profile.kind = try a.dupe(u8, val.string() catch continue);
                } else if (std.mem.eql(u8, prop.key, "id")) {
                    profile.id = try a.dupeSentinel(u8, val.string() catch continue, 0);
                } else if (std.mem.eql(u8, prop.key, "uuid")) {
                    profile.uuid = try a.dupeSentinel(u8, val.string() catch continue, 0);
                }
            }
        }
        return profile;
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

    /// Activate a VPN profile; NetworkManager picks the device.
    pub fn vpnConnect(self: *Client, index: usize) !void {
        if (index >= self.model.vpns.len) return error.UnknownVpn;
        const vpn = self.model.vpns[index];
        try self.activateProfile(vpn.path, vpn.id);
    }

    /// Activate any profile by settings path, tracking it as a pending VPN.
    pub fn activateProfile(self: *Client, path: [:0]const u8, id: []const u8) !void {
        self.clearPendingVpn();
        self.suppress_vpn_failure = false;
        self.setError(null);
        log.info("activating {s}", .{id});
        const msg = try dbus.Message.methodCall(dest, nm_path, nm_iface, "ActivateConnection");
        var w = msg.writer();
        w.objectPath(path);
        w.objectPath("/");
        w.objectPath("/");
        const reply = try self.conn.call(msg, 15000);
        defer reply.deinit();
        var r = reply.reader();
        const active_path = try r.string();
        const idz = try self.gpa.dupeSentinel(u8, id, 0);
        errdefer self.gpa.free(idz);
        self.pending_vpn = .{ .id = idz, .active_path = try self.gpa.dupeSentinel(u8, active_path, 0) };
        self.markDirty(nowMs());
    }

    pub fn findVpnByUuid(self: *const Client, uuid: []const u8) ?*const Vpn {
        for (self.model.vpns) |*v| {
            if (std.mem.eql(u8, v.uuid, uuid)) return v;
        }
        return null;
    }

    pub fn deactivateByUuid(self: *Client, uuid: []const u8) !void {
        const vpn = self.findVpnByUuid(uuid) orelse return;
        const active_path = vpn.active_path orelse return;
        self.clearPendingVpn();
        log.info("deactivating {s}", .{vpn.id});
        const msg = try dbus.Message.methodCall(dest, nm_path, nm_iface, "DeactivateConnection");
        var w = msg.writer();
        w.objectPath(active_path);
        const reply = try self.conn.call(msg, 15000);
        reply.deinit();
        self.markDirty(nowMs());
    }

    fn profilePathByUuid(self: *Client, uuid: [:0]const u8) !?[:0]u8 {
        const msg = try dbus.Message.methodCall(dest, settings_path, settings_iface, "GetConnectionByUuid");
        var w = msg.writer();
        w.string(uuid);
        const reply = self.conn.call(msg, 5000) catch return null;
        defer reply.deinit();
        var r = reply.reader();
        return try self.gpa.dupeSentinel(u8, try r.string(), 0);
    }

    pub fn deleteProfileByUuid(self: *Client, uuid: []const u8) !void {
        const uuidz = try self.gpa.dupeSentinel(u8, uuid, 0);
        defer self.gpa.free(uuidz);
        const path = (try self.profilePathByUuid(uuidz)) orelse return;
        defer self.gpa.free(path);
        log.info("deleting profile {s}", .{path});
        const msg = try dbus.Message.methodCall(dest, path, settings_conn_iface, "Delete");
        const reply = try self.conn.call(msg, 5000);
        reply.deinit();
        self.markDirty(nowMs());
    }

    pub const WireguardProfile = struct {
        uuid: []const u8,
        id: []const u8,
        interface: []const u8,
        /// Base64 X25519 private key.
        private_key: []const u8,
        /// Base64 X25519 public key of the peer.
        peer_public_key: []const u8,
        /// `ip:port`.
        endpoint: []const u8,
    };

    /// Creates or updates a WireGuard profile that routes everything through
    /// the peer (address 10.2.0.2/32, DNS 10.2.0.1). Returns its settings path.
    pub fn ensureWireguardProfile(self: *Client, p: WireguardProfile) ![:0]u8 {
        const z = struct {
            fn dup(gpa: Allocator, s: []const u8) ![:0]u8 {
                return gpa.dupeSentinel(u8, s, 0);
            }
        };
        const uuid = try z.dup(self.gpa, p.uuid);
        defer self.gpa.free(uuid);
        const id = try z.dup(self.gpa, p.id);
        defer self.gpa.free(id);
        const iface_name = try z.dup(self.gpa, p.interface);
        defer self.gpa.free(iface_name);
        const key = try z.dup(self.gpa, p.private_key);
        defer {
            @memset(key, 0);
            self.gpa.free(key);
        }
        const peer_key = try z.dup(self.gpa, p.peer_public_key);
        defer self.gpa.free(peer_key);
        const endpoint = try z.dup(self.gpa, p.endpoint);
        defer self.gpa.free(endpoint);

        const existing = try self.profilePathByUuid(uuid);
        defer if (existing) |e| self.gpa.free(e);

        const msg = if (existing) |path|
            try dbus.Message.methodCall(dest, path, settings_conn_iface, "Update")
        else
            try dbus.Message.methodCall(dest, settings_path, settings_iface, "AddConnection");
        var w = msg.writer();
        var settings = w.open(c.DBUS_TYPE_ARRAY, "{sa{sv}}");
        {
            var section = settings.open(c.DBUS_TYPE_DICT_ENTRY, null);
            section.string("connection");
            var props = section.open(c.DBUS_TYPE_ARRAY, "{sv}");
            props.dictString("id", id);
            props.dictString("uuid", uuid);
            props.dictString("type", "wireguard");
            props.dictString("interface-name", iface_name);
            props.dictBool("autoconnect", false);
            section.close(&props);
            settings.close(&section);
        }
        {
            var section = settings.open(c.DBUS_TYPE_DICT_ENTRY, null);
            section.string("wireguard");
            var props = section.open(c.DBUS_TYPE_ARRAY, "{sv}");
            props.dictString("private-key", key);
            var peers_entry = props.open(c.DBUS_TYPE_DICT_ENTRY, null);
            peers_entry.string("peers");
            var peers_variant = peers_entry.open(c.DBUS_TYPE_VARIANT, "aa{sv}");
            var peers = peers_variant.open(c.DBUS_TYPE_ARRAY, "a{sv}");
            var peer = peers.open(c.DBUS_TYPE_ARRAY, "{sv}");
            peer.dictString("public-key", peer_key);
            peer.dictString("endpoint", endpoint);
            peer.dictStringArray("allowed-ips", &.{"0.0.0.0/0"});
            peer.dictUint32("persistent-keepalive", 25);
            peers.close(&peer);
            peers_variant.close(&peers);
            peers_entry.close(&peers_variant);
            props.close(&peers_entry);
            section.close(&props);
            settings.close(&section);
        }
        {
            var section = settings.open(c.DBUS_TYPE_DICT_ENTRY, null);
            section.string("ipv4");
            var props = section.open(c.DBUS_TYPE_ARRAY, "{sv}");
            props.dictString("method", "manual");
            var addr_entry = props.open(c.DBUS_TYPE_DICT_ENTRY, null);
            addr_entry.string("address-data");
            var addr_variant = addr_entry.open(c.DBUS_TYPE_VARIANT, "aa{sv}");
            var addrs = addr_variant.open(c.DBUS_TYPE_ARRAY, "a{sv}");
            var addr = addrs.open(c.DBUS_TYPE_ARRAY, "{sv}");
            addr.dictString("address", "10.2.0.2");
            addr.dictUint32("prefix", 32);
            addrs.close(&addr);
            addr_variant.close(&addrs);
            addr_entry.close(&addr_variant);
            props.close(&addr_entry);
            // DNS servers are `au` in the in-memory (native) byte order of
            // the address bytes, as inet_aton produces them.
            var dns_entry = props.open(c.DBUS_TYPE_DICT_ENTRY, null);
            dns_entry.string("dns");
            var dns_variant = dns_entry.open(c.DBUS_TYPE_VARIANT, "au");
            var dns = dns_variant.open(c.DBUS_TYPE_ARRAY, "u");
            dns.uint32(std.mem.readInt(u32, &[4]u8{ 10, 2, 0, 1 }, @import("builtin").cpu.arch.endian()));
            dns_variant.close(&dns);
            dns_entry.close(&dns_variant);
            props.close(&dns_entry);
            props.dictStringArray("dns-search", &.{"~"});
            props.dictInt32("dns-priority", -1500);
            props.dictBool("ignore-auto-dns", true);
            section.close(&props);
            settings.close(&section);
        }
        {
            var section = settings.open(c.DBUS_TYPE_DICT_ENTRY, null);
            section.string("ipv6");
            var props = section.open(c.DBUS_TYPE_ARRAY, "{sv}");
            props.dictString("method", "disabled");
            section.close(&props);
            settings.close(&section);
        }
        w.close(&settings);

        const reply = try self.conn.call(msg, 10000);
        defer reply.deinit();
        if (existing) |path| {
            log.info("updated WireGuard profile {s}", .{path});
            self.markDirty(nowMs());
            return try self.gpa.dupeSentinel(u8, path, 0);
        }
        var r = reply.reader();
        const path = try r.string();
        log.info("created WireGuard profile {s}", .{path});
        self.markDirty(nowMs());
        return try self.gpa.dupeSentinel(u8, path, 0);
    }

    pub fn vpnDisconnect(self: *Client, index: usize) !void {
        if (index >= self.model.vpns.len) return error.UnknownVpn;
        const vpn = self.model.vpns[index];
        const active_path = vpn.active_path orelse return;
        self.clearPendingVpn();
        log.info("deactivating VPN {s}", .{vpn.id});
        const msg = try dbus.Message.methodCall(dest, nm_path, nm_iface, "DeactivateConnection");
        var w = msg.writer();
        w.objectPath(active_path);
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
