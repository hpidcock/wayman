// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! Proton VPN: sign-in, server list, and a WireGuard tunnel through
//! NetworkManager.
//!
//! All network traffic runs on a worker thread so the popup stays
//! responsive; results come back through a queue and an eventfd the main
//! loop polls. The session (tokens, WireGuard key, choices) is persisted to
//! `~/.config/wayman/proton.json` with mode 0600; the reduced server list to
//! `~/.cache/wayman/proton-servers.json`.
const std = @import("std");
const c = @import("c");
const api_mod = @import("proton/api.zig");
const srp = @import("proton/srp.zig");
const countries = @import("proton/countries.zig");
const nm = @import("nm.zig");

const log = std.log.scoped(.proton);
const Allocator = std.mem.Allocator;
const Api = api_mod.Api;

pub const Status = enum { signed_out, signing_in, needs_2fa, signed_in };

pub const profile_id = "Proton VPN";
const interface_name = "proton0";
const cert_duration = "10080 min";
const servers_max_age: i64 = 3 * 60 * 60;
const feature_secure_core: i64 = 1;
const feature_tor: i64 = 2;

/// Persisted session.
const SessionFile = struct {
    uid: []const u8 = "",
    access_token: []const u8 = "",
    refresh_token: []const u8 = "",
    username: []const u8 = "",
    /// Base64 Ed25519 seed; the WireGuard key is derived from it.
    ed25519_seed: []const u8 = "",
    cert_expiration: i64 = 0,
    cert_refresh: i64 = 0,
    tier: i64 = 0,
    plan: []const u8 = "",
    profile_uuid: []const u8 = "",
    /// Exit country code, empty for "fastest".
    country: []const u8 = "",
    last_server: []const u8 = "",
    wg_port: i64 = 51820,
    servers_fetched: i64 = 0,
};

const CachedServer = struct {
    n: []const u8,
    c: []const u8,
    t: i64,
    s: f64,
    l: i64,
    f: i64,
    ip: []const u8,
    pk: []const u8,
};

const CacheFile = struct {
    fetched: i64 = 0,
    servers: []const CachedServer = &.{},
};

/// Typed view of `/vpn/v1/logicals`, keeping only what is needed.
const Logicals = struct {
    LogicalServers: []const struct {
        Name: []const u8 = "",
        ExitCountry: []const u8 = "",
        Tier: i64 = 0,
        Score: f64 = 0,
        Load: i64 = 0,
        Status: i64 = 0,
        Features: i64 = 0,
        Servers: []const struct {
            EntryIP: []const u8 = "",
            Status: i64 = 0,
            X25519PublicKey: ?[]const u8 = null,
        } = &.{},
    } = &.{},
};

pub const Country = struct {
    code: [2]u8,
    name: []const u8,
    servers: u32,
};

const Job = union(enum) {
    quit,
    login: struct { username: []u8, password: []u8 },
    two_factor: []u8,
    logout,
    refresh_account,
    connect: struct { country: ?[2]u8 },
};

const Result = union(enum) {
    login_ok: struct { uid: []u8, access: []u8, refresh: []u8, username: []u8, needs_2fa: bool },
    two_factor_ok,
    tokens: struct { access: []u8, refresh: []u8 },
    account: struct { tier: i64, plan: []u8, seed_b64: ?[]u8, cert_expiration: i64, cert_refresh: i64, wg_port: i64, servers_fetched: i64 },
    certificate: struct { cert_expiration: i64, cert_refresh: i64 },
    servers: struct { fetched: i64 },
    connect_ready: struct { server: []u8, ip: []u8, pk: []u8, port: u16, wg_key: []u8 },
    logout_ok,
    signed_out: []u8,
    failed: []u8,
};

