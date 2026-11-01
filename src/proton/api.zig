// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! HTTPS access to the Proton VPN REST API.
//!
//! Every response is JSON with a `Code` field; 1000 and 1001 mean success,
//! anything else carries an `Error` message. Requests are blocking and are
//! made from the worker thread in proton.zig.
const std = @import("std");
const http = std.http;
const json = std.json;

const log = std.log.scoped(.proton_api);
const Allocator = std.mem.Allocator;

pub const base_url = "https://vpn-api.proton.me";
/// Sent as `x-pm-appversion`. The official Linux CLI sends
/// `linux-vpn-cli@<proton-vpn-api-core version>`; the API rejects versions
/// it considers outdated (code 5003), so bump this when that happens.
pub const app_version = "linux-vpn-cli@5.8.11";
pub const user_agent = "ProtonVPN/5.8.11 (Linux; wayman)";

pub const Error = error{ Api, OutOfMemory };

pub const Failure = struct {
    status: u16 = 0,
    code: i64 = 0,
    message: []u8,
};

pub const Response = struct {
    parsed: json.Parsed(json.Value),

    pub fn deinit(self: *Response) void {
        self.parsed.deinit();
    }

    pub fn root(self: *const Response) json.Value {
        return self.parsed.value;
    }

    pub fn object(self: *const Response) ?json.ObjectMap {
        return switch (self.parsed.value) {
            .object => |o| o,
            else => null,
        };
    }

    pub fn str(self: *const Response, key: []const u8) ?[]const u8 {
        return getStr(self.object() orelse return null, key);
    }

    pub fn int(self: *const Response, key: []const u8) ?i64 {
        return getInt(self.object() orelse return null, key);
    }
};

