// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! The popup: Wi-Fi networks with signal strength, a Wi-Fi toggle, a VPN
//! section with switches, a Proton VPN section with sign-in and a country
//! picker, and prompts for passwords and other secrets.
const std = @import("std");
const c = @import("c");
const wl = @import("wl.zig");
const nm = @import("nm.zig");
const icon = @import("icon.zig");
const agent = @import("agent.zig");
const proton = @import("proton.zig");
const Theme = @import("theme.zig").Theme;

const log = std.log.scoped(.ui);
const Allocator = std.mem.Allocator;
const Color = icon.Color;

pub const width: u32 = 380;
const pad: f64 = 14;
const header_h: f64 = 54;
const row_h: f64 = 50;
const small_row_h: f64 = 36;
const entry_h: f64 = 60;
const message_h: f64 = 44;
const footer_h: f64 = 36;
const section_h: f64 = 30;
const field_h: f64 = 36;
const field_row_h: f64 = 44;
const max_list_h: f64 = 520;
const corner: f64 = 12;

const HitKind = enum {
    row,
    toggle,
    disconnect,
    cancel,
    connect,
    reveal,
    field,
    vpn,
    prompt_cancel,
    proton_sign_in,
    proton_toggle,
    proton_country,
    proton_sign_out,
    proton_2fa,
    country,
    picker_back,
};

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

const PromptField = struct {
    label: []const u8,
    text: std.ArrayList(u8) = .empty,
    masked: bool,
    reveal: bool = false,
};

const PromptKind = union(enum) {
    /// Password for joining a new Wi-Fi network; drawn under its row.
    wifi: [:0]u8,
    /// A NetworkManager secret request; drawn under the header.
    agent: *agent.Request,
    proton_login,
    proton_2fa,
};

const Prompt = struct {
    kind: PromptKind,
    fields: []PromptField,
    focus: usize = 0,
    title: []const u8 = "",
    message: ?[]const u8 = null,
    message_danger: bool = false,

    fn isBlock(p: Prompt) bool {
        return p.kind != .wifi;
    }
};

const Point = struct { x: f64, y: f64 };