pub const ChangeFn = *const fn (?*anyopaque) void;

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    nm: *nm.Client,
    config_path: []u8,
    cache_path: []u8,
    session: SessionFile = .{},
    session_arena: std.heap.ArenaAllocator,
    status: Status = .signed_out,
    busy: ?[]const u8 = null,
    last_error: ?[]u8 = null,
    cache: ?std.json.Parsed(CacheFile) = null,
    country_list: []Country = &.{},
    /// Set when the user asked to connect and the activation is in flight.
    on_change: ?ChangeFn = null,
    on_change_ctx: ?*anyopaque = null,

    // Worker thread.
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    jobs: std.ArrayList(Job) = .empty,
    results: std.ArrayList(Result) = .empty,
    quit: bool = false,
    wake_fd: c_int = -1,

    pub fn init(self: *Client, gpa: Allocator, io: std.Io, environ: *std.process.Environ.Map, nm_client: *nm.Client) !void {
        const home = environ.get("HOME") orelse "/tmp";
        const config_dir = if (environ.get("XDG_CONFIG_HOME")) |x| try std.fmt.allocPrint(gpa, "{s}/wayman", .{x}) else try std.fmt.allocPrint(gpa, "{s}/.config/wayman", .{home});
        defer gpa.free(config_dir);
        const cache_dir = if (environ.get("XDG_CACHE_HOME")) |x| try std.fmt.allocPrint(gpa, "{s}/wayman", .{x}) else try std.fmt.allocPrint(gpa, "{s}/.cache/wayman", .{home});
        defer gpa.free(cache_dir);
        ensureDir(config_dir);
        ensureDir(cache_dir);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .nm = nm_client,
            .config_path = try std.fmt.allocPrint(gpa, "{s}/proton.json", .{config_dir}),
            .cache_path = try std.fmt.allocPrint(gpa, "{s}/proton-servers.json", .{cache_dir}),
            .session_arena = std.heap.ArenaAllocator.init(gpa),
        };
        errdefer gpa.free(self.config_path);
        errdefer gpa.free(self.cache_path);

        self.wake_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (self.wake_fd < 0) return error.EventFd;

        self.loadSession();
        self.loadCache();
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});

        if (self.status == .signed_in) {
            const now = epoch();
            const no_servers = self.cache == null or self.cache.?.value.servers.len == 0;
            if (no_servers or now - self.session.servers_fetched > servers_max_age or self.session.cert_refresh <= now) {
                self.enqueue(.refresh_account, "Refreshing Proton VPN\u{2026}");
            }
        }
    }

    pub fn deinit(self: *Client) void {
        if (self.thread) |t| {
            self.mutex.lockUncancelable(self.io);
            self.quit = true;
            self.cond.signal(self.io);
            self.mutex.unlock(self.io);
            t.join();
        }
        for (self.jobs.items) |*j| freeJob(self.gpa, j);
        self.jobs.deinit(self.gpa);
        for (self.results.items) |*r| freeResult(self.gpa, r);
        self.results.deinit(self.gpa);
        if (self.wake_fd >= 0) _ = c.close(self.wake_fd);
        if (self.cache) |*p| p.deinit();
        self.gpa.free(self.country_list);
        if (self.last_error) |e| self.gpa.free(e);
        self.session_arena.deinit();
        self.gpa.free(self.config_path);
        self.gpa.free(self.cache_path);
    }

    // ---- queries -------------------------------------------------------------

    pub fn fd(self: *Client) c_int {
        return self.wake_fd;
    }

    pub fn lastError(self: *const Client) ?[]const u8 {
        return self.last_error;
    }

    pub fn clearError(self: *Client) void {
        if (self.last_error) |e| self.gpa.free(e);
        self.last_error = null;
    }

    pub fn username(self: *const Client) []const u8 {
        return self.session.username;
    }

    pub fn plan(self: *const Client) []const u8 {
        return self.session.plan;
    }

    pub fn profileUuid(self: *const Client) ?[]const u8 {
        return if (self.session.profile_uuid.len > 0) self.session.profile_uuid else null;
    }

    pub fn lastServer(self: *const Client) ?[]const u8 {
        return if (self.session.last_server.len > 0) self.session.last_server else null;
    }

    pub fn selectedCountry(self: *const Client) ?[2]u8 {
        if (self.session.country.len != 2) return null;
        return self.session.country[0..2].*;
    }

    pub fn selectedCountryName(self: *const Client) []const u8 {
        const code = self.selectedCountry() orelse return "Fastest";
        return countries.name(&code);
    }

    pub fn countryList(self: *const Client) []const Country {
        return self.country_list;
    }

    /// The tunnel's state as NetworkManager sees it.
    pub fn vpnState(self: *const Client) nm.VpnState {
        const uuid = self.profileUuid() orelse return .off;
        const vpn = self.nm.findVpnByUuid(uuid) orelse return .off;
        return vpn.state;
    }

    // ---- actions ---------------------------------------------------------------

    pub fn login(self: *Client, user: []const u8, password: []const u8) void {
        if (self.status == .signing_in) return;
        self.clearError();
        const u = self.gpa.dupe(u8, user) catch return;
        const p = self.gpa.dupe(u8, password) catch {
            self.gpa.free(u);
            return;
        };
        self.status = .signing_in;
        self.enqueue(.{ .login = .{ .username = u, .password = p } }, "Signing in\u{2026}");
    }

    pub fn twoFactor(self: *Client, code: []const u8) void {
        self.clearError();
        const copy = self.gpa.dupe(u8, code) catch return;
        self.enqueue(.{ .two_factor = copy }, "Checking code\u{2026}");
    }

    pub fn logout(self: *Client) void {
        self.clearError();
        self.disconnect();
        self.enqueue(.logout, "Signing out\u{2026}");
    }

    pub fn connect(self: *Client) void {
        if (self.status != .signed_in) return;
        self.clearError();
        self.enqueue(.{ .connect = .{ .country = self.selectedCountry() } }, "Connecting\u{2026}");
    }

    pub fn disconnect(self: *Client) void {
        const uuid = self.profileUuid() orelse return;
        self.nm.deactivateByUuid(uuid) catch |err| log.warn("cannot deactivate the Proton VPN profile: {t}", .{err});
    }

    /// Choose the exit country (null for fastest). Reconnects when connected.
    pub fn selectCountry(self: *Client, code: ?[2]u8) void {
        const a = self.session_arena.allocator();
        self.session.country = if (code) |cc| (a.dupe(u8, &cc) catch return) else "";
        self.saveSession();
        self.notify();
        const state = self.vpnState();
        if (state == .on or state == .connecting) self.connect();
    }

    pub fn refreshServers(self: *Client) void {
        if (self.status != .signed_in) return;
        self.enqueue(.refresh_account, "Refreshing servers\u{2026}");
    }

    // ---- worker plumbing ---------------------------------------------------

    fn enqueue(self: *Client, job: Job, busy_text: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        self.jobs.append(self.gpa, job) catch {
            self.mutex.unlock(self.io);
            return;
        };
        self.cond.signal(self.io);
        self.mutex.unlock(self.io);
        self.busy = busy_text;
        self.notify();
    }

    fn notify(self: *Client) void {
        if (self.on_change) |cb| cb(self.on_change_ctx);
    }

    fn wake(self: *Client) void {
        const one: u64 = 1;
        _ = c.write(self.wake_fd, &one, 8);
    }

    /// Called from the main loop when the eventfd is readable (or any time).
    pub fn poll(self: *Client) void {
        var buf: u64 = 0;
        _ = c.read(self.wake_fd, &buf, 8);
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.results.items.len == 0) {
                self.mutex.unlock(self.io);
                break;
            }
            var result = self.results.orderedRemove(0);
            self.mutex.unlock(self.io);
            self.handle(&result);
            freeResult(self.gpa, &result);
        }
    }

    fn setError(self: *Client, text: []const u8) void {
        self.clearError();
        self.last_error = self.gpa.dupe(u8, text) catch null;
    }

    fn handle(self: *Client, result: *Result) void {
        const a = self.session_arena.allocator();
        switch (result.*) {
            .login_ok => |r| {
                self.session.uid = a.dupe(u8, r.uid) catch "";
                self.session.access_token = a.dupe(u8, r.access) catch "";
                self.session.refresh_token = a.dupe(u8, r.refresh) catch "";
                self.session.username = a.dupe(u8, r.username) catch "";
                if (r.needs_2fa) {
                    self.status = .needs_2fa;
                    self.busy = null;
                } else {
                    self.status = .signed_in;
                    self.enqueue(.refresh_account, "Fetching servers\u{2026}");
                }
                self.saveSession();
            },
            .two_factor_ok => {
                self.status = .signed_in;
                self.enqueue(.refresh_account, "Fetching servers\u{2026}");
                self.saveSession();
            },
            .tokens => |r| {
                self.session.access_token = a.dupe(u8, r.access) catch "";
                self.session.refresh_token = a.dupe(u8, r.refresh) catch "";
                self.saveSession();
            },
            .account => |r| {
                self.session.tier = r.tier;
                self.session.plan = a.dupe(u8, r.plan) catch "";
                if (r.seed_b64) |s| self.session.ed25519_seed = a.dupe(u8, s) catch "";
                self.session.cert_expiration = r.cert_expiration;
                self.session.cert_refresh = r.cert_refresh;
                self.session.wg_port = r.wg_port;
                self.session.servers_fetched = r.servers_fetched;
                if (self.session.profile_uuid.len == 0) self.session.profile_uuid = newUuid(a, self.io) catch "";
                self.loadCache();
                self.saveSession();
                self.busy = null;
            },
            .certificate => |r| {
                self.session.cert_expiration = r.cert_expiration;
                self.session.cert_refresh = r.cert_refresh;
                self.saveSession();
            },
            .servers => |r| {
                self.session.servers_fetched = r.fetched;
                self.loadCache();
                self.saveSession();
            },
            .connect_ready => |r| {
                self.busy = null;
                self.session.last_server = a.dupe(u8, r.server) catch "";
                if (self.session.profile_uuid.len == 0) self.session.profile_uuid = newUuid(a, self.io) catch "";
                self.saveSession();
                var endpoint_buf: [128]u8 = undefined;
                const endpoint = std.fmt.bufPrint(&endpoint_buf, "{s}:{d}", .{ r.ip, r.port }) catch return;
                const path = self.nm.ensureWireguardProfile(.{
                    .uuid = self.session.profile_uuid,
                    .id = profile_id,
                    .interface = interface_name,
                    .private_key = r.wg_key,
                    .peer_public_key = r.pk,
                    .endpoint = endpoint,
                }) catch |err| {
                    self.setError("Couldn't create the WireGuard profile in NetworkManager");
                    log.warn("profile: {t}", .{err});
                    return;
                };
                defer self.gpa.free(path);
                log.info("connecting to {s} ({s})", .{ r.server, endpoint });
                self.nm.activateProfile(path, profile_id) catch |err| {
                    self.setError("Couldn't activate the Proton VPN profile");
                    log.warn("activate: {t}", .{err});
                };
            },
            .logout_ok => {
                self.busy = null;
                self.status = .signed_out;
                if (self.profileUuid()) |uuid| self.nm.deleteProfileByUuid(uuid) catch {};
                const keep_user = self.gpa.dupe(u8, self.session.username) catch "";
                defer self.gpa.free(keep_user);
                _ = self.session_arena.reset(.free_all);
                self.session = .{ .username = a.dupe(u8, keep_user) catch "" };
                _ = c.unlink(self.config_path.ptr);
                self.gpa.free(self.country_list);
                self.country_list = &.{};
            },
            .signed_out => |msg| {
                self.busy = null;
                self.status = .signed_out;
                self.session.uid = "";
                self.session.access_token = "";
                self.session.refresh_token = "";
                self.saveSession();
                self.setError(msg);
            },
            .failed => |msg| {
                self.busy = null;
                if (self.status == .signing_in) self.status = .signed_out;
                self.setError(msg);
            },
        }
        self.notify();
    }

    // ---- persistence ------------------------------------------------------

    fn loadSession(self: *Client) void {
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, self.config_path, self.gpa, .limited(1 << 20)) catch return;
        defer self.gpa.free(text);
        const a = self.session_arena.allocator();
        const parsed = parseSession(a, text) catch |err| {
            log.warn("ignoring unreadable {s}: {t}", .{ self.config_path, err });
            return;
        };
        self.session = parsed;
        if (self.session.uid.len > 0 and self.session.access_token.len > 0) {
            self.status = .signed_in;
            log.info("Proton VPN session restored for {s}", .{self.session.username});
        }
    }

    fn saveSession(self: *Client) void {
        const text = std.json.Stringify.valueAlloc(self.gpa, self.session, .{ .whitespace = .indent_2 }) catch return;
        defer self.gpa.free(text);
        writeFilePrivate(self.config_path, text) catch |err| log.warn("cannot write {s}: {t}", .{ self.config_path, err });
    }

    fn loadCache(self: *Client) void {
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, self.cache_path, self.gpa, .limited(64 << 20)) catch return;
        defer self.gpa.free(text);
        const parsed = std.json.parseFromSlice(CacheFile, self.gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
            log.warn("ignoring unreadable {s}: {t}", .{ self.cache_path, err });
            return;
        };
        if (self.cache) |*old| old.deinit();
        self.cache = parsed;
        self.rebuildCountries();
    }

    fn rebuildCountries(self: *Client) void {
        self.gpa.free(self.country_list);
        self.country_list = &.{};
        const cache = self.cache orelse return;
        var list: std.ArrayList(Country) = .empty;
        outer: for (cache.value.servers) |s| {
            if (s.c.len != 2 or s.t > self.session.tier) continue;
            if (s.f & (feature_secure_core | feature_tor) != 0) continue;
            for (list.items) |*cn| {
                if (std.mem.eql(u8, &cn.code, s.c)) {
                    cn.servers += 1;
                    continue :outer;
                }
            }
            list.append(self.gpa, .{ .code = s.c[0..2].*, .name = countries.name(s.c), .servers = 1 }) catch continue;
        }
        std.mem.sort(Country, list.items, {}, countryLessThan);
        self.country_list = list.toOwnedSlice(self.gpa) catch &.{};
    }

    fn countryLessThan(_: void, lhs: Country, rhs: Country) bool {
        return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
    }
};

