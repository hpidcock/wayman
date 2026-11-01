// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! Proton's SRP-6a variant, as used by `/auth/info` and `/auth`.
//!
//! Differences from textbook SRP: all integers are 2048-bit little-endian,
//! the hash is "PMHash" (four SHA-512s concatenated, 256 bytes), and the
//! password is first run through bcrypt with a salt derived from the server
//! salt plus the string "proton".
const std = @import("std");

const Allocator = std.mem.Allocator;
const Managed = std.math.big.int.Managed;
const Sha512 = std.crypto.hash.sha2.Sha512;
const bcrypt = std.crypto.pwhash.bcrypt;

pub const len: usize = 256;
pub const Bytes = [len]u8;

/// PMHash: SHA512(data||0) || SHA512(data||1) || SHA512(data||2) || SHA512(data||3).
pub fn pmhash(parts: []const []const u8) Bytes {
    var out: Bytes = undefined;
    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        var h = Sha512.init(.{});
        for (parts) |p| h.update(p);
        h.update(&[_]u8{i});
        h.final(out[@as(usize, i) * 64 ..][0..64]);
    }
    return out;
}

fn fromLittle(gpa: Allocator, bytes: []const u8) !Managed {
    // Build a big-endian hex string and parse it.
    const hex = try gpa.alloc(u8, bytes.len * 2);
    defer gpa.free(hex);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        const j = bytes.len - 1 - i;
        hex[j * 2] = digits[b >> 4];
        hex[j * 2 + 1] = digits[b & 0xf];
    }
    var m = try Managed.init(gpa);
    errdefer m.deinit();
    try m.setString(16, hex);
    return m;
}

fn toLittle(m: *const Managed) Bytes {
    var out: Bytes = @splat(0);
    m.toConst().writeTwosComplement(&out, .little);
    return out;
}

/// base^exp mod modulus by square-and-multiply.
pub fn powMod(gpa: Allocator, base: *const Managed, exp: *const Managed, modulus: *const Managed) !Managed {
    var result = try Managed.initSet(gpa, 1);
    errdefer result.deinit();
    var b = try Managed.init(gpa);
    defer b.deinit();
    var q = try Managed.init(gpa);
    defer q.deinit();
    var tmp = try Managed.init(gpa);
    defer tmp.deinit();
    try q.divFloor(&b, base, modulus); // b = base mod modulus

    const e = exp.toConst();
    const limb_bits = @bitSizeOf(std.math.big.Limb);
    var bit = e.bitCountAbs();
    while (bit > 0) {
        bit -= 1;
        try tmp.sqr(&result);
        try q.divFloor(&result, &tmp, modulus);
        const set = (e.limbs[bit / limb_bits] >> @intCast(bit % limb_bits)) & 1 == 1;
        if (set) {
            try tmp.mul(&result, &b);
            try q.divFloor(&result, &tmp, modulus);
        }
    }
    return result;
}

const bcrypt_alphabet = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/// The bcrypt step of Proton's password hashing (auth versions 3 and 4):
/// `bcrypt("$2y$10$" + b64((salt + "proton")[:16]), password[:72])`,
/// returned as the 60-character crypt string.
pub fn bcryptPassword(password: []const u8, salt: []const u8, out: *[bcrypt.hash_length]u8) ![]const u8 {
    var raw_salt: [16]u8 = undefined;
    var n: usize = 0;
    for (salt) |b| {
        if (n == 16) break;
        raw_salt[n] = b;
        n += 1;
    }
    for ("proton") |b| {
        if (n == 16) break;
        raw_salt[n] = b;
        n += 1;
    }
    if (n < 16) return error.SaltTooShort;
    const truncated = password[0..@min(password.len, 72)];
    const str = try bcrypt.strHashWithSalt(truncated, .{
        .params = .{ .rounds_log = 10, .silently_truncate_password = true },
        .encoding = .crypt,
    }, out, raw_salt);
    // Proton hashes the "$2y$" form of the string.
    out[2] = 'y';
    return str;
}