pub const Ui = struct {
    gpa: Allocator,
    wl: *wl.Client,
    nm: *nm.Client,
    agent: *agent.Agent,
    proton: *proton.Client,
    theme: Theme,
    open: bool = false,
    needs_redraw: bool = false,
    hits: std.ArrayList(Hit) = .empty,
    hover: ?Hit = null,
    pointer: ?Point = null,
    scroll: f64 = 0,
    content_h: f64 = 0,
    list_h: f64 = 0,
    prompt: ?Prompt = null,
    /// The country picker replaces the list while open.
    picker: bool = false,

    pub fn init(self: *Ui, gpa: Allocator, wl_client: *wl.Client, nm_client: *nm.Client, agent_client: *agent.Agent, proton_client: *proton.Client, theme: Theme) void {
        self.* = .{ .gpa = gpa, .wl = wl_client, .nm = nm_client, .agent = agent_client, .proton = proton_client, .theme = theme };
    }

    pub fn deinit(self: *Ui) void {
        self.cancelPrompt();
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
        self.picker = false;
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
        self.cancelPrompt();
        self.picker = false;
        self.hover = null;
        self.pointer = null;
    }

    pub fn onPopupReady(self: *Ui) void {
        self.needs_redraw = true;
    }

    pub fn onDismiss(self: *Ui) void {
        self.close();
    }

    pub fn onModelChanged(self: *Ui) void {
        if (!self.open) return;
        if (self.prompt) |p| {
            if (p.kind == .wifi) {
                const net = self.nm.findNetwork(p.kind.wifi);
                if (net == null or net.?.active) self.clearPrompt();
            }
        }
        if (self.proton.status == .needs_2fa and self.prompt == null) self.startProton2fa();
        self.relayout();
    }

    fn relayout(self: *Ui) void {
        const h = self.desiredHeight();
        _ = self.wl.popupResize(width, h);
        self.needs_redraw = true;
    }

    // ---- prompts ----------------------------------------------------------

    /// NetworkManager wants secrets; show the prompt, opening the popup if needed.
    pub fn showAgentPrompt(self: *Ui, req: *agent.Request) void {
        self.cancelPrompt();
        const fields = self.gpa.alloc(PromptField, req.fields.len) catch {
            self.agent.cancel(req);
            return;
        };
        for (req.fields, 0..) |f, i| fields[i] = .{ .label = f.label, .masked = f.masked };
        self.prompt = .{
            .kind = .{ .agent = req },
            .fields = fields,
            .title = req.title,
            .message = if (req.message) |m| m else if (req.retry) "The previous credentials were rejected" else null,
            .message_danger = req.retry,
        };
        if (!self.open) self.openPopup();
        self.relayout();
    }

    /// NetworkManager withdrew a request; `req` is about to be destroyed.
    pub fn agentRequestCancelled(self: *Ui, req: *agent.Request) void {
        const p = self.prompt orelse return;
        if (p.kind != .agent or p.kind.agent != req) return;
        self.clearPrompt();
        self.relayout();
    }

    fn startWifiPrompt(self: *Ui, ssid: []const u8) void {
        self.cancelPrompt();
        const copy = self.gpa.dupeSentinel(u8, ssid, 0) catch return;
        const fields = self.gpa.alloc(PromptField, 1) catch {
            self.gpa.free(copy);
            return;
        };
        fields[0] = .{ .label = "Password", .masked = true };
        self.prompt = .{ .kind = .{ .wifi = copy }, .fields = fields };
    }

    fn startProtonLogin(self: *Ui) void {
        self.cancelPrompt();
        const fields = self.gpa.alloc(PromptField, 2) catch return;
        fields[0] = .{ .label = "Proton username or email", .masked = false };
        fields[1] = .{ .label = "Password", .masked = true };
        self.prompt = .{ .kind = .proton_login, .fields = fields, .title = "Sign in to Proton VPN" };
        if (self.proton.username().len > 0) fields[0].text.appendSlice(self.gpa, self.proton.username()) catch {};
        if (fields[0].text.items.len > 0) self.prompt.?.focus = 1;
    }

    fn startProton2fa(self: *Ui) void {
        self.cancelPrompt();
        const fields = self.gpa.alloc(PromptField, 1) catch return;
        fields[0] = .{ .label = "Two-factor code", .masked = false };
        self.prompt = .{ .kind = .proton_2fa, .fields = fields, .title = "Proton two-factor authentication", .message = "Enter the code from your authenticator app" };
    }

    /// Drops the prompt without answering an agent request.
    fn clearPrompt(self: *Ui) void {
        const p = &(self.prompt orelse return);
        for (p.fields) |*f| {
            @memset(f.text.items, 0);
            f.text.deinit(self.gpa);
        }
        self.gpa.free(p.fields);
        if (p.kind == .wifi) self.gpa.free(p.kind.wifi);
        self.prompt = null;
    }

    /// Drops the prompt, telling NetworkManager the user declined if it was
    /// an agent request.
    fn cancelPrompt(self: *Ui) void {
        const p = self.prompt orelse return;
        if (p.kind == .agent) {
            self.nm.suppressNextVpnFailure();
            self.agent.cancel(p.kind.agent);
        }
        self.clearPrompt();
    }

    fn submitPrompt(self: *Ui) void {
        const p = &(self.prompt orelse return);
        // Every field must be filled; otherwise move the focus to the first empty one.
        for (p.fields, 0..) |f, i| {
            if (f.text.items.len == 0) {
                p.focus = i;
                self.needs_redraw = true;
                return;
            }
        }
        switch (p.kind) {
            .wifi => |ssid| {
                const text = p.fields[0].text.items;
                if (text.len < 8) {
                    self.nm.setErrorFmt("Wi-Fi passwords are at least 8 characters", .{});
                    self.relayout();
                    return;
                }
                self.nm.connect(ssid, text) catch |err| {
                    self.nm.setErrorFmt("Couldn't join {s}: {t}", .{ ssid, err });
                    self.relayout();
                    return;
                };
            },
            .agent => |req| {
                var values: [8][]const u8 = undefined;
                if (p.fields.len > values.len) return;
                for (p.fields, 0..) |f, i| values[i] = f.text.items;
                self.agent.respond(req, values[0..p.fields.len]);
            },
            .proton_login => self.proton.login(p.fields[0].text.items, p.fields[1].text.items),
            .proton_2fa => self.proton.twoFactor(p.fields[0].text.items),
        }
        self.clearPrompt();
        self.relayout();
    }

    fn promptBlockHeight(self: *Ui) f64 {
        const p = self.prompt orelse return 0;
        if (!p.isBlock()) return 0;
        var h: f64 = 8 + 26;
        if (p.message != null) h += 22;
        h += @as(f64, @floatFromInt(p.fields.len)) * field_row_h;
        h += 40 + 8;
        return h;
    }

    fn isProtonProfile(self: *Ui, vpn: nm.Vpn) bool {
        const uuid = self.proton.profileUuid() orelse return false;
        return std.mem.eql(u8, vpn.uuid, uuid);
    }

    fn otherVpnCount(self: *Ui) usize {
        var n: usize = 0;
        for (self.nm.model.vpns) |v| {
            if (!self.isProtonProfile(v)) n += 1;
        }
        return n;
    }

    fn protonHeight(self: *Ui) f64 {
        return section_h + switch (self.proton.status) {
            .signed_out, .signing_in, .needs_2fa => row_h,
            .signed_in => row_h + row_h + small_row_h,
        };
    }

    fn desiredHeight(self: *Ui) u32 {
        const m = self.nm.model;
        var list: f64 = 0;
        if (self.picker) {
            list = small_row_h + @as(f64, @floatFromInt(1 + self.proton.countryList().len)) * row_h;
        } else {
            list = message_h;
            if (m.status != .disabled and m.status != .no_device and m.networks.len > 0) {
                list = @as(f64, @floatFromInt(m.networks.len)) * row_h;
                if (self.prompt) |p| {
                    if (p.kind == .wifi) list += entry_h;
                }
            }
            const others = self.otherVpnCount();
            if (others > 0) list += section_h + @as(f64, @floatFromInt(others)) * row_h;
            list += self.protonHeight();
        }
        self.content_h = list;
        self.list_h = @min(list, max_list_h);
        var h = header_h + self.promptBlockHeight() + self.list_h + pad / 2;
        if (self.footerError() != null) h += footer_h;
        return @intFromFloat(@ceil(h));
    }

    fn footerError(self: *Ui) ?[]const u8 {
        return self.nm.lastError() orelse self.proton.lastError();
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
        if (!pressed) return;
        const p = self.pointer orelse return;
        const hit = self.hitTest(p.x, p.y) orelse return;
        log.debug("button {x} on {t}", .{ button, hit.kind });
        if (button == c.BTN_MIDDLE) {
            // Middle click pastes the primary selection into a field.
            if (hit.kind == .field) {
                if (self.prompt) |*pr| {
                    if (hit.index < pr.fields.len) pr.focus = hit.index;
                }
                self.paste(.primary);
            }
            return;
        }
        if (button != c.BTN_LEFT) return;
        self.activate(hit);
    }

    /// Inserts the clipboard or primary selection into the focused field.
    fn paste(self: *Ui, source: wl.Client.Source) void {
        const f = self.focusedField() orelse return;
        const text = self.wl.readSelection(self.gpa, source) orelse return;
        defer {
            @memset(text, 0);
            self.gpa.free(text);
        }
        // Drop line breaks and control characters; a trailing newline is
        // common when copying from a password manager or terminal.
        for (text) |ch| {
            if (ch >= 0x20 and ch != 0x7f) f.text.append(self.gpa, ch) catch break;
        }
        self.needs_redraw = true;
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
                if (self.prompt != null) {
                    self.cancelPrompt();
                    self.relayout();
                } else if (self.picker) {
                    self.picker = false;
                    self.scroll = 0;
                    self.relayout();
                } else {
                    self.close();
                }
            },
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => self.submitPrompt(),
            c.XKB_KEY_Tab, c.XKB_KEY_ISO_Left_Tab => {
                if (self.prompt) |*p| {
                    if (p.fields.len > 1) {
                        p.focus = if (sym == c.XKB_KEY_Tab) (p.focus + 1) % p.fields.len else (p.focus + p.fields.len - 1) % p.fields.len;
                        self.needs_redraw = true;
                    }
                }
            },
            c.XKB_KEY_BackSpace => {
                if (self.focusedField()) |f| {
                    if (f.text.items.len > 0) {
                        var n = f.text.items.len - 1;
                        // Step back over UTF-8 continuation bytes.
                        while (n > 0 and (f.text.items[n] & 0xc0) == 0x80) n -= 1;
                        f.text.shrinkRetainingCapacity(n);
                        self.needs_redraw = true;
                    }
                }
            },
            c.XKB_KEY_Insert, c.XKB_KEY_KP_Insert => {
                if (mods.shift) self.paste(.clipboard);
            },
            else => {
                const f = self.focusedField() orelse return;
                if (mods.ctrl) {
                    switch (sym) {
                        c.XKB_KEY_u => {
                            f.text.clearRetainingCapacity();
                            self.needs_redraw = true;
                        },
                        c.XKB_KEY_v, c.XKB_KEY_V => self.paste(.clipboard),
                        else => {},
                    }
                    return;
                }
                if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) {
                    f.text.appendSlice(self.gpa, text) catch {};
                    self.needs_redraw = true;
                }
            },
        }
    }

    fn focusedField(self: *Ui) ?*PromptField {
        const p = &(self.prompt orelse return null);
        if (p.fields.len == 0) return null;
        return &p.fields[@min(p.focus, p.fields.len - 1)];
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
            .connect => self.submitPrompt(),
            .prompt_cancel => self.cancelPrompt(),
            .reveal => {
                if (self.prompt) |*p| {
                    if (hit.index < p.fields.len) p.fields[hit.index].reveal = !p.fields[hit.index].reveal;
                }
            },
            .field => {
                if (self.prompt) |*p| {
                    if (hit.index < p.fields.len) p.focus = hit.index;
                }
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
                    self.startWifiPrompt(net.ssid);
                }
            },
            .vpn => {
                if (hit.index >= m.vpns.len) return;
                const vpn = m.vpns[hit.index];
                self.nm.clearError();
                switch (vpn.state) {
                    .off => self.nm.vpnConnect(hit.index) catch |err| {
                        self.nm.setErrorFmt("Couldn't connect {s}: {t}", .{ vpn.id, err });
                    },
                    .connecting, .on => self.nm.vpnDisconnect(hit.index) catch |err| {
                        self.nm.setErrorFmt("Couldn't disconnect {s}: {t}", .{ vpn.id, err });
                    },
                    .disconnecting => {},
                }
            },
            .proton_sign_in => self.startProtonLogin(),
            .proton_2fa => self.startProton2fa(),
            .proton_sign_out => self.proton.logout(),
            .proton_toggle => {
                self.nm.clearError();
                self.proton.clearError();
                switch (self.proton.vpnState()) {
                    .off => self.proton.connect(),
                    .connecting, .on => self.proton.disconnect(),
                    .disconnecting => {},
                }
            },
            .proton_country => {
                self.picker = true;
                self.scroll = 0;
            },
            .picker_back => {
                self.picker = false;
                self.scroll = 0;
            },
            .country => {
                const list = self.proton.countryList();
                if (hit.index == 0) {
                    self.proton.selectCountry(null);
                } else if (hit.index - 1 < list.len) {
                    self.proton.selectCountry(list[hit.index - 1].code);
                }
                self.picker = false;
                self.scroll = 0;
            },
        }
        self.relayout();
    }

    // ---- drawing ----------------------------------------------------------

    pub fn render(self: *Ui) void {
        self.needs_redraw = false;
        const frame = self.wl.beginFrame() orelse return;
        defer self.wl.endFrame(frame);
        log.debug("rendering {d}x{d}", .{ frame.width, frame.height });
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
        icon.setColor(cr, self.theme.bg);
        c.cairo_fill_preserve(cr);
        icon.setColor(cr, self.theme.border);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);

        self.drawHeader(cr, w);

        var list_top = header_h;
        if (self.prompt) |p| {
            if (p.isBlock()) list_top += self.drawPromptBlock(cr, w, list_top, p);
        }

        const m = self.nm.model;
        const max_scroll = @max(0.0, self.content_h - self.list_h);
        self.scroll = std.math.clamp(self.scroll, 0.0, max_scroll);

        c.cairo_save(cr);
        c.cairo_rectangle(cr, 0, list_top, w, self.list_h);
        c.cairo_clip(cr);
        var y = list_top - self.scroll;
        if (self.picker) {
            self.drawPicker(cr, w, y);
        } else {
            switch (m.status) {
                .no_device => {
                    self.drawMessage(cr, w, y, "No Wi-Fi device found");
                    y += message_h;
                },
                .disabled => {
                    self.drawMessage(cr, w, y, "Wi-Fi is off");
                    y += message_h;
                },
                else => {
                    if (m.networks.len == 0) {
                        self.drawMessage(cr, w, y, "Looking for networks\u{2026}");
                        y += message_h;
                    } else {
                        for (m.networks, 0..) |net, i| {
                            self.drawRow(cr, w, y, i, net, m.status);
                            y += row_h;
                            if (self.prompt) |p| {
                                if (p.kind == .wifi and std.mem.eql(u8, p.kind.wifi, net.ssid)) {
                                    self.drawWifiPrompt(cr, w, y, p);
                                    y += entry_h;
                                }
                            }
                        }
                    }
                },
            }
            if (self.otherVpnCount() > 0) {
                self.drawSection(cr, w, y, "VPN");
                y += section_h;
                for (m.vpns, 0..) |vpn, i| {
                    if (self.isProtonProfile(vpn)) continue;
                    self.drawVpnRow(cr, w, y, i, vpn);
                    y += row_h;
                }
            }
            self.drawSection(cr, w, y, "PROTON VPN");
            y += section_h;
            self.drawProton(cr, w, y);
        }
        c.cairo_restore(cr);

        if (max_scroll > 0) {
            const track = self.list_h - 8;
            const thumb = @max(24.0, track * self.list_h / self.content_h);
            const ty = list_top + 4 + (track - thumb) * (self.scroll / max_scroll);
            icon.setColor(cr, self.theme.dim);
            icon.roundedRect(cr, w - 6, ty, 3, thumb, 1.5);
            c.cairo_fill(cr);
        }

        if (self.footerError()) |err| {
            const fy = h - footer_h - pad / 2;
            self.separator(cr, pad, w - pad, fy + 0.5);
            _ = drawText(cr, pad, fy + footer_h / 2, err, self.theme.font_small, self.theme.danger, w - 2 * pad);
        }
    }

    fn separator(self: *Ui, cr: *c.cairo_t, x0: f64, x1: f64, y: f64) void {
        c.cairo_move_to(cr, x0, y);
        c.cairo_line_to(cr, x1, y);
        icon.setColor(cr, self.theme.border);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
    }

    fn drawHeader(self: *Ui, cr: *c.cairo_t, w: f64) void {
        const m = self.nm.model;
        _ = drawText(cr, pad, header_h / 2, "Wi-Fi", self.theme.font_title, self.theme.text, null);

        const tw: f64 = 42;
        const th: f64 = 24;
        const tx = w - pad - tw;
        const ty = (header_h - th) / 2;
        const on = m.wireless_enabled and m.status != .no_device;
        self.drawSwitch(cr, tx, ty, tw, th, on, false, self.isHovered(.toggle, 0));
        if (m.status != .no_device) {
            self.addHit(.{ .kind = .toggle, .x = tx - 6, .y = ty - 6, .w = tw + 12, .h = th + 12 });
        }
        self.separator(cr, 0, w, header_h - 0.5);
    }

    fn drawSwitch(self: *Ui, cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, on: bool, pending: bool, hovered: bool) void {
        const track = if (on) self.theme.accent else if (pending) self.theme.accent.withAlpha(0.5) else if (hovered) self.theme.dim.withAlpha(0.35) else self.theme.dim;
        icon.setColor(cr, track);
        icon.roundedRect(cr, x, y, w, h, h / 2);
        c.cairo_fill(cr);
        icon.setColor(cr, if (on) self.theme.on_accent else self.theme.text);
        const kx = if (on) x + w - h / 2 else if (pending) x + w / 2 else x + h / 2;
        c.cairo_arc(cr, kx, y + h / 2, h / 2 - 4, 0, 2 * std.math.pi);
        c.cairo_fill(cr);
    }

    fn drawSection(self: *Ui, cr: *c.cairo_t, w: f64, y: f64, title: []const u8) void {
        self.separator(cr, 0, w, y + 0.5);
        _ = drawText(cr, pad, y + section_h / 2 + 2, title, self.theme.font_small, self.theme.muted, null);
    }

    fn drawMessage(self: *Ui, cr: *c.cairo_t, w: f64, y: f64, text: []const u8) void {
        _ = drawTextAligned(cr, w / 2, y + message_h / 2, text, self.theme.font_regular, self.theme.muted, .center);
    }

    fn hoverRow(self: *Ui, cr: *c.cairo_t, w: f64, y: f64, h: f64, kind: HitKind, index: usize) void {
        if (self.isHovered(kind, index)) {
            icon.setColor(cr, self.theme.hover);
            c.cairo_rectangle(cr, 0, y, w, h);
            c.cairo_fill(cr);
        }
    }

    fn drawRow(self: *Ui, cr: *c.cairo_t, w: f64, y: f64, index: usize, net: nm.Network, status: nm.Status) void {
        if (!net.active) self.hoverRow(cr, w, y, row_h, .row, index);

        const icon_size: f64 = 20;
        const iy = y + (row_h - icon_size) / 2;
        const bar_color = if (net.active) self.theme.accent else self.theme.text;
        icon.drawBars(cr, pad, iy, icon_size, net.bars(), bar_color, self.theme.dim);

        const cy = y + row_h / 2;
        var right = w - pad;
        if (net.active and status == .connected) {
            right -= self.drawButton(cr, "Disconnect", right, cy, false, .disconnect, index) + 8;
        } else if (net.active) {
            right -= self.drawButton(cr, "Cancel", right, cy, false, .cancel, index) + 10;
            right -= drawTextAligned(cr, right, cy, "Connecting\u{2026}", self.theme.font_small, self.theme.muted, .right) + 10;
        } else {
            if (net.security.isSecured()) {
                icon.drawLock(cr, right - 13, cy - 6.5, 13, self.theme.muted);
                right -= 13 + 8;
            }
            const label: ?[]const u8 = if (net.saved != null)
                "Saved"
            else if (!net.security.canAutoCreate())
                net.security.label()
            else
                null;
            if (label) |l| {
                right -= drawTextAligned(cr, right, cy, l, self.theme.font_small, self.theme.muted, .right) + 8;
            }
        }

        const name_x = pad + icon_size + 12;
        const font = if (net.active) self.theme.font_bold else self.theme.font_regular;
        const name_color = if (net.active) self.theme.accent else self.theme.text;
        _ = drawText(cr, name_x, cy, net.ssid, font, name_color, right - name_x - 6);

        self.addHit(.{ .kind = .row, .index = index, .x = 0, .y = y, .w = w, .h = row_h });
    }

    /// A row with a lock icon, a name, an optional status and a switch.
    fn drawSwitchRow(self: *Ui, cr: *c.cairo_t, w: f64, y: f64, name: []const u8, status: ?[]const u8, on: bool, pending: bool, kind: HitKind, index: usize) void {
        self.hoverRow(cr, w, y, row_h, kind, index);
        const cy = y + row_h / 2;
        const sw: f64 = 36;
        const sh: f64 = 20;
        const sx = w - pad - sw;
        self.drawSwitch(cr, sx, cy - sh / 2, sw, sh, on, pending, self.isHovered(kind, index));
        var right = sx - 12;
        if (status) |s| {
            right -= drawTextAligned(cr, right, cy, s, self.theme.font_small, self.theme.muted, .right) + 8;
        }
        const icon_size: f64 = 16;
        icon.drawLock(cr, pad + 2, cy - icon_size / 2, icon_size, if (on) self.theme.accent else self.theme.text);
        const name_x = pad + 20 + 12;
        const font = if (on) self.theme.font_bold else self.theme.font_regular;
        _ = drawText(cr, name_x, cy, name, font, if (on) self.theme.accent else self.theme.text, right - name_x - 6);
        self.addHit(.{ .kind = kind, .index = index, .x = 0, .y = y, .w = w, .h = row_h });
    }

    fn drawVpnRow(self: *Ui, cr: *c.cairo_t, w: f64, y: f64, index: usize, vpn: nm.Vpn) void {
        const status: ?[]const u8 = switch (vpn.state) {
            .on => "Connected",
            .connecting => "Connecting\u{2026}",
            .disconnecting => "Disconnecting\u{2026}",
            .off => null,
        };
        const pending = vpn.state == .connecting or vpn.state == .disconnecting;
        self.drawSwitchRow(cr, w, y, vpn.id, status, vpn.state == .on, pending, .vpn, index);
    }

    /// A clickable row with text on the left and an optional value on the right.
    fn drawLinkRow(self: *Ui, cr: *c.cairo_t, w: f64, y: f64, h: f64, label: []const u8, value: ?[]const u8, chevron: bool, kind: HitKind, muted: bool) void {
        self.hoverRow(cr, w, y, h, kind, 0);
        const cy = y + h / 2;
        var right = w - pad;
        if (chevron) {
            right -= drawTextAligned(cr, right, cy, "\u{203a}", self.theme.font_regular, self.theme.muted, .right) + 8;
        }
        if (value) |v| {
            right -= drawTextAligned(cr, right, cy, v, self.theme.font_regular, self.theme.text, .right) + 8;
        }
        const x = pad + 32;
        _ = drawText(cr, x, cy, label, if (muted) self.theme.font_small else self.theme.font_regular, if (muted) self.theme.muted else self.theme.text, right - x - 6);
        self.addHit(.{ .kind = kind, .x = 0, .y = y, .w = w, .h = h });
    }

    fn drawProton(self: *Ui, cr: *c.cairo_t, w: f64, y0: f64) void {
        var y = y0;
        const p = self.proton;
        switch (p.status) {
            .signed_out => {
                self.drawLinkRow(cr, w, y, row_h, if (p.busy) |b| b else "Sign in to Proton VPN", null, true, .proton_sign_in, false);
            },
            .signing_in => {
                self.drawLinkRow(cr, w, y, row_h, p.busy orelse "Signing in\u{2026}", null, false, .proton_sign_in, false);
            },
            .needs_2fa => {
                self.drawLinkRow(cr, w, y, row_h, "Enter your two-factor code", null, true, .proton_2fa, false);
            },
            .signed_in => {
                const state = p.vpnState();
                var status_buf: [160]u8 = undefined;
                const status: ?[]const u8 = switch (state) {
                    .on => if (p.lastServer()) |s| (std.fmt.bufPrint(&status_buf, "{s}", .{s}) catch "Connected") else "Connected",
                    .connecting => "Connecting\u{2026}",
                    .disconnecting => "Disconnecting\u{2026}",
                    .off => p.busy,
                };
                const pending = state == .connecting or state == .disconnecting or (p.busy != null and state == .off);
                self.drawSwitchRow(cr, w, y, "Proton VPN", status, state == .on, pending, .proton_toggle, 0);
                y += row_h;
                self.drawLinkRow(cr, w, y, row_h, "Country", p.selectedCountryName(), true, .proton_country, false);
                y += row_h;
                var acct: [200]u8 = undefined;
                const who = std.fmt.bufPrint(&acct, "{s} \u{00b7} {s}", .{ p.username(), if (p.plan().len > 0) p.plan() else "Proton VPN" }) catch p.username();
                self.drawLinkRow(cr, w, y, small_row_h, who, "Sign out", false, .proton_sign_out, true);
            },
        }
    }

    fn drawPicker(self: *Ui, cr: *c.cairo_t, w: f64, y0: f64) void {
        var y = y0;
        self.drawLinkRow(cr, w, y, small_row_h, "\u{2039} Back", "Choose a country", false, .picker_back, true);
        y += small_row_h;
        const selected = self.proton.selectedCountry();
        self.drawCountryRow(cr, w, y, 0, "Fastest server", null, selected == null);
        y += row_h;
        for (self.proton.countryList(), 0..) |cn, i| {
            var count_buf: [32]u8 = undefined;
            const count = std.fmt.bufPrint(&count_buf, "{d} servers", .{cn.servers}) catch "";
            const is_selected = selected != null and std.mem.eql(u8, &selected.?, &cn.code);
            self.drawCountryRow(cr, w, y, i + 1, cn.name, count, is_selected);
            y += row_h;
        }
    }

    fn drawCountryRow(self: *Ui, cr: *c.cairo_t, w: f64, y: f64, index: usize, name: []const u8, detail: ?[]const u8, selected: bool) void {
        self.hoverRow(cr, w, y, row_h, .country, index);
        const cy = y + row_h / 2;
        var right = w - pad;
        if (selected) {
            right -= drawTextAligned(cr, right, cy, "\u{2713}", self.theme.font_regular, self.theme.accent, .right) + 10;
        }
        if (detail) |d| {
            right -= drawTextAligned(cr, right, cy, d, self.theme.font_small, self.theme.muted, .right) + 8;
        }
        const x = pad + 32;
        _ = drawText(cr, x, cy, name, if (selected) self.theme.font_bold else self.theme.font_regular, if (selected) self.theme.accent else self.theme.text, right - x - 6);
        self.addHit(.{ .kind = .country, .index = index, .x = 0, .y = y, .w = w, .h = row_h });
    }

    fn drawWifiPrompt(self: *Ui, cr: *c.cairo_t, w: f64, y: f64, p: Prompt) void {
        const fy = y + (entry_h - field_h) / 2;
        const button_w: f64 = 80;
        const fx = pad + 32;
        const fw = w - pad - button_w - 10 - fx;
        self.drawField(cr, fx, fy, fw, &p.fields[0], 0, true);
        _ = self.drawButton(cr, "Connect", w - pad, fy + field_h / 2, true, .connect, 0);
    }

    /// Draws a prompt block below the header; returns its height.
    fn drawPromptBlock(self: *Ui, cr: *c.cairo_t, w: f64, top: f64, p: Prompt) f64 {
        var y = top + 8;
        _ = drawText(cr, pad, y + 13, p.title, self.theme.font_bold, self.theme.text, w - 2 * pad);
        y += 26;
        if (p.message) |msg| {
            _ = drawText(cr, pad, y + 11, msg, self.theme.font_small, if (p.message_danger) self.theme.danger else self.theme.muted, w - 2 * pad);
            y += 22;
        }
        for (p.fields, 0..) |*f, i| {
            const fy = y + (field_row_h - field_h) / 2;
            self.drawField(cr, pad, fy, w - 2 * pad, f, i, i == p.focus);
            y += field_row_h;
        }
        const by = y + 20;
        var right = w - pad;
        const submit_label: []const u8 = switch (p.kind) {
            .proton_login => "Sign in",
            .proton_2fa => "Verify",
            else => "Connect",
        };
        right -= self.drawButton(cr, submit_label, right, by, true, .connect, 0) + 8;
        _ = self.drawButton(cr, "Cancel", right, by, false, .prompt_cancel, 0);
        y += 40 + 8;
        self.separator(cr, 0, w, y - 0.5);
        return y - top;
    }

    fn drawField(self: *Ui, cr: *c.cairo_t, fx: f64, fy: f64, fw: f64, f: *const PromptField, index: usize, focused: bool) void {
        icon.setColor(cr, self.theme.field);
        icon.roundedRect(cr, fx, fy, fw, field_h, 8);
        c.cairo_fill_preserve(cr);
        icon.setColor(cr, if (focused) self.theme.accent.withAlpha(0.8) else self.theme.border);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);

        var reveal_w: f64 = 0;
        if (f.masked) {
            const reveal_label: []const u8 = if (f.reveal) "hide" else "show";
            reveal_w = drawTextAligned(cr, fx + fw - 10, fy + field_h / 2, reveal_label, self.theme.font_small, self.theme.muted, .right);
            self.addHit(.{ .kind = .reveal, .index = index, .x = fx + fw - 10 - reveal_w - 6, .y = fy, .w = reveal_w + 16, .h = field_h });
        }

        const text_x = fx + 10;
        const text_max = fw - 20 - (if (f.masked) reveal_w + 8 else 0);
        var shown_w: f64 = 0;
        if (f.text.items.len == 0) {
            _ = drawText(cr, text_x, fy + field_h / 2, f.label, self.theme.font_regular, self.theme.muted.withAlpha(0.6), text_max);
        } else if (!f.masked or f.reveal) {
            shown_w = drawText(cr, text_x, fy + field_h / 2, f.text.items, self.theme.font_regular, self.theme.text, text_max);
        } else {
            var dots: [256]u8 = undefined;
            var n: usize = 0;
            const count = std.unicode.utf8CountCodepoints(f.text.items) catch f.text.items.len;
            var i: usize = 0;
            while (i < count and n + 3 <= dots.len) : (i += 1) {
                @memcpy(dots[n..][0..3], "\u{2022}");
                n += 3;
            }
            shown_w = drawText(cr, text_x, fy + field_h / 2, dots[0..n], self.theme.font_regular, self.theme.text, text_max);
        }
        if (focused) {
            const caret_x = @min(text_x + shown_w + 1, text_x + text_max) + 0.5;
            icon.setColor(cr, self.theme.accent);
            c.cairo_move_to(cr, caret_x, fy + 9);
            c.cairo_line_to(cr, caret_x, fy + field_h - 9);
            c.cairo_stroke(cr);
        }
        self.addHit(.{ .kind = .field, .index = index, .x = fx, .y = fy, .w = fw - reveal_w - 16, .h = field_h });
    }

    /// Draws a pill button whose right edge is at `right`, returns its width.
    fn drawButton(self: *Ui, cr: *c.cairo_t, label: []const u8, right: f64, cy: f64, filled: bool, kind: HitKind, index: usize) f64 {
        const size = textSize(cr, label, self.theme.font_small);
        const bw = size.w + 24;
        const bh: f64 = 28;
        const bx = right - bw;
        const by = cy - bh / 2;
        const hovered = self.isHovered(kind, index);
        icon.roundedRect(cr, bx + 0.5, by + 0.5, bw - 1, bh - 1, bh / 2);
        if (filled) {
            icon.setColor(cr, if (hovered) self.theme.accent.withAlpha(0.85) else self.theme.accent);
            c.cairo_fill(cr);
        } else {
            icon.setColor(cr, if (hovered) self.theme.hover.withAlpha(0.12) else self.theme.hover.withAlpha(0.0));
            c.cairo_fill_preserve(cr);
            icon.setColor(cr, self.theme.border.withAlpha(0.25));
            c.cairo_set_line_width(cr, 1);
            c.cairo_stroke(cr);
        }
        _ = drawTextAligned(cr, bx + bw / 2, cy, label, self.theme.font_small, if (filled) self.theme.on_accent else self.theme.text, .center);
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
