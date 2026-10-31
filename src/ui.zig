// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! The popup: a list of networks with signal strength, a Wi-Fi toggle, an
//! inline password prompt, and connect/disconnect actions.
const std = @import("std");
const c = @import("c");
const wl = @import("wl.zig");
const nm = @import("nm.zig");
const icon = @import("icon.zig");

const log = std.log.scoped(.ui);
const Allocator = std.mem.Allocator;
const Color = icon.Color;

pub const width: u32 = 380;
const pad: f64 = 14;
const header_h: f64 = 54;
const row_h: f64 = 50;
const entry_h: f64 = 60;
const message_h: f64 = 44;
const footer_h: f64 = 36;
const max_list_h: f64 = 520;
const corner: f64 = 12;

const theme = struct {
    const bg = Color.rgb(0x1e1e2e).withAlpha(0.97);
    const border = Color.rgb(0xffffff).withAlpha(0.08);
    const text = Color.rgb(0xcdd6f4);
    const subtext = Color.rgb(0xa6adc8);
    const dim = Color.rgb(0xffffff).withAlpha(0.22);
    const hover = Color.rgb(0xffffff).withAlpha(0.06);
    const accent = Color.rgb(0x89b4fa);
    const on_accent = Color.rgb(0x1e1e2e);
    const danger = Color.rgb(0xf38ba8);
    const field = Color.rgb(0xffffff).withAlpha(0.05);
    const knob = Color.rgb(0xffffff);
};

const font_regular = "Sans 10.5";
const font_bold = "Sans Bold 10.5";
const font_title = "Sans Bold 12";
const font_small = "Sans 9";

const HitKind = enum { row, toggle, disconnect, cancel, connect, reveal };

const Hit = struct {
    kind: HitKind,
    index: usize = 0,
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    fn contains(h: Hit, px: f64, py: f64) bool {
        return px >= h.x and px < h.x + h.w and py >= h.y and py < h.y + h.h;
    }

    fn same(a: ?Hit, b: ?Hit) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.?.kind == b.?.kind and a.?.index == b.?.index;
    }
};

const Entry = struct {
    ssid: [:0]u8,
    text: std.ArrayList(u8) = .empty,
    reveal: bool = false,
};

const Point = struct { x: f64, y: f64 };

