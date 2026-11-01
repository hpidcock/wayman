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
const agent = @import("agent.zig");
const proton = @import("proton.zig");
const portal = @import("portal.zig");
const clock = @import("clock.zig");
const control = @import("control.zig");
const Theme = @import("theme.zig").Theme;

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
    agent: agent.Agent,
    proton: proton.Client,
    portal: portal.Detector,
    timedate: clock.Timedate,
    control: control.Server,
    theme: Theme,
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
        const m = app.nm.model;
        app.portal.onNetwork(if (m.status == .connected) m.active_ssid else null, nm.nowMs());
        app.updateTray();
        app.ui.onModelChanged();
    }

    fn onPortalChange(ctx: ?*anyopaque) void {
        const app = fromCtx(ctx);
        app.updateTray();
        app.ui.onModelChanged();
    }

    fn onTimedateChange(ctx: ?*anyopaque) void {
        fromCtx(ctx).ui.onModelChanged();
    }

    fn onControl(ctx: ?*anyopaque, action: control.Action) void {
        const app = fromCtx(ctx);
        switch (action) {
            .toggle_wifi => app.ui.toggle(),
            .toggle_clock => app.ui.toggleClock(),
            .quit => {
                log.info("quit requested over D-Bus", .{});
                app.quit = true;
            },
        }
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
        const vpn_badge = m.vpn_on_count > 0;
        const key = @as(u32, bars) | (@as(u32, @backingInt(look)) << 8) | (@as(u32, @intFromBool(vpn_badge)) << 16);
        if (key != app.icon_key) {
            if (app.renderIcons(bars, look, vpn_badge)) |pixmaps| {
                app.tray.setIcon(pixmaps);
                app.icon_key = key;
            } else |err| {
                log.warn("cannot render the tray icon: {t}", .{err});
            }
        }

        var buf: [320]u8 = undefined;
        const ssid = m.active_ssid orelse "Wi-Fi";
        const wifi_text: []const u8 = switch (m.status) {
            .connected => if (app.portal.blocked())
                std.fmt.bufPrint(&buf, "{s} needs a sign-in ({d}%)", .{ ssid, m.active_strength }) catch "Sign-in needed"
            else
                std.fmt.bufPrint(&buf, "Connected to {s} ({d}%)", .{ ssid, m.active_strength }) catch "Connected",
            .connecting => std.fmt.bufPrint(&buf, "Connecting to {s}\u{2026}", .{ssid}) catch "Connecting",
            .disconnected => "Not connected",
            .disabled => "Wi-Fi is off",
            .no_device => "No Wi-Fi device",
        };
        var full: [512]u8 = undefined;
        const text: []const u8 = if (m.vpn_on) |vpn|
            std.fmt.bufPrint(&full, "{s}\nVPN: {s}", .{ wifi_text, vpn }) catch wifi_text
        else
            wifi_text;
        app.tray.setTooltip("Wi-Fi", text) catch |err| log.warn("cannot update the tooltip: {t}", .{err});
    }

    fn renderIcons(app: *App, bars: u8, look: icon.Look, vpn_badge: bool) ![]sni.Pixmap {
        const sizes = [_]u32{ 16, 22, 24, 32, 48 };
        const pixmaps = try app.gpa.alloc(sni.Pixmap, sizes.len);
        var done: usize = 0;
        errdefer {
            for (pixmaps[0..done]) |p| app.gpa.free(p.data);
            app.gpa.free(pixmaps);
        }
        for (sizes, 0..) |size, i| {
            pixmaps[i] = .{ .size = size, .data = try icon.renderTrayPixmap(app.gpa, size, bars, look, app.theme.tray, vpn_badge) };
            done += 1;
        }
        return pixmaps;
    }

    // ---- tray -> popup ----------------------------------------------------

    fn onActivate(ctx: ?*anyopaque) void {
        fromCtx(ctx).ui.toggle();
    }

    // ---- secret agent -> popup --------------------------------------------

    fn onAgentRequest(ctx: ?*anyopaque, req: *agent.Request) void {
        fromCtx(ctx).ui.showAgentPrompt(req);
    }

    fn onAgentCancel(ctx: ?*anyopaque, req: *agent.Request) void {
        fromCtx(ctx).ui.agentRequestCancelled(req);
    }

    fn onProtonChange(ctx: ?*anyopaque) void {
        fromCtx(ctx).ui.onModelChanged();
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
            .{ .fd = app.proton.fd(), .events = POLL.IN, .revents = 0 },
            .{ .fd = app.portal.fd(), .events = POLL.IN, .revents = 0 },
        };

        while (true) {
            const now = nm.nowMs();
            // Deferred NetworkManager work: coalesced refreshes, cleanups.
            app.nm.poll(now);
            app.portal.poll(now);
            app.ui.tick();
            if (app.ui.open and now >= app.next_scan_ms) {
                app.nm.requestScan();
                app.next_scan_ms = now + scan_interval_ms;
            }
            // Draw after state changes and before handling more input, so
            // click targets always match what is on screen.
            if (app.ui.needs_redraw and app.wl.popupReady()) app.ui.render();

            var timeout: i32 = -1;
            if (app.nm.nextDeadline(now)) |d| timeout = @intCast(@min(d, std.math.maxInt(i32)));
            if (app.portal.nextDeadline(now)) |d| {
                const until: i32 = @intCast(@min(d, std.math.maxInt(i32)));
                timeout = if (timeout < 0) until else @min(timeout, until);
            }
            if (app.ui.clockOpen()) {
                const until: i32 = @intCast(@max(10, 1000 - clock.msIntoSecond()));
                timeout = if (timeout < 0) until else @min(timeout, until);
            }
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
            if ((fds[3].revents & POLL.IN) != 0) app.proton.poll();
            if ((fds[4].revents & POLL.IN) != 0) app.portal.poll(nm.nowMs());
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

const usage =
    \\Usage: wayman [options]              run the daemon (tray icon and popups)
    \\       wayman toggle                 open or close the Wi-Fi popup
    \\       wayman clock toggle           open or close the clock popup
    \\       wayman clock status [--format FMT]
    \\                                     stream the date/time label for a
    \\                                     waybar custom module (JSON lines)
    \\       wayman quit                   stop the running daemon
    \\
    \\A Wi-Fi tray icon, clock and popups for sway and other wlroots compositors.
    \\
    \\Options:
    \\  --style PATH       Load colours and fonts from this CSS file
    \\                     (same subset as waybar's style.css).
    \\  --no-waybar-theme  Use the built-in theme instead of waybar's.
    \\  -h, --help         Show this help.
    \\  --version          Show the version.
    \\
;

const Options = struct {
    style: ?[]const u8 = null,
    use_waybar_theme: bool = true,
};

fn parseArgs(args: std.process.Args, init: std.process.Init) !Options {
    var opts: Options = .{};
    var it = args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "toggle")) {
            std.process.exit(if (sendOrComplain(.toggle_wifi)) 0 else 1);
        } else if (std.mem.eql(u8, arg, "quit")) {
            std.process.exit(if (sendOrComplain(.quit)) 0 else 1);
        } else if (std.mem.eql(u8, arg, "clock")) {
            const sub = it.next() orelse "status";
            if (std.mem.eql(u8, sub, "toggle")) {
                std.process.exit(if (sendOrComplain(.toggle_clock)) 0 else 1);
            } else if (std.mem.eql(u8, sub, "status")) {
                var fmt: []const u8 = clock.default_format;
                while (it.next()) |a| {
                    if (std.mem.startsWith(u8, a, "--format=")) {
                        fmt = a["--format=".len..];
                    } else if (std.mem.eql(u8, a, "--format")) {
                        fmt = it.next() orelse fmt;
                    } else {
                        std.debug.print("unknown option: {s}\n{s}", .{ a, usage });
                        std.process.exit(2);
                    }
                }
                try runClockStatus(init, fmt);
                std.process.exit(0);
            } else {
                std.debug.print("unknown clock command: {s}\n{s}", .{ sub, usage });
                std.process.exit(2);
            }
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("wayman 0.1.0\n", .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--no-waybar-theme")) {
            opts.use_waybar_theme = false;
        } else if (std.mem.startsWith(u8, arg, "--style=")) {
            opts.style = arg["--style=".len..];
        } else if (std.mem.eql(u8, arg, "--style")) {
            opts.style = it.next() orelse {
                std.debug.print("--style needs a path\n{s}", .{usage});
                std.process.exit(2);
            };
        } else {
            std.debug.print("unknown option: {s}\n{s}", .{ arg, usage });
            std.process.exit(2);
        }
    }
    return opts;
}