pub const Client = struct {
    gpa: Allocator,
    n: Managed,
    g: Managed,
    k: Managed,
    a: Managed,
    big_a: Managed,
    a_bytes: Bytes,
    client_proof: Bytes = undefined,
    expected_server_proof: Bytes = undefined,

    /// `modulus` is the decoded 256-byte little-endian modulus from
    /// `/auth/info`; `secret` the 32 random bytes for the ephemeral.
    pub fn init(gpa: Allocator, modulus: *const Bytes, secret: [32]u8) !Client {
        var n = try fromLittle(gpa, modulus);
        errdefer n.deinit();
        var g = try Managed.initSet(gpa, 2);
        errdefer g.deinit();

        var g_bytes: Bytes = @splat(0);
        g_bytes[0] = 2;
        var k = try fromLittle(gpa, &pmhash(&.{ &g_bytes, modulus }));
        errdefer k.deinit();

        var secret_bytes = secret;
        secret_bytes[31] |= 0x80;
        var a = try fromLittle(gpa, &secret_bytes);
        errdefer a.deinit();

        var big_a = try powMod(gpa, &g, &a, &n);
        errdefer big_a.deinit();

        return .{
            .gpa = gpa,
            .n = n,
            .g = g,
            .k = k,
            .a = a,
            .big_a = big_a,
            .a_bytes = toLittle(&big_a),
        };
    }

    pub fn deinit(self: *Client) void {
        self.n.deinit();
        self.g.deinit();
        self.k.deinit();
        self.a.deinit();
        self.big_a.deinit();
    }

    /// The client ephemeral `A` to send as `ClientEphemeral`.
    pub fn challenge(self: *const Client) Bytes {
        return self.a_bytes;
    }

    /// Computes the client proof `M1` from the server's salt and ephemeral.
    pub fn processChallenge(self: *Client, salt: []const u8, server_ephemeral: *const Bytes, password: []const u8, version: u32) !Bytes {
        if (version != 3 and version != 4) return error.UnsupportedAuthVersion;
        const gpa = self.gpa;

        var big_b = try fromLittle(gpa, server_ephemeral);
        defer big_b.deinit();
        var q = try Managed.init(gpa);
        defer q.deinit();
        var r = try Managed.init(gpa);
        defer r.deinit();
        try q.divFloor(&r, &big_b, &self.n);
        if (r.eqlZero()) return error.InvalidServerEphemeral;

        const u_bytes = pmhash(&.{ &self.a_bytes, server_ephemeral });
        var u = try fromLittle(gpa, &u_bytes);
        defer u.deinit();
        if (u.eqlZero()) return error.InvalidServerEphemeral;

        // x = PMHash(bcrypt(password) || N)
        var bcrypt_buf: [bcrypt.hash_length]u8 = undefined;
        const hashed = try bcryptPassword(password, salt, &bcrypt_buf);
        const n_bytes = toLittle(&self.n);
        const x_bytes = pmhash(&.{ hashed, &n_bytes });
        var x = try fromLittle(gpa, &x_bytes);
        defer x.deinit();

        var v = try powMod(gpa, &self.g, &x, &self.n);
        defer v.deinit();

        // base = (B - k*v) mod N
        var kv = try Managed.init(gpa);
        defer kv.deinit();
        try kv.mul(&self.k, &v);
        var base = try Managed.init(gpa);
        defer base.deinit();
        try base.sub(&big_b, &kv);
        try q.divFloor(&r, &base, &self.n);
        try base.copy(r.toConst());

        // exp = a + u*x
        var ux = try Managed.init(gpa);
        defer ux.deinit();
        try ux.mul(&u, &x);
        var exp = try Managed.init(gpa);
        defer exp.deinit();
        try exp.add(&self.a, &ux);

        var s = try powMod(gpa, &base, &exp, &self.n);
        defer s.deinit();
        const key = toLittle(&s);

        self.client_proof = pmhash(&.{ &self.a_bytes, server_ephemeral, &key });
        self.expected_server_proof = pmhash(&.{ &self.a_bytes, &self.client_proof, &key });
        return self.client_proof;
    }

    pub fn verifyServerProof(self: *const Client, proof: []const u8) bool {
        if (proof.len != len) return false;
        return std.crypto.timing_safe.eql(Bytes, self.expected_server_proof, proof[0..len].*);
    }
};

// ---- tests ------------------------------------------------------------------

test "pmhash is four domain-separated sha512s" {
    const out = pmhash(&.{ "ab", "c" });
    var expected: [64]u8 = undefined;
    Sha512.hash("abc\x02", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, out[128..192]);
}

test "little-endian round trip" {
    var bytes: Bytes = @splat(0);
    bytes[0] = 0x34;
    bytes[1] = 0x12;
    bytes[255] = 0x80;
    var m = try fromLittle(std.testing.allocator, &bytes);
    defer m.deinit();
    try std.testing.expectEqualSlices(u8, &bytes, &toLittle(&m));
}