pub const Ui = struct {
    gpa: Allocator,
    wl: *wl.Client,
    nm: *nm.Client,
    open: bool = false,
    needs_redraw: bool = false,
    hits: std.ArrayList(Hit) = .empty,
    hover: ?Hit = null,
    pointer: ?Point = null,
    scroll: f64 = 0,
    content_h: f64 = 0,
    list_h: f64 = 0,
    entry: ?Entry = null,

    pub fn init(self: *Ui, gpa: Allocator, wl_client: *wl.Client, nm_client: *nm.Client) void {
        self.* = .{ .gpa = gpa, .wl = wl_client, .nm = nm_client };
    }

    pub fn deinit(self: *Ui) void {
        self.clearEntry();
        self.hits.deinit(self.gpa);
    }

    // ---- open / close -----------------------------------------------------

    pub fn toggle(self: *Ui) void {
        if (self.open) self.close() else self.openPopup();
    }

    pub fn openPopup(self: *Ui) void {
        if (self.open) return;
        self.scroll = 0;
        self.hover = null;
        self.pointer = null;
        const h = self.desiredHeight();
        self.wl.openPopup(width, h) catch |err| {
            log.err("cannot open the popup: {t}", .{err});
            return;
        };
        self.open = true;
        log.debug("popup opened, {d}x{d}", .{ width, h });
        self.nm.requestScan();
    }

    pub fn close(self: *Ui) void {
        if (!self.open) return;
        self.wl.closePopup();
        self.onPopupClosed();
    }

    /// The surface is gone (closed by us or by the compositor).
    pub fn onPopupClosed(self: *Ui) void {
        log.debug("popup closed", .{});
        self.open = false;
        self.needs_redraw = false;
        self.clearEntry();
        self.hover = null;
        self.pointer = null;
    }

    pub fn onPopupReady(self: *Ui) void {
        self.needs_redraw = true;
    }

    pub fn onModelChanged(self: *Ui) void {
        if (!self.open) return;
        if (self.entry) |e| {
            const net = self.nm.findNetwork(e.ssid);
            if (net == null or net.?.active) self.clearEntry();
        }
        self.relayout();
    }

    fn relayout(self: *Ui) void {
        const h = self.desiredHeight();
        _ = self.wl.popupResize(width, h);
        self.needs_redraw = true;
    }

    fn clearEntry(self: *Ui) void {
        if (self.entry) |*e| {
            @memset(e.text.items, 0);
            e.text.deinit(self.gpa);
            self.gpa.free(e.ssid);
            self.entry = null;
        }
    }

    fn desiredHeight(self: *Ui) u32 {
        const m = self.nm.model;
        var list: f64 = message_h;
        if (m.status != .disabled and m.status != .no_device and m.networks.len > 0) {
            list = @as(f64, @floatFromInt(m.networks.len)) * row_h;
            if (self.entry != null) list += entry_h;
        }
        self.content_h = list;
        self.list_h = @min(list, max_list_h);
        var h = header_h + self.list_h + pad / 2;
        if (self.nm.lastError() != null) h += footer_h;
        return @intFromFloat(@ceil(h));
    }

    // ---- input ------------------------------------------------------------

    fn hitTest(self: *Ui, x: f64, y: f64) ?Hit {
        var i = self.hits.items.len;
        while (i > 0) {
            i -= 1;
            const h = self.hits.items[i];
            if (h.contains(x, y)) return h;
        }
        return null;
    }

    fn updateHover(self: *Ui) void {
        const new_hover = if (self.pointer) |p| self.hitTest(p.x, p.y) else null;
        if (!Hit.same(self.hover, new_hover)) {
            self.hover = new_hover;
            self.needs_redraw = true;
        }
    }

    pub fn onPointerMotion(self: *Ui, x: f64, y: f64) void {
        self.pointer = .{ .x = x, .y = y };
        self.updateHover();
    }

    pub fn onPointerLeave(self: *Ui) void {
        self.pointer = null;
        self.updateHover();
    }

    pub fn onPointerButton(self: *Ui, button: u32, pressed: bool) void {
        if (!pressed or button != c.BTN_LEFT) return;
        const p = self.pointer orelse return;
        const hit = self.hitTest(p.x, p.y) orelse return;
        self.activate(hit);
    }

    pub fn onAxis(self: *Ui, dy: f64) void {
        const max_scroll = @max(0.0, self.content_h - self.list_h);
        const new_scroll = std.math.clamp(self.scroll + dy, 0.0, max_scroll);
        if (new_scroll != self.scroll) {
            self.scroll = new_scroll;
            self.needs_redraw = true;
        }
    }

    pub fn onKey(self: *Ui, sym: u32, text: []const u8, mods: wl.Modifiers) void {
        switch (sym) {
            c.XKB_KEY_Escape => {
                if (self.entry != null) {
                    self.clearEntry();
                    self.relayout();
                } else {
                    self.close();
                }
            },
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => self.submitEntry(),
            c.XKB_KEY_BackSpace => {
                if (self.entry) |*e| {
                    if (e.text.items.len > 0) {
                        var n = e.text.items.len - 1;
                        // Step back over UTF-8 continuation bytes.
                        while (n > 0 and (e.text.items[n] & 0xc0) == 0x80) n -= 1;
                        e.text.shrinkRetainingCapacity(n);
                        self.needs_redraw = true;
                    }
                }
            },
            else => {
                if (self.entry) |*e| {
                    if (mods.ctrl) {
                        if (sym == c.XKB_KEY_u) {
                            e.text.clearRetainingCapacity();
                            self.needs_redraw = true;
                        }
                        return;
                    }
                    if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) {
                        e.text.appendSlice(self.gpa, text) catch {};
                        self.needs_redraw = true;
                    }
                }
            },
        }
    }

    pub fn onDismiss(self: *Ui) void {
        self.close();
    }

    fn activate(self: *Ui, hit: Hit) void {
        const m = self.nm.model;
        switch (hit.kind) {
            .toggle => {
                self.nm.setWirelessEnabled(!m.wireless_enabled) catch |err| {
                    self.nm.setErrorFmt("Couldn't switch Wi-Fi: {t}", .{err});
                };
            },
            .disconnect, .cancel => {
                self.nm.disconnect() catch |err| {
                    self.nm.setErrorFmt("Couldn't disconnect: {t}", .{err});
                };
            },
            .connect => self.submitEntry(),
            .reveal => {
                if (self.entry) |*e| e.reveal = !e.reveal;
            },
            .row => {
                if (hit.index >= m.networks.len) return;
                const net = m.networks[hit.index];
                if (net.active) return;
                self.nm.clearError();
                if (net.saved == null and !net.security.canAutoCreate()) {
                    self.nm.setErrorFmt("{s} networks need a profile created with netplan or nmcli", .{net.security.label()});
                } else if (net.saved != null or !net.security.needsPassword()) {
                    self.nm.connect(net.ssid, null) catch |err| {
                        self.nm.setErrorFmt("Couldn't join {s}: {t}", .{ net.ssid, err });
                    };
                } else {
                    self.clearEntry();
                    const ssid = self.gpa.dupeSentinel(u8, net.ssid, 0) catch return;
                    self.entry = .{ .ssid = ssid };
                }
            },
        }
        self.relayout();
    }

    fn submitEntry(self: *Ui) void {
        const e = &(self.entry orelse return);
        if (e.text.items.len < 8) {
            self.nm.setErrorFmt("Wi-Fi passwords are at least 8 characters", .{});
            self.relayout();
            return;
        }
        self.nm.connect(e.ssid, e.text.items) catch |err| {
            self.nm.setErrorFmt("Couldn't join {s}: {t}", .{ e.ssid, err });
            self.relayout();
            return;
        };
        self.clearEntry();
        self.relayout();
    }

    // ---- drawing ----------------------------------------------------------

    pub fn render(self: *Ui) void {
        self.needs_redraw = false;
        const frame = self.wl.beginFrame() orelse return;
        log.debug("rendering {d}x{d}", .{ frame.width, frame.height });
        defer self.wl.endFrame(frame);
        const cr = frame.cr;
        const w = frame.width;
        const h = frame.height;
        self.hits.clearRetainingCapacity();

        // Transparent background with a rounded panel.
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
        icon.roundedRect(cr, 0.5, 0.5, w - 1, h - 1, corner);
        icon.setColor(cr, theme.bg);
        c.cairo_fill_preserve(cr);
        icon.setColor(cr, theme.border);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);

        self.drawHeader(cr, w);

        const m = self.nm.model;
        const list_top = header_h;
        const max_scroll = @max(0.0, self.content_h - self.list_h);
        self.scroll = std.math.clamp(self.scroll, 0.0, max_scroll);

        c.cairo_save(cr);
        c.cairo_rectangle(cr, 0, list_top, w, self.list_h);
        c.cairo_clip(cr);
        var y = list_top - self.scroll;
        switch (m.status) {
            .no_device => drawMessage(cr, w, y, "No Wi-Fi device found"),
            .disabled => drawMessage(cr, w, y, "Wi-Fi is off"),
            else => {
                if (m.networks.len == 0) {
                    drawMessage(cr, w, y, "Looking for networks\u{2026}");
                } else {
                    for (m.networks, 0..) |net, i| {
                        self.drawRow(cr, w, y, i, net, m.status);
                        y += row_h;
                        if (self.entry) |e| {
                            if (std.mem.eql(u8, e.ssid, net.ssid)) {
                                self.drawEntry(cr, w, y, e);
                                y += entry_h;
                            }
                        }
                    }
                }
            },
        }
        c.cairo_restore(cr);

        if (max_scroll > 0) {
            const track = self.list_h - 8;
            const thumb = @max(24.0, track * self.list_h / self.content_h);
            const ty = list_top + 4 + (track - thumb) * (self.scroll / max_scroll);
            icon.setColor(cr, theme.dim);
            icon.roundedRect(cr, w - 6, ty, 3, thumb, 1.5);
            c.cairo_fill(cr);
        }

        if (self.nm.lastError()) |err| {
            const fy = h - footer_h - pad / 2;
            c.cairo_move_to(cr, pad, fy + 0.5);
            c.cairo_line_to(cr, w - pad, fy + 0.5);
            icon.setColor(cr, theme.border);
            c.cairo_set_line_width(cr, 1);
            c.cairo_stroke(cr);
            _ = drawText(cr, pad, fy + footer_h / 2, err, font_small, theme.danger, w - 2 * pad);
        }
    }

    fn drawHeader(self: *Ui, cr: *c.cairo_t, w: f64) void {
        const m = self.nm.model;
        _ = drawText(cr, pad, header_h / 2, "Wi-Fi", font_title, theme.text, null);

        const tw: f64 = 42;
        const th: f64 = 24;
        const tx = w - pad - tw;
        const ty = (header_h - th) / 2;
        const on = m.wireless_enabled and m.status != .no_device;
        const hovered = self.isHovered(.toggle, 0);
        icon.setColor(cr, if (on) theme.accent else if (hovered) theme.dim.withAlpha(0.3) else theme.dim);
        icon.roundedRect(cr, tx, ty, tw, th, th / 2);
        c.cairo_fill(cr);
        icon.setColor(cr, if (on) theme.on_accent else theme.knob);
        const kx = if (on) tx + tw - th / 2 else tx + th / 2;
        c.cairo_arc(cr, kx, ty + th / 2, th / 2 - 4, 0, 2 * std.math.pi);
        c.cairo_fill(cr);
        if (m.status != .no_device) {
            self.addHit(.{ .kind = .toggle, .x = tx - 6, .y = ty - 6, .w = tw + 12, .h = th + 12 });
        }

        c.cairo_move_to(cr, 0, header_h - 0.5);
        c.cairo_line_to(cr, w, header_h - 0.5);
        icon.setColor(cr, theme.border);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
    }

    fn drawMessage(cr: *c.cairo_t, w: f64, y: f64, text: []const u8) void {
        _ = drawTextAligned(cr, w / 2, y + message_h / 2, text, font_regular, theme.subtext, .center);
    }

    fn drawRow(self: *Ui, cr: *c.cairo_t, w: f64, y: f64, index: usize, net: nm.Network, status: nm.Status) void {
        if (self.isHovered(.row, index) and !net.active) {
            icon.setColor(cr, theme.hover);
            c.cairo_rectangle(cr, 0, y, w, row_h);
            c.cairo_fill(cr);
        }

        const icon_size: f64 = 20;
        const iy = y + (row_h - icon_size) / 2;
        const bar_color = if (net.active) theme.accent else theme.text;
        icon.drawBars(cr, pad, iy, icon_size, net.bars(), bar_color, theme.dim);

        const cy = y + row_h / 2;
        var right = w - pad;
        if (net.active and status == .connected) {
            right -= self.drawButton(cr, "Disconnect", right, cy, false, .disconnect, index) + 8;
        } else if (net.active) {
            right -= self.drawButton(cr, "Cancel", right, cy, false, .cancel, index) + 10;
            right -= drawTextAligned(cr, right, cy, "Connecting\u{2026}", font_small, theme.subtext, .right) + 10;
        } else {
            if (net.security.isSecured()) {
                icon.drawLock(cr, right - 13, cy - 6.5, 13, theme.subtext);
                right -= 13 + 8;
            }
            const label: ?[]const u8 = if (net.saved != null)
                "Saved"
            else if (!net.security.canAutoCreate())
                net.security.label()
            else
                null;
            if (label) |l| {
                right -= drawTextAligned(cr, right, cy, l, font_small, theme.subtext, .right) + 8;
            }
        }

        const name_x = pad + icon_size + 12;
        const font = if (net.active) font_bold else font_regular;
        const name_color = if (net.active) theme.accent else theme.text;
        _ = drawText(cr, name_x, cy, net.ssid, font, name_color, right - name_x - 6);

        self.addHit(.{ .kind = .row, .index = index, .x = 0, .y = y, .w = w, .h = row_h });
    }

    fn drawEntry(self: *Ui, cr: *c.cairo_t, w: f64, y: f64, e: Entry) void {
        const field_h: f64 = 36;
        const fy = y + (entry_h - field_h) / 2;
        const button_w: f64 = 80;
        const fx = pad + 32;
        const fw = w - pad - button_w - 10 - fx;

        icon.setColor(cr, theme.field);
        icon.roundedRect(cr, fx, fy, fw, field_h, 8);
        c.cairo_fill_preserve(cr);
        icon.setColor(cr, theme.accent.withAlpha(0.8));
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);

        const reveal_label: []const u8 = if (e.reveal) "hide" else "show";
        const reveal_w = drawTextAligned(cr, fx + fw - 10, fy + field_h / 2, reveal_label, font_small, theme.subtext, .right);
        self.addHit(.{ .kind = .reveal, .x = fx + fw - 10 - reveal_w - 6, .y = fy, .w = reveal_w + 16, .h = field_h });

        const text_x = fx + 10;
        const text_max = fw - 20 - reveal_w - 8;
        var shown_w: f64 = 0;
        if (e.text.items.len == 0) {
            _ = drawText(cr, text_x, fy + field_h / 2, "Password", font_regular, theme.subtext.withAlpha(0.6), text_max);
        } else if (e.reveal) {
            shown_w = drawText(cr, text_x, fy + field_h / 2, e.text.items, font_regular, theme.text, text_max);
        } else {
            var dots: [256]u8 = undefined;
            var n: usize = 0;
            const count = std.unicode.utf8CountCodepoints(e.text.items) catch e.text.items.len;
            var i: usize = 0;
            while (i < count and n + 3 <= dots.len) : (i += 1) {
                @memcpy(dots[n..][0..3], "\u{2022}");
                n += 3;
            }
            shown_w = drawText(cr, text_x, fy + field_h / 2, dots[0..n], font_regular, theme.text, text_max);
        }
        // Caret.
        const caret_x = @min(text_x + shown_w + 1, text_x + text_max) + 0.5;
        icon.setColor(cr, theme.accent);
        c.cairo_move_to(cr, caret_x, fy + 9);
        c.cairo_line_to(cr, caret_x, fy + field_h - 9);
        c.cairo_stroke(cr);

        _ = self.drawButton(cr, "Connect", w - pad, fy + field_h / 2, true, .connect, 0);
    }

    /// Draws a pill button whose right edge is at `right`, returns its width.
    fn drawButton(self: *Ui, cr: *c.cairo_t, label: []const u8, right: f64, cy: f64, filled: bool, kind: HitKind, index: usize) f64 {
        const size = textSize(cr, label, font_small);
        const bw = size.w + 24;
        const bh: f64 = 28;
        const bx = right - bw;
        const by = cy - bh / 2;
        const hovered = self.isHovered(kind, index);
        icon.roundedRect(cr, bx + 0.5, by + 0.5, bw - 1, bh - 1, bh / 2);
        if (filled) {
            icon.setColor(cr, if (hovered) theme.accent.withAlpha(0.85) else theme.accent);
            c.cairo_fill(cr);
        } else {
            icon.setColor(cr, if (hovered) theme.hover.withAlpha(0.12) else theme.hover.withAlpha(0.0));
            c.cairo_fill_preserve(cr);
            icon.setColor(cr, theme.border.withAlpha(0.25));
            c.cairo_set_line_width(cr, 1);
            c.cairo_stroke(cr);
        }
        _ = drawTextAligned(cr, bx + bw / 2, cy, label, font_small, if (filled) theme.on_accent else theme.text, .center);
        self.addHit(.{ .kind = kind, .index = index, .x = bx, .y = by, .w = bw, .h = bh });
        return bw;
    }

    fn isHovered(self: *Ui, kind: HitKind, index: usize) bool {
        const h = self.hover orelse return false;
        return h.kind == kind and h.index == index;
    }

    fn addHit(self: *Ui, hit: Hit) void {
        self.hits.append(self.gpa, hit) catch {};
    }
};