// ---- worker thread ---------------------------------------------------------

const Worker = struct {
    client: *Client,
    gpa: Allocator,
    api: Api,
    uid: ?[]u8 = null,
    access: ?[]u8 = null,
    refresh: ?[]u8 = null,
    seed_b64: ?[]u8 = null,
    tier: i64 = 0,
    cert_refresh: i64 = 0,
    servers_fetched: i64 = 0,
    wg_port: i64 = 51820,

    const WorkerError = error{ Api, OutOfMemory, SignedOut, Invalid };

    fn push(self: *Worker, result: Result) void {
        const cl = self.client;
        cl.mutex.lockUncancelable(cl.io);
        cl.results.append(self.gpa, result) catch {
            cl.mutex.unlock(cl.io);
            return;
        };
        cl.mutex.unlock(cl.io);
        cl.wake();
    }

    fn pushFailure(self: *Worker, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        self.push(.{ .failed = msg });
    }

    fn freeTokens(self: *Worker) void {
        if (self.uid) |x| self.gpa.free(x);
        if (self.access) |x| self.gpa.free(x);
        if (self.refresh) |x| self.gpa.free(x);
        if (self.seed_b64) |x| self.gpa.free(x);
        self.uid = null;
        self.access = null;
        self.refresh = null;
        self.seed_b64 = null;
    }

    /// Copies the session the main thread holds.
    fn snapshot(self: *Worker) !void {
        const cl = self.client;
        cl.mutex.lockUncancelable(cl.io);
        defer cl.mutex.unlock(cl.io);
        self.freeTokens();
        if (cl.session.uid.len > 0) self.uid = try self.gpa.dupe(u8, cl.session.uid);
        if (cl.session.access_token.len > 0) self.access = try self.gpa.dupe(u8, cl.session.access_token);
        if (cl.session.refresh_token.len > 0) self.refresh = try self.gpa.dupe(u8, cl.session.refresh_token);
        if (cl.session.ed25519_seed.len > 0) self.seed_b64 = try self.gpa.dupe(u8, cl.session.ed25519_seed);
        self.tier = cl.session.tier;
        self.cert_refresh = cl.session.cert_refresh;
        self.servers_fetched = cl.session.servers_fetched;
        self.wg_port = cl.session.wg_port;
        if (self.uid != null and self.access != null) {
            try self.api.setSession(self.uid.?, self.access.?);
        } else {
            self.api.clearSession();
        }
    }

    /// A request with the session, refreshing the access token once on 401.
    fn authed(self: *Worker, method: std.http.Method, path: []const u8, body: ?[]const u8, extra: []const std.http.Header) WorkerError!api_mod.Response {
        if (self.uid == null) return error.SignedOut;
        return self.api.request(method, path, body, extra) catch |err| {
            if (err == error.Api and self.api.failureStatus() == 401) {
                try self.refreshTokens();
                return self.api.request(method, path, body, extra) catch return error.Api;
            }
            return err;
        };
    }

    fn refreshTokens(self: *Worker) WorkerError!void {
        const body = try api_mod.encode(self.gpa, .{
            .ResponseType = "token",
            .GrantType = "refresh_token",
            .RefreshToken = self.refresh orelse return error.SignedOut,
            .RedirectURI = "http://protonmail.ch",
        });
        defer self.gpa.free(body);
        var resp = self.api.post("/auth/refresh", body) catch {
            self.push(.{ .signed_out = try self.gpa.dupe(u8, "Proton session expired; sign in again") });
            return error.SignedOut;
        };
        defer resp.deinit();
        const access = resp.str("AccessToken") orelse return error.Invalid;
        const refresh = resp.str("RefreshToken") orelse return error.Invalid;
        self.gpa.free(self.access.?);
        self.access = try self.gpa.dupe(u8, access);
        self.gpa.free(self.refresh.?);
        self.refresh = try self.gpa.dupe(u8, refresh);
        try self.api.setSession(self.uid.?, self.access.?);
        self.push(.{ .tokens = .{ .access = try self.gpa.dupe(u8, access), .refresh = try self.gpa.dupe(u8, refresh) } });
        log.info("Proton access token refreshed", .{});
    }

    fn run(self: *Worker, job: *Job) void {
        self.snapshot() catch return;
        switch (job.*) {
            .quit => {},
            .login => |l| self.login(l.username, l.password) catch |err| self.reportError(err),
            .two_factor => |code| self.twoFactor(code) catch |err| self.reportError(err),
            .logout => self.logout(),
            .refresh_account => self.refreshAccount() catch |err| self.reportError(err),
            .connect => |cn| self.connectJob(cn.country) catch |err| self.reportError(err),
        }
    }

    fn reportError(self: *Worker, err: WorkerError) void {
        switch (err) {
            error.SignedOut => {},
            error.Api => {
                const status = self.api.failureStatus();
                const code = self.api.failureCode();
                if (status == 422 and code == 9001) {
                    self.pushFailure("Proton asks for human verification; sign in at account.proton.me once, then retry", .{});
                } else if (code == 5003) {
                    self.pushFailure("Proton no longer accepts wayman's client version ({s}); update wayman", .{api_mod.app_version});
                } else {
                    self.pushFailure("Proton: {s}", .{self.api.failureText()});
                }
            },
            error.OutOfMemory => self.pushFailure("Out of memory", .{}),
            error.Invalid => self.pushFailure("Unexpected reply from Proton", .{}),
        }
    }

    fn login(self: *Worker, user: []const u8, password: []const u8) WorkerError!void {
        self.api.clearSession();
        const info_body = try api_mod.encode(self.gpa, .{ .Username = user });
        defer self.gpa.free(info_body);
        var info = self.api.post("/auth/info", info_body) catch return error.Api;
        defer info.deinit();

        const modulus_b64 = api_mod.clearsignedPayload(info.str("Modulus") orelse return error.Invalid) catch return error.Invalid;
        const modulus = api_mod.base64Decode(self.gpa, modulus_b64) catch return error.Invalid;
        defer self.gpa.free(modulus);
        const server_ephemeral = api_mod.base64Decode(self.gpa, info.str("ServerEphemeral") orelse return error.Invalid) catch return error.Invalid;
        defer self.gpa.free(server_ephemeral);
        const salt = api_mod.base64Decode(self.gpa, info.str("Salt") orelse return error.Invalid) catch return error.Invalid;
        defer self.gpa.free(salt);
        const version: u32 = @intCast(info.int("Version") orelse 4);
        const srp_session = info.str("SRPSession") orelse return error.Invalid;
        if (modulus.len != srp.len or server_ephemeral.len != srp.len) return error.Invalid;

        var secret: [32]u8 = undefined;
        randomBytes(self.client.io, &secret);
        var client = srp.Client.init(self.gpa, modulus[0..srp.len], secret) catch return error.OutOfMemory;
        defer client.deinit();
        const proof = client.processChallenge(salt, server_ephemeral[0..srp.len], password, version) catch |err| {
            if (err == error.UnsupportedAuthVersion) {
                self.pushFailure("This Proton account needs a web sign-in once to upgrade its auth version", .{});
                return error.SignedOut;
            }
            return error.Invalid;
        };

        const a_b64 = try api_mod.base64Encode(self.gpa, &client.challenge());
        defer self.gpa.free(a_b64);
        const m1_b64 = try api_mod.base64Encode(self.gpa, &proof);
        defer self.gpa.free(m1_b64);
        const auth_body = try api_mod.encode(self.gpa, .{
            .Username = user,
            .ClientEphemeral = a_b64,
            .ClientProof = m1_b64,
            .SRPSession = srp_session,
        });
        defer self.gpa.free(auth_body);
        var auth = self.api.post("/auth", auth_body) catch {
            if (self.api.failureCode() == 8002) {
                self.pushFailure("Wrong username or password", .{});
                return error.SignedOut;
            }
            return error.Api;
        };
        defer auth.deinit();

        const server_proof = api_mod.base64Decode(self.gpa, auth.str("ServerProof") orelse return error.Invalid) catch return error.Invalid;
        defer self.gpa.free(server_proof);
        if (!client.verifyServerProof(server_proof)) {
            self.pushFailure("Proton's server proof did not verify", .{});
            return error.SignedOut;
        }
        var needs_2fa = false;
        if (auth.object()) |o| {
            if (api_mod.getArray(o, "Scopes")) |scopes| {
                for (scopes) |s| {
                    if (s == .string and std.mem.eql(u8, s.string, "twofactor")) needs_2fa = true;
                }
            }
        }
        self.push(.{ .login_ok = .{
            .uid = try self.gpa.dupe(u8, auth.str("UID") orelse return error.Invalid),
            .access = try self.gpa.dupe(u8, auth.str("AccessToken") orelse return error.Invalid),
            .refresh = try self.gpa.dupe(u8, auth.str("RefreshToken") orelse return error.Invalid),
            .username = try self.gpa.dupe(u8, user),
            .needs_2fa = needs_2fa,
        } });
        log.info("signed in to Proton as {s}{s}", .{ user, if (needs_2fa) " (2FA pending)" else "" });
    }

    fn twoFactor(self: *Worker, code: []const u8) WorkerError!void {
        const body = try api_mod.encode(self.gpa, .{ .TwoFactorCode = code });
        defer self.gpa.free(body);
        var resp = try self.authed(.POST, "/auth/2fa", body, &.{});
        resp.deinit();
        self.push(.two_factor_ok);
    }

    fn logout(self: *Worker) void {
        if (self.uid != null) {
            if (self.api.delete("/auth")) |resp| {
                var r = resp;
                r.deinit();
            } else |_| {}
        }
        self.push(.logout_ok);
    }

    fn ensureSeed(self: *Worker) WorkerError!bool {
        if (self.seed_b64 != null) return false;
        var seed: [32]u8 = undefined;
        randomBytes(self.client.io, &seed);
        self.seed_b64 = try api_mod.base64Encode(self.gpa, &seed);
        return true;
    }

    fn keyPair(self: *Worker) WorkerError!std.crypto.sign.Ed25519.KeyPair {
        const seed_bytes = api_mod.base64Decode(self.gpa, self.seed_b64 orelse return error.Invalid) catch return error.Invalid;
        defer self.gpa.free(seed_bytes);
        if (seed_bytes.len != 32) return error.Invalid;
        return std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed_bytes[0..32].*) catch return error.Invalid;
    }

    /// The Ed25519 public key as a PEM SubjectPublicKeyInfo, which is what
    /// the certificate endpoint expects as `ClientPublicKey`.
    fn publicKeyPem(self: *Worker) WorkerError![]u8 {
        const kp = try self.keyPair();
        const prefix = [_]u8{ 0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00 };
        var der: [44]u8 = undefined;
        @memcpy(der[0..12], &prefix);
        @memcpy(der[12..44], &kp.public_key.toBytes());
        const b64 = try api_mod.base64Encode(self.gpa, &der);
        defer self.gpa.free(b64);
        return std.fmt.allocPrint(self.gpa, "-----BEGIN PUBLIC KEY-----\n{s}\n-----END PUBLIC KEY-----\n", .{b64});
    }

    fn wireguardPrivateKey(self: *Worker) WorkerError![]u8 {
        const kp = try self.keyPair();
        const x = std.crypto.dh.X25519.KeyPair.fromEd25519(kp) catch return error.Invalid;
        return api_mod.base64Encode(self.gpa, &x.secret_key);
    }

    const CertTimes = struct { expiration: i64, refresh: i64 };

    fn requestCertificate(self: *Worker) WorkerError!CertTimes {
        const pem = try self.publicKeyPem();
        defer self.gpa.free(pem);
        const body = try api_mod.encode(self.gpa, .{ .ClientPublicKey = pem, .Duration = cert_duration });
        defer self.gpa.free(body);
        var resp = try self.authed(.POST, "/vpn/v1/certificate", body, &.{});
        defer resp.deinit();
        const expiration = resp.int("ExpirationTime") orelse return error.Invalid;
        const refresh = resp.int("RefreshTime") orelse expiration - 24 * 3600;
        log.info("Proton certificate issued, valid until {d}", .{expiration});
        return .{ .expiration = expiration, .refresh = refresh };
    }

    fn netzone(self: *Worker, out: *[32]u8) WorkerError![]const u8 {
        var resp = try self.authed(.GET, "/vpn/v1/location", null, &.{});
        defer resp.deinit();
        const ip = resp.str("IP") orelse return error.Invalid;
        const last_dot = std.mem.lastIndexOfScalar(u8, ip, '.') orelse return error.Invalid;
        return std.fmt.bufPrint(out, "{s}.0", .{ip[0..last_dot]}) catch return error.Invalid;
    }

    fn fetchServers(self: *Worker) WorkerError!i64 {
        var zone_buf: [32]u8 = undefined;
        const zone = try self.netzone(&zone_buf);
        // The v1 list carries Status/Load/Score inline; v2 moves them into a
        // binary status blob that needs Proton's scoring library to interpret.
        var resp = try self.authed(.GET, "/vpn/v1/logicals?SecureCoreFilter=all&WithState=true", null, &.{.{ .name = "X-PM-netzone", .value = zone }});
        defer resp.deinit();

        // Re-parse the body as the typed view; the generic tree is dropped.
        const text = try std.json.Stringify.valueAlloc(self.gpa, resp.root(), .{});
        defer self.gpa.free(text);
        var reduced = reduceLogicals(self.gpa, text) catch return error.Invalid;
        defer freeReduced(self.gpa, &reduced);
        const now = epoch();
        const cache: CacheFile = .{ .fetched = now, .servers = reduced.items };
        const out = try std.json.Stringify.valueAlloc(self.gpa, cache, .{});
        defer self.gpa.free(out);
        writeFilePrivate(self.client.cache_path, out) catch return error.Invalid;
        log.info("Proton server list: {d} servers", .{reduced.items.len});
        return now;
    }

    fn refreshAccount(self: *Worker) WorkerError!void {
        const new_seed = try self.ensureSeed();
        var info = try self.authed(.GET, "/vpn/v2", null, &.{});
        defer info.deinit();
        const vpn = api_mod.getObject(info.object() orelse return error.Invalid, "VPN") orelse return error.Invalid;
        const tier = api_mod.getInt(vpn, "MaxTier") orelse 0;
        const plan_title = api_mod.getStr(vpn, "PlanTitle") orelse "Proton VPN";
        self.tier = tier;

        const cert = try self.requestCertificate();

        var port: i64 = 51820;
        if (self.authed(.GET, "/vpn/v2/clientconfig", null, &.{})) |cfg_resp| {
            var cfg = cfg_resp;
            defer cfg.deinit();
            if (cfg.object()) |o| {
                if (api_mod.getObject(o, "DefaultPorts")) |ports| {
                    if (api_mod.getObject(ports, "WireGuard")) |wg| {
                        if (api_mod.getArray(wg, "UDP")) |udp| {
                            if (udp.len > 0 and udp[0] == .integer) port = udp[0].integer;
                        }
                    }
                }
            }
        } else |_| {}

        const fetched = try self.fetchServers();
        self.push(.{ .account = .{
            .tier = tier,
            .plan = try self.gpa.dupe(u8, plan_title),
            .seed_b64 = if (new_seed) try self.gpa.dupe(u8, self.seed_b64.?) else null,
            .cert_expiration = cert.expiration,
            .cert_refresh = cert.refresh,
            .wg_port = port,
            .servers_fetched = fetched,
        } });
    }

    fn connectJob(self: *Worker, country: ?[2]u8) WorkerError!void {
        const now = epoch();
        if (self.seed_b64 == null or self.cert_refresh <= now) {
            if (try self.ensureSeed()) {
                // A brand-new key: the account result carries it to the main thread.
                try self.refreshAccount();
            } else {
                const cert = try self.requestCertificate();
                self.push(.{ .certificate = .{ .cert_expiration = cert.expiration, .cert_refresh = cert.refresh } });
            }
        }
        if (now - self.servers_fetched > servers_max_age) {
            const fetched = try self.fetchServers();
            self.push(.{ .servers = .{ .fetched = fetched } });
        }

        const text = std.Io.Dir.cwd().readFileAlloc(self.client.io, self.client.cache_path, self.gpa, .limited(64 << 20)) catch return error.Invalid;
        defer self.gpa.free(text);
        var cache = std.json.parseFromSlice(CacheFile, self.gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.Invalid;
        defer cache.deinit();

        var best: ?CachedServer = null;
        for (cache.value.servers) |s| {
            if (s.t > self.tier) continue;
            if (s.f & (feature_secure_core | feature_tor) != 0) continue;
            if (country) |cc| {
                if (!std.ascii.eqlIgnoreCase(s.c, &cc)) continue;
            }
            if (best == null or s.s < best.?.s) best = s;
        }
        const chosen = best orelse {
            self.pushFailure("No Proton VPN server available for that choice", .{});
            return;
        };
        self.push(.{ .connect_ready = .{
            .server = try self.gpa.dupe(u8, chosen.n),
            .ip = try self.gpa.dupe(u8, chosen.ip),
            .pk = try self.gpa.dupe(u8, chosen.pk),
            .port = @intCast(std.math.clamp(self.wg_port, 1, 65535)),
            .wg_key = try self.wireguardPrivateKey(),
        } });
    }
};

