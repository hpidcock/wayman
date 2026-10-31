// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! wayman: a Wi-Fi tray item and popup for sway/wlroots compositors.
//!
//! One process, one thread, one poll loop over three file descriptors: the
//! Wayland display, the system bus (NetworkManager) and the session bus
//! (StatusNotifierItem for the bar's tray).
const std = @import("std");
const dbus = @import("dbus.zig");
const nm = @import("nm.zig");
const sni = @import("sni.zig");
const wl = @import("wl.zig");
const ui = @import("ui.zig");
const icon = @import("icon.zig");

const log = std.log.scoped(.wayman);

pub const std_options: std.Options = .{
    .log_level = if (@import("builtin").mode == .debug) .debug else .info,
};

/// How often to ask for a scan while the popup is open.
const scan_interval_ms: i64 = 15_000;

const App = struct {
    gpa: std.mem.Allocator,
    system: dbus.Connection,
    session: dbus.Connection,
    wl: wl.Client,
    nm: nm.Client,
    tray: sni.Item,
    ui: ui.Ui,
    next_scan_ms: i64 = 0,
    icon_key: u32 = std.math.maxInt(u32),
    quit: bool = false,

    fn fromCtx(ctx: ?*anyopaque) *App {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn fromPtr(ctx: *anyopaque) *App {
        return @ptrCast(@alignCast(ctx));
    }

    // ---- NetworkManager -> tray -------------------------------------------

    fn onNmChange(ctx: ?*anyopaque) void {
        const app = fromCtx(ctx);
        app.updateTray();
        app.ui.onModelChanged();
    }

    fn updateTray(app: *App) void {
        const m = app.nm.model;
        const look: icon.Look = switch (m.status) {
            .connected => .connected,
            .connecting => .connecting,
            .disconnected, .no_device => .disconnected,
            .disabled => .off,
        };
        const bars: u8 = if (m.status == .connected) nm.strengthToBars(m.active_strength) else 0;
        const key = @as(u32, bars) | (@as(u32, @backingInt(look)) << 8);
        if (key != app.icon_key) {
            if (app.renderIcons(bars, look)) |pixmaps| {
                app.tray.setIcon(pixmaps);
                app.icon_key = key;
            } else |err| {
                log.warn("cannot render the tray icon: {t}", .{err});
            }
        }

        var buf: [320]u8 = undefined;
        const ssid = m.active_ssid orelse "Wi-Fi";
        const text: []const u8 = switch (m.status) {
            .connected => std.fmt.bufPrint(&buf, "Connected to {s} ({d}%)", .{ ssid, m.active_strength }) catch "Connected",
            .connecting => std.fmt.bufPrint(&buf, "Connecting to {s}\u{2026}", .{ssid}) catch "Connecting",
            .disconnected => "Not connected",
            .disabled => "Wi-Fi is off",
            .no_device => "No Wi-Fi device",
        };
        app.tray.setTooltip("Wi-Fi", text) catch |err| log.warn("cannot update the tooltip: {t}", .{err});
    }

    fn renderIcons(app: *App, bars: u8, look: icon.Look) ![]sni.Pixmap {
        const sizes = [_]u32{ 16, 22, 24, 32, 48 };
        const pixmaps = try app.gpa.alloc(sni.Pixmap, sizes.len);
        var done: usize = 0;
        errdefer {
            for (pixmaps[0..done]) |p| app.gpa.free(p.data);
            app.gpa.free(pixmaps);
        }
        for (sizes, 0..) |size, i| {
            pixmaps[i] = .{ .size = size, .data = try icon.renderTrayPixmap(app.gpa, size, bars, look) };
            done += 1;
        }
        return pixmaps;
    }

    // ---- tray -> popup ----------------------------------------------------

    fn onActivate(ctx: ?*anyopaque) void {
        fromCtx(ctx).ui.toggle();
    }

    /// Right click on the tray icon quits wayman.
    fn onContextMenu(ctx: ?*anyopaque) void {
        log.info("quit requested from the tray icon", .{});
        fromCtx(ctx).quit = true;
    }

    // ---- Wayland -> popup -------------------------------------------------

    fn onPointerMotion(ctx: *anyopaque, x: f64, y: f64) void {
        fromPtr(ctx).ui.onPointerMotion(x, y);
    }

    fn onPointerLeave(ctx: *anyopaque) void {
        fromPtr(ctx).ui.onPointerLeave();
    }

    fn onPointerButton(ctx: *anyopaque, button: u32, pressed: bool) void {
        fromPtr(ctx).ui.onPointerButton(button, pressed);
    }

    fn onAxis(ctx: *anyopaque, dy: f64) void {
        fromPtr(ctx).ui.onAxis(dy);
    }

    fn onKey(ctx: *anyopaque, sym: u32, text: []const u8, mods: wl.Modifiers) void {
        fromPtr(ctx).ui.onKey(sym, text, mods);
    }

    fn onDismiss(ctx: *anyopaque) void {
        fromPtr(ctx).ui.onDismiss();
    }

    fn onPopupReady(ctx: *anyopaque) void {
        fromPtr(ctx).ui.onPopupReady();
    }

    fn onPopupClosed(ctx: *anyopaque) void {
        fromPtr(ctx).ui.onPopupClosed();
    }

    // ---- main loop --------------------------------------------------------

    fn run(app: *App) !void {
        const POLL = std.posix.POLL;
        var fds = [_]std.posix.pollfd{
            .{ .fd = app.wl.fd(), .events = POLL.IN, .revents = 0 },
            .{ .fd = try app.system.fd(), .events = POLL.IN, .revents = 0 },
            .{ .fd = try app.session.fd(), .events = POLL.IN, .revents = 0 },
        };

        while (true) {
            const now = nm.nowMs();
            // Deferred NetworkManager work: coalesced refreshes, cleanups.
            app.nm.poll(now);
            if (app.ui.open and now >= app.next_scan_ms) {
                app.nm.requestScan();
                app.next_scan_ms = now + scan_interval_ms;
            }
            // Draw after state changes and before handling more input, so
            // click targets always match what is on screen.
            if (app.ui.needs_redraw and app.wl.popupReady()) app.ui.render();

            var timeout: i32 = -1;
            if (app.nm.nextDeadline(now)) |d| timeout = @intCast(@min(d, std.math.maxInt(i32)));
            if (app.ui.open) {
                const until_scan: i32 = @intCast(@max(0, @min(app.next_scan_ms - now, std.math.maxInt(i32))));
                timeout = if (timeout < 0) until_scan else @min(timeout, until_scan);
            }

            app.wl.prepare();
            app.system.flush();
            app.session.flush();
            for (&fds) |*p| p.revents = 0;
            _ = std.posix.poll(&fds, timeout) catch |err| {
                app.wl.finish(false) catch {};
                log.err("poll failed: {t}", .{err});
                return err;
            };

            try app.wl.finish((fds[0].revents & POLL.IN) != 0);
            if ((fds[0].revents & (POLL.HUP | POLL.ERR)) != 0) {
                log.err("lost the Wayland connection", .{});
                return error.WaylandDisconnected;
            }
            app.system.dispatch();
            app.session.dispatch();
            if (app.quit) {
                app.ui.close();
                app.session.flush();
                return;
            }
            if (!app.system.isConnected()) {
                log.err("lost the system bus connection", .{});
                return error.SystemBusDisconnected;
            }
            if (!app.session.isConnected()) {
                log.err("lost the session bus connection", .{});
                return error.SessionBusDisconnected;
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.* = .{
        .gpa = gpa,
        .system = undefined,
        .session = undefined,
        .wl = undefined,
        .nm = undefined,
        .tray = undefined,
        .ui = undefined,
    };

    app.system = try dbus.Connection.open(.system);
    defer app.system.close();
    app.session = try dbus.Connection.open(.session);
    defer app.session.close();

    try app.wl.init(gpa, .{
        .ctx = app,
        .pointer_motion = App.onPointerMotion,
        .pointer_leave = App.onPointerLeave,
        .pointer_button = App.onPointerButton,
        .axis = App.onAxis,
        .key = App.onKey,
        .dismiss = App.onDismiss,
        .popup_ready = App.onPopupReady,
        .popup_closed = App.onPopupClosed,
    });
    defer app.wl.deinit();

    try app.nm.init(gpa, app.system);
    defer app.nm.deinit();
    app.nm.on_change = App.onNmChange;
    app.nm.on_change_ctx = app;

    try app.tray.init(gpa, app.session, App.onActivate, app);
    defer app.tray.deinit();
    app.tray.on_context_menu = App.onContextMenu;

    app.ui.init(gpa, &app.wl, &app.nm);
    defer app.ui.deinit();

    app.nm.refresh();
    log.info("wayman is running; click the tray icon to open the popup", .{});
    try app.run();
}

test {
    std.testing.refAllDecls(@This());
    _ = nm;
    _ = icon;
}
