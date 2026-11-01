// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! Cairo drawing shared by the tray icon and the popup: signal bars, lock
//! glyph, and conversion of a cairo surface into the StatusNotifierItem
//! pixmap format.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1.0,

    pub fn rgb(hex: u24) Color {
        return .{
            .r = @as(f64, @floatFromInt((hex >> 16) & 0xff)) / 255.0,
            .g = @as(f64, @floatFromInt((hex >> 8) & 0xff)) / 255.0,
            .b = @as(f64, @floatFromInt(hex & 0xff)) / 255.0,
        };
    }

    pub fn withAlpha(col: Color, a: f64) Color {
        return .{ .r = col.r, .g = col.g, .b = col.b, .a = a };
    }
};

pub fn setColor(cr: *c.cairo_t, col: Color) void {
    c.cairo_set_source_rgba(cr, col.r, col.g, col.b, col.a);
}

pub fn roundedRect(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const r = @min(radius, @min(w, h) / 2.0);
    const pi = std.math.pi;
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + w - r, y + r, r, -pi / 2.0, 0);
    c.cairo_arc(cr, x + w - r, y + h - r, r, 0, pi / 2.0);
    c.cairo_arc(cr, x + r, y + h - r, r, pi / 2.0, pi);
    c.cairo_arc(cr, x + r, y + r, r, pi, 3.0 * pi / 2.0);
    c.cairo_close_path(cr);
}

/// Four ascending signal bars inside a `size`×`size` box at (x, y).
/// `bars` of them (0..4) are drawn in `fill`, the rest in `dim`.
pub fn drawBars(cr: *c.cairo_t, x: f64, y: f64, size: f64, bars: u8, fill: Color, dim: Color) void {
    const gap = size * 0.09;
    const bar_w = (size - 3.0 * gap) / 4.0;
    const heights = [4]f64{ 0.32, 0.54, 0.77, 1.0 };
    const radius = bar_w * 0.25;
    for (heights, 0..) |frac, i| {
        const h = size * frac;
        const bx = x + @as(f64, @floatFromInt(i)) * (bar_w + gap);
        const by = y + size - h;
        setColor(cr, if (i < bars) fill else dim);
        roundedRect(cr, bx, by, bar_w, h, radius);
        c.cairo_fill(cr);
    }
}

/// A diagonal strike through a `size`×`size` box, used for "off".
pub fn drawStrike(cr: *c.cairo_t, x: f64, y: f64, size: f64, col: Color) void {
    setColor(cr, col);
    c.cairo_set_line_width(cr, @max(1.5, size * 0.1));
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_move_to(cr, x + size * 0.1, y + size * 0.1);
    c.cairo_line_to(cr, x + size * 0.9, y + size * 0.9);
    c.cairo_stroke(cr);
}

/// A small padlock inside a `size`×`size` box at (x, y).
pub fn drawLock(cr: *c.cairo_t, x: f64, y: f64, size: f64, col: Color) void {
    setColor(cr, col);
    const body_w = size * 0.7;
    const body_h = size * 0.5;
    const body_x = x + (size - body_w) / 2.0;
    const body_y = y + size - body_h;
    roundedRect(cr, body_x, body_y, body_w, body_h, size * 0.1);
    c.cairo_fill(cr);
    const shackle_r = size * 0.22;
    c.cairo_set_line_width(cr, @max(1.2, size * 0.11));
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + size / 2.0, body_y - shackle_r * 0.3, shackle_r, std.math.pi, 2.0 * std.math.pi);
    c.cairo_stroke(cr);
}

pub const Look = enum { off, disconnected, connecting, connected };

/// A tray pixmap in the StatusNotifierItem format: ARGB32, network byte
/// order, non-premultiplied. Caller owns the returned bytes.
pub fn renderTrayPixmap(gpa: std.mem.Allocator, size: u32, bars: u8, look: Look, color: Color, vpn_badge: bool) ![]u8 {
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(size), @intCast(size)) orelse return error.OutOfMemory;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return error.OutOfMemory;
    defer c.cairo_destroy(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    const white = color.withAlpha(1.0);
    const fs: f64 = @floatFromInt(size);
    const inset = fs * 0.08;
    const box = fs - 2.0 * inset;
    switch (look) {
        .connected => drawBars(cr, inset, inset, box, bars, white, white.withAlpha(0.25)),
        .connecting => drawBars(cr, inset, inset, box, bars, white.withAlpha(0.6), white.withAlpha(0.25)),
        .disconnected => drawBars(cr, inset, inset, box, 0, white, white.withAlpha(0.35)),
        .off => {
            drawBars(cr, inset, inset, box, 0, white, white.withAlpha(0.25));
            drawStrike(cr, inset, inset, box, white.withAlpha(0.9));
        },
    }
    if (vpn_badge) {
        // A small padlock in the bottom-right corner, punched out of the bars.
        const badge = fs * 0.5;
        const bx = fs - badge;
        const by = fs - badge;
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
        c.cairo_arc(cr, bx + badge / 2.0, by + badge / 2.0, badge * 0.62, 0, 2.0 * std.math.pi);
        c.cairo_fill(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
        drawLock(cr, bx, by, badge, white);
    }
    c.cairo_surface_flush(surface);

    const data = c.cairo_image_surface_get_data(surface) orelse return error.OutOfMemory;
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
    const out = try gpa.alloc(u8, @as(usize, size) * size * 4);
    errdefer gpa.free(out);

    var y: usize = 0;
    while (y < size) : (y += 1) {
        var x: usize = 0;
        while (x < size) : (x += 1) {
            const src = data[y * stride + x * 4 ..][0..4];
            const px = std.mem.readInt(u32, src, builtin.cpu.arch.endian());
            const a: u32 = px >> 24;
            var r: u32 = (px >> 16) & 0xff;
            var g: u32 = (px >> 8) & 0xff;
            var b: u32 = px & 0xff;
            if (a != 0 and a != 255) {
                r = @min(255, (r * 255 + a / 2) / a);
                g = @min(255, (g * 255 + a / 2) / a);
                b = @min(255, (b * 255 + a / 2) / a);
            }
            const dst = out[(y * size + x) * 4 ..][0..4];
            dst[0] = @intCast(a);
            dst[1] = @intCast(r);
            dst[2] = @intCast(g);
            dst[3] = @intCast(b);
        }
    }
    return out;
}

test "tray pixmap has the expected size and opaque bars" {
    const px = try renderTrayPixmap(std.testing.allocator, 22, 4, .connected, Color.rgb(0xffffff), false);
    defer std.testing.allocator.free(px);
    try std.testing.expectEqual(@as(usize, 22 * 22 * 4), px.len);
    // The bottom-left corner of the first bar is opaque white.
    const idx = ((22 - 3) * 22 + 2) * 4;
    try std.testing.expectEqual(@as(u8, 255), px[idx]);
    try std.testing.expectEqual(@as(u8, 255), px[idx + 1]);
}