fn workerMain(client: *Client) void {
    var worker: Worker = .{ .client = client, .gpa = client.gpa, .api = Api.init(client.gpa, client.io) };
    defer worker.api.deinit();
    defer worker.freeTokens();
    while (true) {
        client.mutex.lockUncancelable(client.io);
        while (client.jobs.items.len == 0 and !client.quit) client.cond.wait(client.io, &client.mutex) catch {};
        if (client.quit) {
            client.mutex.unlock(client.io);
            return;
        }
        var job = client.jobs.orderedRemove(0);
        client.mutex.unlock(client.io);
        defer freeJob(client.gpa, &job);
        worker.run(&job);
    }
}

fn freeJob(gpa: Allocator, job: *Job) void {
    switch (job.*) {
        .login => |l| {
            gpa.free(l.username);
            @memset(l.password, 0);
            gpa.free(l.password);
        },
        .two_factor => |code| gpa.free(code),
        else => {},
    }
}

fn freeResult(gpa: Allocator, result: *Result) void {
    switch (result.*) {
        .login_ok => |r| {
            gpa.free(r.uid);
            gpa.free(r.access);
            gpa.free(r.refresh);
            gpa.free(r.username);
        },
        .tokens => |r| {
            gpa.free(r.access);
            gpa.free(r.refresh);
        },
        .account => |r| {
            gpa.free(r.plan);
            if (r.seed_b64) |s| gpa.free(s);
        },
        .connect_ready => |r| {
            gpa.free(r.server);
            gpa.free(r.ip);
            gpa.free(r.pk);
            @memset(r.wg_key, 0);
            gpa.free(r.wg_key);
        },
        .signed_out => |m| gpa.free(m),
        .failed => |m| gpa.free(m),
        else => {},
    }
}

