// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! Date and time: formatting for the bar label, the system time zone via
//! systemd's timedated, and the analogue clock face.
const std = @import("std");
const c = @import("c");
const dbus = @import("dbus.zig");
const icon = @import("icon.zig");

const log = std.log.scoped(.clock);
const Allocator = std.mem.Allocator;
const Color = icon.Color;

pub const default_format = "%a %-d %b  %H:%M";

const td_dest = "org.freedesktop.timedate1";
const td_path = "/org/freedesktop/timedate1";
const td_iface = "org.freedesktop.timedate1";

pub fn epochSeconds() i64 {
    return @intCast(c.time(null));
}

/// Milliseconds into the current second, from the real-time clock.
pub fn msIntoSecond() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

pub fn localParts(t: i64) c.struct_tm {
    var tm: c.struct_tm = undefined;
    const tt: c.time_t = @intCast(t);
    _ = c.localtime_r(&tt, &tm);
    return tm;
}

/// strftime into `buf`; returns the formatted text.
pub fn format(buf: []u8, fmt: [*:0]const u8, tm: *const c.struct_tm) []const u8 {
    const n = c.strftime(buf.ptr, buf.len, fmt, tm);
    return buf[0..n];
}

/// True when the format shows seconds, so the label must tick every second.
pub fn showsSeconds(fmt: []const u8) bool {
    const specs = [_][]const u8{ "%S", "%T", "%X", "%c", "%r", "%s", "%+" };
    for (specs) |s| {
        if (std.mem.indexOf(u8, fmt, s) != null) return true;
    }
    return false;
}

/// "UTC+05:30" for the offset of `tm`.
pub fn utcOffset(buf: []u8, tm: *const c.struct_tm) []const u8 {
    const off: i64 = tm.tm_gmtoff;
    const sign: u8 = if (off < 0) '-' else '+';
    const abs: u64 = @intCast(if (off < 0) -off else off);
    return std.fmt.bufPrint(buf, "UTC{c}{d:0>2}:{d:0>2}", .{ sign, abs / 3600, (abs % 3600) / 60 }) catch "UTC";
}

/// Makes libc follow a zone change immediately: glibc only re-reads
/// /etc/localtime when `TZ` changes.
pub fn applyZone(zone: [:0]const u8) void {
    var buf: [256]u8 = undefined;
    const value = std.fmt.bufPrintSentinel(&buf, ":/usr/share/zoneinfo/{s}", .{zone}, 0) catch return;
    _ = c.setenv("TZ", value, 1);
    c.tzset();
}

pub const ChangeFn = *const fn (?*anyopaque) void;