fn sendOrComplain(action: control.Action) bool {
    if (control.send(action)) return true;
    std.debug.print("wayman is not running\n", .{});
    return false;
}

const Label = struct { text: []const u8, tooltip: []const u8, class: []const u8 = "clock" };

/// `wayman clock status`: prints a JSON line for waybar whenever the label
/// changes, following system time zone changes.
fn runClockStatus(init: std.process.Init, fmt_text: []const u8) !void {
    const gpa = init.gpa;
    const fmt = try gpa.dupeSentinel(u8, fmt_text, 0);
    defer gpa.free(fmt);
    const per_second = clock.showsSeconds(fmt);

    // Follow zone changes when the system bus is reachable.
    var td: ?clock.Timedate = null;
    var td_fd: ?std.posix.fd_t = null;
    const sys = dbus.Connection.open(.system) catch null;
    if (sys) |conn| {
        // Initialise into a plain value first: unwrapping an optional that
        // was assigned `undefined` reads an undefined null tag.
        var tmp: clock.Timedate = undefined;
        if (tmp.init(gpa, conn)) {
            td = tmp;
            td_fd = conn.fd() catch null;
        } else |_| {}
    }
    defer if (td) |*t| t.deinit();

    var stdout_buf: [1024]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    var last: ?[]u8 = null;
    defer if (last) |l| gpa.free(l);

    while (true) {
        const now = clock.epochSeconds();
        const tm = clock.localParts(now);
        var tbuf: [256]u8 = undefined;
        const text = clock.format(&tbuf, fmt, &tm);
        var tipbuf: [256]u8 = undefined;
        var obuf: [16]u8 = undefined;
        const date = clock.format(&tipbuf, "%A, %-d %B %Y  %H:%M:%S", &tm);
        var full: [400]u8 = undefined;
        const tooltip = std.fmt.bufPrint(&full, "{s}\n{s} ({s})", .{ date, if (td) |t| t.zone else "local time", clock.utcOffset(&obuf, &tm) }) catch date;
        if (last == null or !std.mem.eql(u8, last.?, text) or per_second) {
            const line = try std.json.Stringify.valueAlloc(gpa, Label{ .text = text, .tooltip = tooltip }, .{});
            defer gpa.free(line);
            // Waybar closing the pipe is the normal way for this loop to end.
            stdout.interface.writeAll(line) catch std.process.exit(0);
            stdout.interface.writeByte('\n') catch std.process.exit(0);
            stdout.interface.flush() catch std.process.exit(0);
            if (last) |l| gpa.free(l);
            last = try gpa.dupe(u8, text);
        }
        // Sleep to the next second or minute boundary.
        const ms_in = clock.msIntoSecond();
        var wait_ms: i32 = @intCast(1000 - ms_in + 20);
        if (!per_second) wait_ms += @intCast((59 - @mod(tm.tm_sec, 60)) * 1000);
        if (td_fd) |fd| {
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            _ = std.posix.poll(&fds, wait_ms) catch {};
            sys.?.dispatch();
            sys.?.flush();
        } else {
            var fds = [_]std.posix.pollfd{};
            _ = std.posix.poll(&fds, wait_ms) catch {};
        }
    }
}