/// Keeps, from a `/vpn/v1/logicals` body, the enabled logical servers that
/// have an enabled physical server with a WireGuard key.
fn reduceLogicals(gpa: Allocator, text: []const u8) !std.ArrayList(CachedServer) {
    var parsed = try std.json.parseFromSlice(Logicals, gpa, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var reduced: std.ArrayList(CachedServer) = .empty;
    errdefer reduced.deinit(gpa);
    for (parsed.value.LogicalServers) |ls| {
        if (ls.Status != 1) continue;
        var ip: []const u8 = "";
        var pk: []const u8 = "";
        for (ls.Servers) |ps| {
            if (ps.Status == 1 and ps.EntryIP.len > 0 and ps.X25519PublicKey != null) {
                ip = ps.EntryIP;
                pk = ps.X25519PublicKey.?;
                break;
            }
        }
        if (ip.len == 0) continue;
        try reduced.append(gpa, .{
            .n = try gpa.dupe(u8, ls.Name),
            .c = try gpa.dupe(u8, ls.ExitCountry),
            .t = ls.Tier,
            .s = ls.Score,
            .l = ls.Load,
            .f = ls.Features,
            .ip = try gpa.dupe(u8, ip),
            .pk = try gpa.dupe(u8, pk),
        });
    }
    return reduced;
}

fn freeReduced(gpa: Allocator, list: *std.ArrayList(CachedServer)) void {
    for (list.items) |s| {
        gpa.free(s.n);
        gpa.free(s.c);
        gpa.free(s.ip);
        gpa.free(s.pk);
    }
    list.deinit(gpa);
}

test "reduce a v1 logicals body" {
    const body =
        \\{"Code":1000,"LogicalServers":[
        \\ {"Name":"CH#1","ExitCountry":"CH","Tier":0,"Features":0,"Score":1.5,"Load":40,"Status":1,
        \\  "Servers":[{"EntryIP":"1.2.3.4","Status":0,"X25519PublicKey":"a"},{"EntryIP":"1.2.3.5","Status":1,"X25519PublicKey":"b"}]},
        \\ {"Name":"CH#2","ExitCountry":"CH","Tier":2,"Features":1,"Score":0.9,"Load":10,"Status":0,
        \\  "Servers":[{"EntryIP":"1.2.3.6","Status":1,"X25519PublicKey":"c"}]},
        \\ {"Name":"US#1","ExitCountry":"US","Tier":2,"Features":0,"Score":2,"Load":70,"Status":1,
        \\  "Servers":[{"EntryIP":"5.6.7.8","Status":1}]}
        \\]}
    ;
    var list = try reduceLogicals(std.testing.allocator, body);
    defer freeReduced(std.testing.allocator, &list);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("CH#1", list.items[0].n);
    try std.testing.expectEqualStrings("1.2.3.5", list.items[0].ip);
    try std.testing.expectEqualStrings("b", list.items[0].pk);
}

/// Parses the session file so that every string is owned by `a`, never a
/// slice of `text`.
fn parseSession(a: Allocator, text: []const u8) !SessionFile {
    return std.json.parseFromSliceLeaky(SessionFile, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

test "session strings do not alias the input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try std.testing.allocator.dupe(u8, "{\"uid\":\"abc\",\"access_token\":\"tok\",\"tier\":2}");
    const sess = try parseSession(arena.allocator(), text);
    @memset(text, 'x');
    std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("abc", sess.uid);
    try std.testing.expectEqualStrings("tok", sess.access_token);
    try std.testing.expectEqual(@as(i64, 2), sess.tier);
}

test "cache strings do not alias the input" {
    const text = try std.testing.allocator.dupe(u8, "{\"fetched\":1,\"servers\":[{\"n\":\"CH#1\",\"c\":\"CH\",\"t\":0,\"s\":1.0,\"l\":1,\"f\":0,\"ip\":\"1.2.3.4\",\"pk\":\"k\"}]}");
    var parsed = try std.json.parseFromSlice(CacheFile, std.testing.allocator, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();
    @memset(text, 'x');
    std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("CH", parsed.value.servers[0].c);
    try std.testing.expectEqualStrings("CH#1", parsed.value.servers[0].n);
}

// ---- helpers -----------------------------------------------------------------

pub fn epoch() i64 {
    return @intCast(c.time(null));
}

fn ensureDir(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return;
    _ = c.mkdir(z, 0o700);
}

/// Writes `data` to `path` readable only by the owner.
fn writeFilePrivate(path: []const u8, data: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0);
    const fd = c.open(z, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn randomBytes(io: std.Io, buf: []u8) void {
    io.randomSecure(buf) catch io.random(buf);
}

fn newUuid(a: Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    randomBytes(io, &bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}

test "uuid shape" {
    const u = try newUuid(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(u);
    try std.testing.expectEqual(@as(usize, 36), u.len);
    try std.testing.expectEqual(@as(u8, '-'), u[8]);
    try std.testing.expectEqual(@as(u8, '4'), u[14]);
}