/// Client for org.freedesktop.timedate1 on the system bus.
pub const Timedate = struct {
    gpa: Allocator,
    conn: dbus.Connection,
    zone: [:0]u8,
    zones: ?[][:0]u8 = null,
    on_change: ?ChangeFn = null,
    on_change_ctx: ?*anyopaque = null,

    pub fn init(self: *Timedate, gpa: Allocator, conn: dbus.Connection) !void {
        self.* = .{ .gpa = gpa, .conn = conn, .zone = try gpa.dupeSentinel(u8, "UTC", 0) };
        errdefer gpa.free(self.zone);
        self.refreshZone();
        try conn.addMatch("type='signal',sender='org.freedesktop.timedate1',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'");
        try conn.addFilter(filter, self);
    }

    pub fn deinit(self: *Timedate) void {
        self.gpa.free(self.zone);
        self.freeZones();
    }

    fn freeZones(self: *Timedate) void {
        if (self.zones) |zs| {
            for (zs) |z| self.gpa.free(z);
            self.gpa.free(zs);
            self.zones = null;
        }
    }

    fn filter(_: ?*c.DBusConnection, msg_opt: ?*c.DBusMessage, data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
        const self: *Timedate = @ptrCast(@alignCast(data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
        const msg = msg_opt orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        if (c.dbus_message_is_signal(msg, dbus.properties_iface, "PropertiesChanged") != 0) {
            const path = std.mem.span(c.dbus_message_get_path(msg) orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED);
            if (std.mem.eql(u8, path, td_path)) {
                self.refreshZone();
                if (self.on_change) |cb| cb(self.on_change_ctx);
            }
        }
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    /// Re-reads the system zone and makes libc use it.
    pub fn refreshZone(self: *Timedate) void {
        const reply = dbus.getProperty(self.conn, td_dest, td_path, td_iface, "Timezone") catch return;
        defer reply.deinit();
        var r = reply.reader();
        var v = r.variant() catch return;
        const zone = v.string() catch return;
        if (std.mem.eql(u8, zone, self.zone)) return;
        const copy = self.gpa.dupeSentinel(u8, zone, 0) catch return;
        const first = std.mem.eql(u8, self.zone, "UTC") and self.zones == null;
        self.gpa.free(self.zone);
        self.zone = copy;
        applyZone(self.zone);
        if (first) log.debug("system time zone is {s}", .{self.zone}) else log.info("system time zone changed to {s}", .{self.zone});
    }

    /// All zones timedated knows, sorted; fetched once.
    pub fn listZones(self: *Timedate) ![]const [:0]u8 {
        if (self.zones) |zs| return zs;
        const msg = try dbus.Message.methodCall(td_dest, td_path, td_iface, "ListTimezones");
        const reply = try self.conn.call(msg, 10000);
        defer reply.deinit();
        var list: std.ArrayList([:0]u8) = .empty;
        errdefer {
            for (list.items) |z| self.gpa.free(z);
            list.deinit(self.gpa);
        }
        var r = reply.reader();
        var it = try r.stringArray();
        while (it.next()) |z| try list.append(self.gpa, try self.gpa.dupeSentinel(u8, z, 0));
        std.mem.sort([:0]u8, list.items, {}, zoneLessThan);
        self.zones = try list.toOwnedSlice(self.gpa);
        return self.zones.?;
    }

    fn zoneLessThan(_: void, a: [:0]u8, b: [:0]u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    /// Sets the system zone through timedated (polkit may ask for
    /// authentication). Returns an error message on failure.
    pub fn setZone(self: *Timedate, zone: [:0]const u8) ?[]const u8 {
        const msg = dbus.Message.methodCall(td_dest, td_path, td_iface, "SetTimezone") catch return "out of memory";
        var w = msg.writer();
        w.string(zone);
        w.boolean(true);
        defer c.dbus_message_unref(msg.raw);
        var err = dbus.Error.init();
        defer err.free();
        if (c.dbus_connection_send_with_reply_and_block(self.conn.raw, msg.raw, 60_000, err.raw())) |reply| {
            c.dbus_message_unref(reply);
            log.info("system time zone set to {s}", .{zone});
            self.refreshZone();
            return null;
        }
        const name = err.nameText();
        log.warn("SetTimezone failed: {s}: {s}", .{ name, err.text() });
        if (std.mem.indexOf(u8, name, "InteractiveAuthorizationRequired") != null or std.mem.indexOf(u8, name, "NotAuthorized") != null or std.mem.indexOf(u8, err.text(), "authenticat") != null) {
            return "Not authorised to change the time zone; is a polkit agent running?";
        }
        return "Couldn't change the time zone";
    }
};

/// Draws an analogue clock face centred on (cx, cy).
pub fn drawFace(cr: *c.cairo_t, cx: f64, cy: f64, radius: f64, tm: *const c.struct_tm, face: Color, ticks: Color, hands: Color, accent: Color) void {
    const pi = std.math.pi;
    icon.setColor(cr, face);
    c.cairo_arc(cr, cx, cy, radius, 0, 2 * pi);
    c.cairo_fill(cr);

    // Hour and minute ticks.
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const angle = @as(f64, @floatFromInt(i)) * pi / 30.0;
        const major = i % 5 == 0;
        const len: f64 = if (major) radius * 0.12 else radius * 0.05;
        icon.setColor(cr, if (major) ticks else ticks.withAlpha(ticks.a * 0.5));
        c.cairo_set_line_width(cr, if (major) 2.0 else 1.0);
        c.cairo_move_to(cr, cx + @sin(angle) * (radius - len - 4), cy - @cos(angle) * (radius - len - 4));
        c.cairo_line_to(cr, cx + @sin(angle) * (radius - 4), cy - @cos(angle) * (radius - 4));
        c.cairo_stroke(cr);
    }

    const sec: f64 = @floatFromInt(tm.tm_sec);
    const min: f64 = @as(f64, @floatFromInt(tm.tm_min)) + sec / 60.0;
    const hour: f64 = @as(f64, @floatFromInt(@mod(tm.tm_hour, 12))) + min / 60.0;

    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    hand(cr, cx, cy, hour * pi / 6.0, radius * 0.52, 5.0, hands);
    hand(cr, cx, cy, min * pi / 30.0, radius * 0.78, 3.5, hands);
    hand(cr, cx, cy, sec * pi / 30.0, radius * 0.85, 1.2, accent);
    icon.setColor(cr, accent);
    c.cairo_arc(cr, cx, cy, 3.5, 0, 2 * pi);
    c.cairo_fill(cr);
}

fn hand(cr: *c.cairo_t, cx: f64, cy: f64, angle: f64, len: f64, width: f64, col: Color) void {
    icon.setColor(cr, col);
    c.cairo_set_line_width(cr, width);
    c.cairo_move_to(cr, cx - @sin(angle) * len * 0.15, cy + @cos(angle) * len * 0.15);
    c.cairo_line_to(cr, cx + @sin(angle) * len, cy - @cos(angle) * len);
    c.cairo_stroke(cr);
}

test "seconds detection" {
    try std.testing.expect(showsSeconds("%H:%M:%S"));
    try std.testing.expect(showsSeconds("%T"));
    try std.testing.expect(!showsSeconds(default_format));
}

test "utc offset text" {
    var tm: c.struct_tm = .{};
    tm.tm_gmtoff = -5 * 3600;
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("UTC-05:00", utcOffset(&buf, &tm));
    tm.tm_gmtoff = 5 * 3600 + 1800;
    try std.testing.expectEqualStrings("UTC+05:30", utcOffset(&buf, &tm));
}