fn loadTheme(gpa: std.mem.Allocator, init: std.process.Init, opts: Options) !Theme {
    if (opts.style) |path| {
        return Theme.fromCssFile(gpa, init.io, path) catch |err| {
            log.err("cannot load the stylesheet {s}: {t}", .{ path, err });
            return err;
        };
    }
    if (opts.use_waybar_theme) {
        if (try Theme.fromWaybar(gpa, init.io, init.environ_map)) |t| return t;
        log.info("no waybar stylesheet found; using the built-in theme", .{});
    }
    return Theme.builtin;
}

/// Holds an exclusive lock so a second wayman cannot run alongside the
/// first; two instances would fight over the tray item and the Proton
/// session's single-use refresh token.
fn acquireInstanceLock(environ: *std.process.Environ.Map) !void {
    const c = @import("c");
    const dir = environ.get("XDG_RUNTIME_DIR") orelse "/tmp";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/wayman.lock", .{dir}, 0);
    const fd = c.open(path, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.LockFile;
    // The descriptor is kept open for the life of the process on purpose.
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
        log.err("wayman is already running (lock held on {s})", .{path});
        return error.AlreadyRunning;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const opts = try parseArgs(init.minimal.args, init);
    acquireInstanceLock(init.environ_map) catch |err| switch (err) {
        error.AlreadyRunning => std.process.exit(1),
        else => return err,
    };
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
        .agent = undefined,
        .proton = undefined,
        .portal = undefined,
        .timedate = undefined,
        .control = undefined,
        .theme = try loadTheme(gpa, init, opts),
    };
    defer app.theme.deinit(gpa);

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

    try app.agent.init(gpa, app.system);
    defer app.agent.deinit();
    app.agent.on_request = App.onAgentRequest;
    app.agent.on_cancel = App.onAgentCancel;
    app.agent.ctx = app;

    try app.proton.init(gpa, init.io, init.environ_map, &app.nm);
    defer app.proton.deinit();
    app.proton.on_change = App.onProtonChange;
    app.proton.on_change_ctx = app;

    try app.portal.init(gpa, init.io, init.environ_map);
    defer app.portal.deinit();
    app.portal.on_change = App.onPortalChange;
    app.portal.on_change_ctx = app;

    try app.timedate.init(gpa, app.system);
    defer app.timedate.deinit();
    app.timedate.on_change = App.onTimedateChange;
    app.timedate.on_change_ctx = app;

    try app.control.init(app.session, App.onControl, app);

    app.ui.init(gpa, &app.wl, &app.nm, &app.agent, &app.proton, &app.portal, &app.timedate, app.theme);
    defer app.ui.deinit();

    app.nm.refresh();
    log.info("wayman is running; click the tray icon to open the popup", .{});
    try app.run();
}

test {
    std.testing.refAllDecls(@This());
    _ = nm;
    _ = icon;
    _ = @import("theme.zig");
    _ = agent;
    _ = proton;
    _ = portal;
    _ = clock;
    _ = control;
}