test "powMod" {
    const gpa = std.testing.allocator;
    var b = try Managed.initSet(gpa, 4);
    defer b.deinit();
    var e = try Managed.initSet(gpa, 13);
    defer e.deinit();
    var m = try Managed.initSet(gpa, 497);
    defer m.deinit();
    var r = try powMod(gpa, &b, &e, &m);
    defer r.deinit();
    try std.testing.expect(r.toConst().orderAgainstScalar(445) == .eq);
}

test "bcrypt crypt string matches the reference vector" {
    // Reference vector from the bcrypt test suite (with the $2y$ prefix Proton uses).
    var out: [bcrypt.hash_length]u8 = undefined;
    const salt_chars = "CCCCCCCCCCCCCCCCCCCCC.";
    var raw: [16]u8 = undefined;
    // Decode the bcrypt base64 salt so we can feed raw bytes through bcryptPassword's path.
    var bits: u32 = 0;
    var nbits: u5 = 0;
    var n: usize = 0;
    for (salt_chars) |ch| {
        const v: u32 = @intCast(std.mem.indexOfScalar(u8, bcrypt_alphabet, ch).?);
        bits = (bits << 6) | v;
        nbits += 6;
        if (nbits >= 8) {
            nbits -= 8;
            if (n < 16) raw[n] = @intCast((bits >> nbits) & 0xff);
            n += 1;
        }
    }
    const str = try bcrypt.strHashWithSalt("U*U", .{
        .params = .{ .rounds_log = 5, .silently_truncate_password = true },
        .encoding = .crypt,
    }, &out, raw);
    try std.testing.expectEqualStrings("$2b$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW", str);
}

test "srp round trip against a simulated server" {
    const gpa = std.testing.allocator;
    // A random 2048-bit odd modulus is good enough to exercise the arithmetic.
    var modulus: Bytes = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&modulus);
    modulus[0] |= 1;
    modulus[255] |= 0x80;

    var secret: [32]u8 = undefined;
    prng.random().bytes(&secret);
    var client = try Client.init(gpa, &modulus, secret);
    defer client.deinit();

    const salt = "0123456789";
    const password = "correct horse battery staple";

    // Server side: v = g^x, B = k*v + g^b, S = (A * v^u)^b.
    var bcrypt_buf: [bcrypt.hash_length]u8 = undefined;
    const hashed = try bcryptPassword(password, salt, &bcrypt_buf);
    var x = try fromLittle(gpa, &pmhash(&.{ hashed, &modulus }));
    defer x.deinit();
    var v = try powMod(gpa, &client.g, &x, &client.n);
    defer v.deinit();
    var b = try Managed.initSet(gpa, 123456789);
    defer b.deinit();
    var gb = try powMod(gpa, &client.g, &b, &client.n);
    defer gb.deinit();
    var kv = try Managed.init(gpa);
    defer kv.deinit();
    try kv.mul(&client.k, &v);
    var sum = try Managed.init(gpa);
    defer sum.deinit();
    try sum.add(&kv, &gb);
    var q = try Managed.init(gpa);
    defer q.deinit();
    var big_b = try Managed.init(gpa);
    defer big_b.deinit();
    try q.divFloor(&big_b, &sum, &client.n);
    const b_bytes = toLittle(&big_b);

    const m1 = try client.processChallenge(salt, &b_bytes, password, 4);

    var u = try fromLittle(gpa, &pmhash(&.{ &client.a_bytes, &b_bytes }));
    defer u.deinit();
    var vu = try powMod(gpa, &v, &u, &client.n);
    defer vu.deinit();
    var avu = try Managed.init(gpa);
    defer avu.deinit();
    try avu.mul(&client.big_a, &vu);
    var s = try powMod(gpa, &avu, &b, &client.n);
    defer s.deinit();
    const key = toLittle(&s);
    const expected_m1 = pmhash(&.{ &client.a_bytes, &b_bytes, &key });
    try std.testing.expectEqualSlices(u8, &expected_m1, &m1);
    const m2 = pmhash(&.{ &client.a_bytes, &m1, &key });
    try std.testing.expect(client.verifyServerProof(&m2));
    var wrong = m2;
    wrong[0] ^= 1;
    try std.testing.expect(!client.verifyServerProof(&wrong));
}
