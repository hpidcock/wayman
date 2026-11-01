// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! Captive portal detection.
//!
//! After every Wi-Fi connection wayman fetches http://captive.apple.com on a
//! worker thread. Apple's server answers a tiny page containing "Success";
//! anything else (a redirect, a different page, an HTTP 511) means a portal
//! is intercepting traffic. The first time a portal is seen on a connection
//! the default browser is opened on the probe URL so the portal can show its
//! sign-in page; afterwards the probe repeats every half minute until the
//! network is open.
const std = @import("std");
const c = @import("c");

const log = std.log.scoped(.portal);
const Allocator = std.mem.Allocator;

pub const default_probe_url = "http://captive.apple.com";

pub const State = enum { unknown, checking, online, portal };

pub const ChangeFn = *const fn (?*anyopaque) void;

/// How long to wait after connecting before the first probe, so DHCP and
/// DNS have settled.
pub const first_delay_ms: i64 = 1500;
/// Re-probe interval while a portal is blocking.
pub const recheck_ms: i64 = 30_000;
/// Re-probe interval while online (catches portals that expire).
pub const online_recheck_ms: i64 = 10 * 60_000;

pub const Detector = struct {
    gpa: Allocator,
    io: std.Io,
    /// Overridable with WAYMAN_PORTAL_URL, for testing against a local server.
    probe_url: [:0]const u8 = default_probe_url,
    /// `$BROWSER` when set, otherwise xdg-open.
    browser: ?[:0]u8 = null,
    state: State = .unknown,
    /// Network the current state belongs to.
    ssid: ?[]u8 = null,
    /// Network for which the browser was already opened automatically.
    opened_for: ?[]u8 = null,
    /// When the next probe is due, or null.
    next_probe_ms: ?i64 = null,
    generation: u32 = 0,
    on_change: ?ChangeFn = null,
    on_change_ctx: ?*anyopaque = null,

    // Worker thread.
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    pending: ?u32 = null,
    result: ?struct { generation: u32, state: State } = null,
    quit: bool = false,
    wake_fd: c_int = -1,

    pub fn init(self: *Detector, gpa: Allocator, io: std.Io, environ: *std.process.Environ.Map) !void {
        self.* = .{ .gpa = gpa, .io = io };
        if (environ.get("WAYMAN_PORTAL_URL")) |u| {
            if (u.len > 0) self.probe_url = try gpa.dupeSentinel(u8, u, 0);
        }
        if (environ.get("BROWSER")) |b| {
            if (b.len > 0) self.browser = try gpa.dupeSentinel(u8, b, 0);
        }
        self.wake_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (self.wake_fd < 0) return error.EventFd;
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn deinit(self: *Detector) void {
        if (self.thread) |t| {
            self.mutex.lockUncancelable(self.io);
            self.quit = true;
            self.cond.signal(self.io);
            self.mutex.unlock(self.io);
            t.join();
        }
        if (self.wake_fd >= 0) _ = c.close(self.wake_fd);
        if (self.ssid) |s| self.gpa.free(s);
        if (self.opened_for) |s| self.gpa.free(s);
        if (self.browser) |b| self.gpa.free(b);
        if (self.probe_url.ptr != default_probe_url.ptr) self.gpa.free(self.probe_url);
    }

    pub fn fd(self: *Detector) c_int {
        return self.wake_fd;
    }

    /// True while the current network is known to need a sign-in.
    pub fn blocked(self: *const Detector) bool {
        return self.state == .portal;
    }

    fn notify(self: *Detector) void {
        if (self.on_change) |cb| cb(self.on_change_ctx);
    }

    /// Called whenever the Wi-Fi model changes: `ssid` is the connected
    /// network, or null when disconnected.
    pub fn onNetwork(self: *Detector, ssid: ?[]const u8, now_ms: i64) void {
        const current = self.ssid;
        const same = if (current != null and ssid != null) std.mem.eql(u8, current.?, ssid.?) else (current == null and ssid == null);
        if (same) return;
        if (self.ssid) |s| self.gpa.free(s);
        self.ssid = null;
        self.generation +%= 1;
        self.state = .unknown;
        self.next_probe_ms = null;
        if (ssid) |s| {
            self.ssid = self.gpa.dupe(u8, s) catch null;
            self.next_probe_ms = now_ms + first_delay_ms;
        }
        self.notify();
    }

    /// Milliseconds until the next scheduled probe, if any.
    pub fn nextDeadline(self: *const Detector, now_ms: i64) ?i64 {
        const due = self.next_probe_ms orelse return null;
        return @max(0, due - now_ms);
    }

    /// Runs due work; call from the main loop.
    pub fn poll(self: *Detector, now_ms: i64) void {
        var buf: u64 = 0;
        _ = c.read(self.wake_fd, &buf, 8);

        // Collect a finished probe.
        self.mutex.lockUncancelable(self.io);
        const result = self.result;
        self.result = null;
        self.mutex.unlock(self.io);
        if (result) |r| {
            if (r.generation == self.generation and self.ssid != null) {
                const was = self.state;
                self.state = r.state;
                switch (r.state) {
                    .portal => {
                        log.info("captive portal detected on {s}", .{self.ssid.?});
                        const already = self.opened_for != null and std.mem.eql(u8, self.opened_for.?, self.ssid.?);
                        if (!already) {
                            self.openBrowser();
                            if (self.opened_for) |o| self.gpa.free(o);
                            self.opened_for = self.gpa.dupe(u8, self.ssid.?) catch null;
                        }
                        self.next_probe_ms = now_ms + recheck_ms;
                    },
                    .online => {
                        if (was == .portal) log.info("{s} is open now", .{self.ssid.?});
                        if (self.opened_for) |o| {
                            // Allow the browser to open again if the portal returns later.
                            self.gpa.free(o);
                            self.opened_for = null;
                        }
                        self.next_probe_ms = now_ms + online_recheck_ms;
                    },
                    .unknown => self.next_probe_ms = now_ms + recheck_ms,
                    .checking => {},
                }
                self.notify();
            }
        }

        if (self.next_probe_ms) |due| {
            if (now_ms >= due and self.ssid != null) {
                self.next_probe_ms = null;
                self.state = if (self.state == .unknown) .checking else self.state;
                self.mutex.lockUncancelable(self.io);
                self.pending = self.generation;
                self.cond.signal(self.io);
                self.mutex.unlock(self.io);
            }
        }
    }

    /// Opens the sign-in page in the default browser.
    pub fn openBrowser(self: *Detector) void {
        const url: [*:0]const u8 = default_probe_url;
        if (self.browser) |b| {
            log.info("opening {s} with {s}", .{ url, b });
            spawnDetached(&.{ b, url });
        } else {
            log.info("opening {s} in the default browser", .{url});
            spawnDetached(&.{ "xdg-open", url });
        }
    }

    fn wake(self: *Detector) void {
        const one: u64 = 1;
        _ = c.write(self.wake_fd, &one, 8);
    }
};

fn workerMain(d: *Detector) void {
    var client: std.http.Client = .{ .allocator = d.gpa, .io = d.io };
    defer client.deinit();
    while (true) {
        d.mutex.lockUncancelable(d.io);
        while (d.pending == null and !d.quit) d.cond.wait(d.io, &d.mutex) catch {};
        if (d.quit) {
            d.mutex.unlock(d.io);
            return;
        }
        const generation = d.pending.?;
        d.pending = null;
        d.mutex.unlock(d.io);

        const state = probe(&client, d.gpa, d.probe_url);
        log.debug("probe of {s}: {t}", .{ d.probe_url, state });
        d.mutex.lockUncancelable(d.io);
        d.result = .{ .generation = generation, .state = state };
        d.mutex.unlock(d.io);
        d.wake();
    }
}

/// Fetches the probe URL without following redirects and classifies the reply.
fn probe(client: *std.http.Client, gpa: Allocator, url: []const u8) State {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .redirect_behavior = .unhandled,
        .response_writer = &out.writer,
        .headers = .{ .user_agent = .{ .override = "wayman" } },
    }) catch |err| {
        log.debug("probe failed: {t}", .{err});
        return .unknown;
    };
    return classify(@backingInt(result.status), out.written());
}

pub fn classify(status: u16, body: []const u8) State {
    if (status == 200 and std.mem.indexOf(u8, body, "Success") != null) return .online;
    return .portal;
}

/// Runs a command detached from wayman (double fork, new session), so the
/// browser outlives us and never becomes a zombie.
fn spawnDetached(argv: []const [*:0]const u8) void {
    var args: [8:null]?[*:0]const u8 = @splat(null);
    if (argv.len >= args.len) return;
    for (argv, 0..) |a, i| args[i] = a;
    const pid = c.fork();
    if (pid < 0) {
        log.warn("cannot fork to open the browser", .{});
        return;
    }
    if (pid == 0) {
        _ = c.setsid();
        const grandchild = c.fork();
        if (grandchild != 0) c._exit(0);
        _ = c.execvp(argv[0], @ptrCast(&args));
        c._exit(127);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
}

test "probe classification" {
    try std.testing.expectEqual(State.online, classify(200, "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"));
    try std.testing.expectEqual(State.portal, classify(302, ""));
    try std.testing.expectEqual(State.portal, classify(200, "<html>Welcome to Hotel Wi-Fi</html>"));
    try std.testing.expectEqual(State.portal, classify(511, "Network Authentication Required"));
}