const Size = struct { w: f64, h: f64 };

fn makeLayout(cr: *c.cairo_t, text: []const u8, font: [*:0]const u8, max_w: ?f64) ?*c.PangoLayout {
    const layout = c.pango_cairo_create_layout(cr) orelse return null;
    const desc = c.pango_font_description_from_string(font);
    defer c.pango_font_description_free(desc);
    c.pango_layout_set_font_description(layout, desc);
    c.pango_layout_set_text(layout, text.ptr, @intCast(text.len));
    if (max_w) |mw| {
        c.pango_layout_set_width(layout, @intFromFloat(@max(1.0, mw) * c.PANGO_SCALE));
        c.pango_layout_set_ellipsize(layout, c.PANGO_ELLIPSIZE_END);
    }
    return layout;
}

fn layoutSize(layout: *c.PangoLayout) Size {
    var w: c_int = 0;
    var h: c_int = 0;
    c.pango_layout_get_pixel_size(layout, &w, &h);
    return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

fn textSize(cr: *c.cairo_t, text: []const u8, font: [*:0]const u8) Size {
    const layout = makeLayout(cr, text, font, null) orelse return .{ .w = 0, .h = 0 };
    defer c.g_object_unref(layout);
    return layoutSize(layout);
}

/// Draws text with its left edge at `x`, vertically centred on `cy`.
/// Returns the drawn width.
fn drawText(cr: *c.cairo_t, x: f64, cy: f64, text: []const u8, font: [*:0]const u8, color: Color, max_w: ?f64) f64 {
    const layout = makeLayout(cr, text, font, max_w) orelse return 0;
    defer c.g_object_unref(layout);
    const size = layoutSize(layout);
    icon.setColor(cr, color);
    c.cairo_move_to(cr, x, cy - size.h / 2);
    c.pango_cairo_show_layout(cr, layout);
    return size.w;
}

const Align = enum { center, right };

fn drawTextAligned(cr: *c.cairo_t, anchor: f64, cy: f64, text: []const u8, font: [*:0]const u8, color: Color, alignment: Align) f64 {
    const layout = makeLayout(cr, text, font, null) orelse return 0;
    defer c.g_object_unref(layout);
    const size = layoutSize(layout);
    const x = switch (alignment) {
        .center => anchor - size.w / 2,
        .right => anchor - size.w,
    };
    icon.setColor(cr, color);
    c.cairo_move_to(cr, x, cy - size.h / 2);
    c.pango_cairo_show_layout(cr, layout);
    return size.w;
}