pub fn getStr(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(o: json.ObjectMap, key: []const u8) ?i64 {
    return switch (o.get(key) orelse return null) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn getFloat(o: json.ObjectMap, key: []const u8) ?f64 {
    return switch (o.get(key) orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

pub fn getObject(o: json.ObjectMap, key: []const u8) ?json.ObjectMap {
    return switch (o.get(key) orelse return null) {
        .object => |x| x,
        else => null,
    };
}

pub fn getArray(o: json.ObjectMap, key: []const u8) ?[]json.Value {
    return switch (o.get(key) orelse return null) {
        .array => |a| a.items,
        else => null,
    };
}

pub const Api = struct {
    gpa: Allocator,
    client: http.Client,
    uid: ?[]u8 = null,
    access_token: ?[]u8 = null,
    last_failure: ?Failure = null,

    pub fn init(gpa: Allocator, io: std.Io) Api {
        return .{ .gpa = gpa, .client = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(self: *Api) void {
        self.client.deinit();
        self.clearSession();
        self.clearFailure();
    }

    pub fn clearSession(self: *Api) void {
        if (self.uid) |u| self.gpa.free(u);
        if (self.access_token) |t| self.gpa.free(t);
        self.uid = null;
        self.access_token = null;
    }

    pub fn setSession(self: *Api, uid: []const u8, access_token: []const u8) !void {
        const u = try self.gpa.dupe(u8, uid);
        errdefer self.gpa.free(u);
        const t = try self.gpa.dupe(u8, access_token);
        self.clearSession();
        self.uid = u;
        self.access_token = t;
    }

    fn clearFailure(self: *Api) void {
        if (self.last_failure) |f| self.gpa.free(f.message);
        self.last_failure = null;
    }

    fn fail(self: *Api, status: u16, code: i64, message: []const u8) Error {
        self.clearFailure();
        self.last_failure = .{ .status = status, .code = code, .message = self.gpa.dupe(u8, message) catch return error.OutOfMemory };
        return error.Api;
    }

    /// Human-readable description of the last failure.
    pub fn failureText(self: *const Api) []const u8 {
        const f = self.last_failure orelse return "unknown error";
        return f.message;
    }

    pub fn failureStatus(self: *const Api) u16 {
        return if (self.last_failure) |f| f.status else 0;
    }

    pub fn failureCode(self: *const Api) i64 {
        return if (self.last_failure) |f| f.code else 0;
    }

    pub fn get(self: *Api, path: []const u8, extra: []const http.Header) Error!Response {
        return self.request(.GET, path, null, extra);
    }

    pub fn post(self: *Api, path: []const u8, body: []const u8) Error!Response {
        return self.request(.POST, path, body, &.{});
    }

    pub fn delete(self: *Api, path: []const u8) Error!Response {
        return self.request(.DELETE, path, null, &.{});
    }

    pub fn request(self: *Api, method: http.Method, path: []const u8, body: ?[]const u8, extra: []const http.Header) Error!Response {
        const url = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ base_url, path });
        defer self.gpa.free(url);

        var headers: std.ArrayList(http.Header) = .empty;
        defer headers.deinit(self.gpa);
        try headers.append(self.gpa, .{ .name = "x-pm-appversion", .value = app_version });
        try headers.append(self.gpa, .{ .name = "Accept", .value = "application/json" });
        if (self.uid) |u| try headers.append(self.gpa, .{ .name = "x-pm-uid", .value = u });
        try headers.appendSlice(self.gpa, extra);

        var auth_buf: [4096]u8 = undefined;
        const authorization: http.Client.Request.Headers.Value = if (self.access_token) |t|
            .{ .override = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch return error.OutOfMemory }
        else
            .default;

        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();

        log.debug("{t} {s}", .{ method, path });
        const result = self.client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = body,
            .response_writer = &out.writer,
            .extra_headers = headers.items,
            .headers = .{
                .user_agent = .{ .override = user_agent },
                .content_type = if (body != null) .{ .override = "application/json" } else .default,
                .authorization = authorization,
            },
        }) catch |err| {
            var buf: [128]u8 = undefined;
            return self.fail(0, 0, std.fmt.bufPrint(&buf, "network error: {t}", .{err}) catch "network error");
        };
        const status: u16 = @backingInt(result.status);
        const text = out.written();

        var parsed = json.parseFromSlice(json.Value, self.gpa, text, .{}) catch {
            var buf: [96]u8 = undefined;
            return self.fail(status, 0, std.fmt.bufPrint(&buf, "HTTP {d}: unreadable reply", .{status}) catch "unreadable reply");
        };
        errdefer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return self.fail(status, 0, "unexpected reply"),
        };
        const code = getInt(obj, "Code") orelse 0;
        if (status >= 400 or (code != 1000 and code != 1001)) {
            const message = getStr(obj, "Error") orelse "request failed";
            var buf: [512]u8 = undefined;
            log.warn("{t} {s} -> HTTP {d}, code {d}: {s}", .{ method, path, status, code, message });
            return self.fail(status, code, std.fmt.bufPrint(&buf, "{s}", .{message}) catch message);
        }
        return .{ .parsed = parsed };
    }
};

/// Serialises `value` as JSON for a request body.
pub fn encode(gpa: Allocator, value: anytype) ![]u8 {
    return json.Stringify.valueAlloc(gpa, value, .{});
}

pub fn base64Decode(gpa: Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    const size = std.base64.standard.Decoder.calcSizeForSlice(trimmed) catch return error.InvalidBase64;
    const out = try gpa.alloc(u8, size);
    errdefer gpa.free(out);
    std.base64.standard.Decoder.decode(out, trimmed) catch return error.InvalidBase64;
    return out;
}

pub fn base64Encode(gpa: Allocator, data: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    _ = std.base64.standard.Encoder.encode(out, data);
    return out;
}

/// Extracts the base64 payload of a PGP clear-signed message such as the
/// `Modulus` field of `/auth/info`. The signature itself is not verified;
/// TLS protects the transport.
pub fn clearsignedPayload(armored: []const u8) ![]const u8 {
    const begin = "-----BEGIN PGP SIGNED MESSAGE-----";
    const sig = "-----BEGIN PGP SIGNATURE-----";
    const start = std.mem.indexOf(u8, armored, begin) orelse return error.NotClearsigned;
    const body_start = std.mem.indexOf(u8, armored[start..], "\n\n") orelse return error.NotClearsigned;
    const rest = armored[start + body_start + 2 ..];
    const end = std.mem.indexOf(u8, rest, sig) orelse return error.NotClearsigned;
    return std.mem.trim(u8, rest[0..end], &std.ascii.whitespace);
}

test "clearsigned payload extraction" {
    const msg =
        \\-----BEGIN PGP SIGNED MESSAGE-----
        \\Hash: SHA256
        \\
        \\AAAAbase64==
        \\-----BEGIN PGP SIGNATURE-----
        \\Version: ProtonMail
        \\
        \\xyz
        \\-----END PGP SIGNATURE-----
    ;
    try std.testing.expectEqualStrings("AAAAbase64==", try clearsignedPayload(msg));
}

test "json helpers" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"Code\":1000,\"Name\":\"x\",\"Score\":1.5,\"VPN\":{\"MaxTier\":2}}", .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1000), getInt(o, "Code").?);
    try std.testing.expectEqualStrings("x", getStr(o, "Name").?);
    try std.testing.expectEqual(@as(f64, 1.5), getFloat(o, "Score").?);
    try std.testing.expectEqual(@as(i64, 2), getInt(getObject(o, "VPN").?, "MaxTier").?);
}
