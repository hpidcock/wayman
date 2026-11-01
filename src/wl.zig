// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! Wayland client: display connection, seat input (pointer, keyboard via
//! xkbcommon), outputs, wl_shm buffers and the wlr-layer-shell popup.
//!
//! Everything UI-specific lives in ui.zig; this file only reports input
//! events through `Callbacks` and hands out cairo frames to draw into.
const std = @import("std");
const c = @import("c");

const log = std.log.scoped(.wl);
const Allocator = std.mem.Allocator;

pub const Modifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub const Callbacks = struct {
    ctx: *anyopaque,
    pointer_motion: *const fn (*anyopaque, f64, f64) void,
    pointer_leave: *const fn (*anyopaque) void,
    pointer_button: *const fn (*anyopaque, u32, bool) void,
    axis: *const fn (*anyopaque, f64) void,
    key: *const fn (*anyopaque, u32, []const u8, Modifiers) void,
    /// The user clicked outside the popup (or it otherwise lost control).
    dismiss: *const fn (*anyopaque) void,
    /// The popup is configured (or its scale changed) and wants a frame.
    popup_ready: *const fn (*anyopaque) void,
    /// The compositor closed the popup.
    popup_closed: *const fn (*anyopaque) void,
};

const Output = struct {
    wl: *c.wl_output,
    name: u32,
    scale: i32 = 1,
};

const Buffer = struct {
    gpa: Allocator,
    wl: *c.wl_buffer,
    map: []align(std.heap.page_size_min) u8,
    width: u32,
    height: u32,
    stride: u32,
    busy: bool = false,
    /// Destroy as soon as the compositor releases it.
    orphan: bool = false,

    const listener: c.wl_buffer_listener = .{ .release = onRelease };

    fn create(gpa: Allocator, shm: *c.wl_shm, width: u32, height: u32) !*Buffer {
        const stride = width * 4;
        const size: usize = @as(usize, stride) * height;
        const fd = try std.posix.memfd_create("wayman-shm", std.posix.MFD.CLOEXEC);
        defer _ = c.close(fd);
        if (c.ftruncate(fd, @intCast(size)) != 0) return error.ShmCreate;
        const map = try std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        errdefer std.posix.munmap(map);

        const pool = c.wl_shm_create_pool(shm, fd, @intCast(size)) orelse return error.ShmCreate;
        defer c.wl_shm_pool_destroy(pool);
        const wl_buf = c.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(stride), c.WL_SHM_FORMAT_ARGB8888) orelse return error.ShmCreate;

        const self = try gpa.create(Buffer);
        self.* = .{ .gpa = gpa, .wl = wl_buf, .map = map, .width = width, .height = height, .stride = stride };
        _ = c.wl_buffer_add_listener(wl_buf, &listener, self);
        return self;
    }

    fn destroy(self: *Buffer) void {
        c.wl_buffer_destroy(self.wl);
        std.posix.munmap(self.map);
        self.gpa.destroy(self);
    }

    fn onRelease(data: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
        const self: *Buffer = @ptrCast(@alignCast(data orelse return));
        self.busy = false;
        if (self.orphan) self.destroy();
    }
};

pub const Frame = struct {
    cr: *c.cairo_t,
    surface: *c.cairo_surface_t,
    buffer: *Buffer,
    /// Logical size; the cairo context is already scaled.
    width: f64,
    height: f64,
};

/// A transparent layer surface covering the whole output underneath the
/// popup. Any click on it dismisses the popup.
const Shield = struct {
    surface: *c.wl_surface,
    layer: *c.zwlr_layer_surface_v1,
    viewport: *c.wp_viewport,
    buffer: *Buffer,
};

const Popup = struct {
    surface: *c.wl_surface,
    layer: *c.zwlr_layer_surface_v1,
    width: u32,
    height: u32,
    scale: i32 = 1,
    configured: bool = false,
    buffers: [2]?*Buffer = .{ null, null },
    shield: ?Shield = null,
};

pub const Client = struct {
    gpa: Allocator,
    cbs: Callbacks,
    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: ?*c.wl_compositor = null,
    compositor_version: u32 = 0,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    layer_shell_version: u32 = 0,
    viewporter: ?*c.wp_viewporter = null,
    data_device_manager: ?*c.wl_data_device_manager = null,
    data_device: ?*c.wl_data_device = null,
    primary_manager: ?*c.zwp_primary_selection_device_manager_v1 = null,
    primary_device: ?*c.zwp_primary_selection_device_v1 = null,
    /// The current clipboard and primary-selection offers, if any.
    clipboard: Selection = .{},
    primary: Selection = .{},
    seat: ?*c.wl_seat = null,
    pointer: ?*c.wl_pointer = null,
    keyboard: ?*c.wl_keyboard = null,
    outputs: std.ArrayList(Output) = .empty,
    xkb_context: *c.xkb_context,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_state: ?*c.xkb_state = null,
    mods: Modifiers = .{},
    cursor_theme: ?*c.wl_cursor_theme = null,
    cursor_surface: ?*c.wl_surface = null,
    cursor_scale: i32 = 0,
    popup: ?Popup = null,
    pointer_in_popup: bool = false,
    pointer_in_shield: bool = false,
    keyboard_in_popup: bool = false,

    pub fn init(self: *Client, gpa: Allocator, cbs: Callbacks) !void {
        const display = c.wl_display_connect(null) orelse {
            log.err("cannot connect to the Wayland display; is WAYLAND_DISPLAY set?", .{});
            return error.NoDisplay;
        };
        errdefer c.wl_display_disconnect(display);
        const xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.Xkb;
        self.* = .{
            .gpa = gpa,
            .cbs = cbs,
            .display = display,
            .registry = undefined,
            .xkb_context = xkb_context,
        };
        self.registry = c.wl_display_get_registry(display) orelse return error.NoRegistry;
        _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);
        // First round trip delivers the globals, the second the events of
        // the objects bound in response (output scales, seat capabilities).
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandRoundtrip;
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandRoundtrip;
        if (self.compositor == null or self.shm == null) {
            log.err("the compositor lacks wl_compositor or wl_shm", .{});
            return error.MissingGlobals;
        }
        if (self.layer_shell == null) {
            log.err("the compositor does not support zwlr_layer_shell_v1 (sway, river, hyprland and others do)", .{});
            return error.NoLayerShell;
        }
    }

    pub fn deinit(self: *Client) void {
        self.destroyPopup();
        if (self.clipboard.offer) |o| c.wl_data_offer_destroy(@ptrCast(o));
        if (self.primary.offer) |o| c.zwp_primary_selection_offer_v1_destroy(@ptrCast(o));
        if (self.data_device) |d| c.wl_data_device_release(d);
        if (self.primary_device) |d| c.zwp_primary_selection_device_v1_destroy(d);
        if (self.cursor_surface) |s| c.wl_surface_destroy(s);
        if (self.cursor_theme) |t| c.wl_cursor_theme_destroy(t);
        if (self.xkb_state) |s| c.xkb_state_unref(s);
        if (self.xkb_keymap) |k| c.xkb_keymap_unref(k);
        c.xkb_context_unref(self.xkb_context);
        self.outputs.deinit(self.gpa);
        c.wl_display_disconnect(self.display);
    }

    // ---- event loop integration ---------------------------------------

    pub fn fd(self: *Client) std.posix.fd_t {
        return c.wl_display_get_fd(self.display);
    }

    /// Call before polling: dispatches queued events and flushes requests.
    pub fn prepare(self: *Client) void {
        while (c.wl_display_prepare_read(self.display) != 0) {
            _ = c.wl_display_dispatch_pending(self.display);
        }
        _ = c.wl_display_flush(self.display);
    }

    /// Call after polling with whether the display fd was readable.
    pub fn finish(self: *Client, readable: bool) !void {
        if (readable) {
            if (c.wl_display_read_events(self.display) != 0) return error.WaylandRead;
        } else {
            c.wl_display_cancel_read(self.display);
        }
        if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDispatch;
    }

    pub fn flush(self: *Client) void {
        _ = c.wl_display_flush(self.display);
    }

    // ---- registry ------------------------------------------------------

    const registry_listener: c.wl_registry_listener = .{
        .global = onGlobal,
        .global_remove = onGlobalRemove,
    };

    fn fromData(data: ?*anyopaque) *Client {
        return @ptrCast(@alignCast(data.?));
    }

    fn onGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self = fromData(data);
        const iface = std.mem.span(interface);
        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor_version = @min(version, 6);
            self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, self.compositor_version));
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
            self.layer_shell_version = @min(version, 4);
            self.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, self.layer_shell_version));
        } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
            self.viewporter = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_viewporter_interface, 1));
        } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
            self.data_device_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_data_device_manager_interface, @min(version, 3)));
            self.setupSelections();
        } else if (std.mem.eql(u8, iface, "zwp_primary_selection_device_manager_v1")) {
            self.primary_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zwp_primary_selection_device_manager_v1_interface, 1));
            self.setupSelections();
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            if (self.seat != null) return;
            const seat: *c.wl_seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 7)) orelse return);
            self.seat = seat;
            _ = c.wl_seat_add_listener(seat, &seat_listener, self);
            self.setupSelections();
        } else if (std.mem.eql(u8, iface, "wl_output")) {
            const output: *c.wl_output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, @min(version, 2)) orelse return);
            self.outputs.append(self.gpa, .{ .wl = output, .name = name }) catch {
                c.wl_output_release(output);
                return;
            };
            _ = c.wl_output_add_listener(output, &output_listener, self);
        }
    }

    fn onGlobalRemove(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
        const self = fromData(data);
        for (self.outputs.items, 0..) |o, i| {
            if (o.name == name) {
                c.wl_output_release(o.wl);
                _ = self.outputs.swapRemove(i);
                return;
            }
        }
    }

    // ---- outputs -------------------------------------------------------

    const output_listener: c.wl_output_listener = .{
        .geometry = onOutputGeometry,
        .mode = onOutputMode,
        .done = onOutputDone,
        .scale = onOutputScale,
        .name = onOutputName,
        .description = onOutputDescription,
    };

    fn onOutputGeometry(_: ?*anyopaque, _: ?*c.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
    fn onOutputMode(_: ?*anyopaque, _: ?*c.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
    fn onOutputDone(_: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {}
    fn onOutputName(_: ?*anyopaque, _: ?*c.wl_output, _: [*c]const u8) callconv(.c) void {}
    fn onOutputDescription(_: ?*anyopaque, _: ?*c.wl_output, _: [*c]const u8) callconv(.c) void {}

    fn onOutputScale(data: ?*anyopaque, output: ?*c.wl_output, factor: i32) callconv(.c) void {
        const self = fromData(data);
        for (self.outputs.items) |*o| {
            if (o.wl == output) o.scale = factor;
        }
    }

    fn outputScale(self: *Client, output: ?*c.wl_output) i32 {
        for (self.outputs.items) |o| {
            if (o.wl == output) return o.scale;
        }
        return 1;
    }

    // ---- clipboard / primary selection ---------------------------------

    /// An offer as advertised by the compositor and the text types it carries.
    const Selection = struct {
        offer: ?*anyopaque = null,
        utf8: bool = false,
        plain: bool = false,

        fn reset(sel: *Selection) void {
            sel.* = .{};
        }

        fn mime(sel: Selection) ?[*:0]const u8 {
            if (sel.utf8) return "text/plain;charset=utf-8";
            if (sel.plain) return "text/plain";
            return null;
        }

        fn noteMime(sel: *Selection, mime_type: []const u8) void {
            if (std.ascii.eqlIgnoreCase(mime_type, "text/plain;charset=utf-8") or std.ascii.eqlIgnoreCase(mime_type, "UTF8_STRING")) sel.utf8 = true;
            if (std.ascii.eqlIgnoreCase(mime_type, "text/plain") or std.ascii.eqlIgnoreCase(mime_type, "TEXT") or std.ascii.eqlIgnoreCase(mime_type, "STRING")) sel.plain = true;
        }
    };

    /// Creates the per-seat selection devices once both the seat and a
    /// manager are known.
    fn setupSelections(self: *Client) void {
        const seat = self.seat orelse return;
        if (self.data_device == null) {
            if (self.data_device_manager) |m| {
                if (c.wl_data_device_manager_get_data_device(m, seat)) |d| {
                    self.data_device = d;
                    _ = c.wl_data_device_add_listener(d, &data_device_listener, self);
                }
            }
        }
        if (self.primary_device == null) {
            if (self.primary_manager) |m| {
                if (c.zwp_primary_selection_device_manager_v1_get_device(m, seat)) |d| {
                    self.primary_device = d;
                    _ = c.zwp_primary_selection_device_v1_add_listener(d, &primary_device_listener, self);
                }
            }
        }
    }

    const data_device_listener: c.wl_data_device_listener = .{
        .data_offer = onDataOffer,
        .enter = onDndEnter,
        .leave = onDndLeave,
        .motion = onDndMotion,
        .drop = onDndDrop,
        .selection = onSelection,
    };

    const data_offer_listener: c.wl_data_offer_listener = .{
        .offer = onOfferMime,
        .source_actions = onOfferSourceActions,
        .action = onOfferAction,
    };

    const primary_device_listener: c.zwp_primary_selection_device_v1_listener = .{
        .data_offer = onPrimaryOffer,
        .selection = onPrimarySelection,
    };

    const primary_offer_listener: c.zwp_primary_selection_offer_v1_listener = .{
        .offer = onPrimaryOfferMime,
    };

    /// Offers announce their mime types before becoming the selection, so
    /// the types are collected per offer and copied over on `selection`.
    const OfferInfo = struct { sel: Selection = .{} };

    fn onDataOffer(_: ?*anyopaque, _: ?*c.wl_data_device, offer: ?*c.wl_data_offer) callconv(.c) void {
        const info = std.heap.c_allocator.create(OfferInfo) catch return;
        info.* = .{};
        _ = c.wl_data_offer_add_listener(offer, &data_offer_listener, info);
    }

    fn onOfferMime(data: ?*anyopaque, _: ?*c.wl_data_offer, mime_type: [*c]const u8) callconv(.c) void {
        const info: *OfferInfo = @ptrCast(@alignCast(data orelse return));
        info.sel.noteMime(std.mem.span(mime_type));
    }

    fn onOfferSourceActions(_: ?*anyopaque, _: ?*c.wl_data_offer, _: u32) callconv(.c) void {}
    fn onOfferAction(_: ?*anyopaque, _: ?*c.wl_data_offer, _: u32) callconv(.c) void {}
    fn onDndEnter(_: ?*anyopaque, _: ?*c.wl_data_device, _: u32, _: ?*c.wl_surface, _: c.wl_fixed_t, _: c.wl_fixed_t, _: ?*c.wl_data_offer) callconv(.c) void {}
    fn onDndLeave(_: ?*anyopaque, _: ?*c.wl_data_device) callconv(.c) void {}
    fn onDndMotion(_: ?*anyopaque, _: ?*c.wl_data_device, _: u32, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {}
    fn onDndDrop(_: ?*anyopaque, _: ?*c.wl_data_device) callconv(.c) void {}

    fn onSelection(data: ?*anyopaque, _: ?*c.wl_data_device, offer: ?*c.wl_data_offer) callconv(.c) void {
        const self = fromData(data);
        if (self.clipboard.offer) |old| c.wl_data_offer_destroy(@ptrCast(old));
        self.clipboard.reset();
        const o = offer orelse {
            log.debug("clipboard cleared", .{});
            return;
        };
        const info: *OfferInfo = @ptrCast(@alignCast(c.wl_data_offer_get_user_data(o) orelse return));
        self.clipboard = info.sel;
        self.clipboard.offer = o;
        std.heap.c_allocator.destroy(info);
        log.debug("clipboard offer: utf8={} plain={}", .{ self.clipboard.utf8, self.clipboard.plain });
    }

    fn onPrimaryOffer(_: ?*anyopaque, _: ?*c.zwp_primary_selection_device_v1, offer: ?*c.zwp_primary_selection_offer_v1) callconv(.c) void {
        const info = std.heap.c_allocator.create(OfferInfo) catch return;
        info.* = .{};
        _ = c.zwp_primary_selection_offer_v1_add_listener(offer, &primary_offer_listener, info);
    }

    fn onPrimaryOfferMime(data: ?*anyopaque, _: ?*c.zwp_primary_selection_offer_v1, mime_type: [*c]const u8) callconv(.c) void {
        const info: *OfferInfo = @ptrCast(@alignCast(data orelse return));
        info.sel.noteMime(std.mem.span(mime_type));
    }

    fn onPrimarySelection(data: ?*anyopaque, _: ?*c.zwp_primary_selection_device_v1, offer: ?*c.zwp_primary_selection_offer_v1) callconv(.c) void {
        const self = fromData(data);
        if (self.primary.offer) |old| c.zwp_primary_selection_offer_v1_destroy(@ptrCast(old));
        self.primary.reset();
        const o = offer orelse return;
        const info: *OfferInfo = @ptrCast(@alignCast(c.zwp_primary_selection_offer_v1_get_user_data(o) orelse return));
        self.primary = info.sel;
        self.primary.offer = o;
        std.heap.c_allocator.destroy(info);
        log.debug("primary selection offer: utf8={} plain={}", .{ self.primary.utf8, self.primary.plain });
    }

    pub const Source = enum { clipboard, primary };

    /// Reads the text of the clipboard or primary selection. Caller owns
    /// the result. Null when there is no text or the owner does not answer
    /// within a short time.
    pub fn readSelection(self: *Client, gpa: Allocator, source: Source) ?[]u8 {
        const sel = switch (source) {
            .clipboard => self.clipboard,
            .primary => self.primary,
        };
        const offer = sel.offer orelse {
            log.debug("paste: no {t} offer", .{source});
            return null;
        };
        const mime_type = sel.mime() orelse {
            log.debug("paste: {t} offer has no text", .{source});
            return null;
        };
        var fds: [2]std.posix.fd_t = undefined;
        if (std.os.linux.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return null;
        switch (source) {
            .clipboard => c.wl_data_offer_receive(@ptrCast(offer), mime_type, fds[1]),
            .primary => c.zwp_primary_selection_offer_v1_receive(@ptrCast(offer), mime_type, fds[1]),
        }
        _ = c.close(fds[1]);
        _ = c.wl_display_flush(self.display);
        defer _ = c.close(fds[0]);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var buf: [4096]u8 = undefined;
        var deadline: i32 = 1000;
        while (deadline > 0) {
            var pfd = [_]c.struct_pollfd{.{ .fd = fds[0], .events = c.POLLIN, .revents = 0 }};
            const ready = c.poll(&pfd, 1, 100);
            if (ready < 0) break;
            if (ready == 0) {
                deadline -= 100;
                continue;
            }
            const n = c.read(fds[0], &buf, buf.len);
            if (n <= 0) break;
            out.appendSlice(gpa, buf[0..@intCast(n)]) catch break;
            if (out.items.len > 64 * 1024) break;
        }
        log.debug("paste: read {d} bytes from the {t}", .{ out.items.len, source });
        if (out.items.len == 0) {
            out.deinit(gpa);
            return null;
        }
        return out.toOwnedSlice(gpa) catch null;
    }

    // ---- seat ----------------------------------------------------------

    const seat_listener: c.wl_seat_listener = .{
        .capabilities = onSeatCapabilities,
        .name = onSeatName,
    };

    fn onSeatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.c) void {}

    fn onSeatCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, caps: u32) callconv(.c) void {
        const self = fromData(data);
        const has_pointer = caps & c.WL_SEAT_CAPABILITY_POINTER != 0;
        const has_keyboard = caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0;
        if (has_pointer and self.pointer == null) {
            if (c.wl_seat_get_pointer(seat)) |p| {
                self.pointer = p;
                _ = c.wl_pointer_add_listener(p, &pointer_listener, self);
            }
        } else if (!has_pointer and self.pointer != null) {
            c.wl_pointer_release(self.pointer);
            self.pointer = null;
        }
        if (has_keyboard and self.keyboard == null) {
            if (c.wl_seat_get_keyboard(seat)) |k| {
                self.keyboard = k;
                _ = c.wl_keyboard_add_listener(k, &keyboard_listener, self);
            }
        } else if (!has_keyboard and self.keyboard != null) {
            c.wl_keyboard_release(self.keyboard);
            self.keyboard = null;
        }
    }

    const pointer_listener: c.wl_pointer_listener = .{
        .enter = onPointerEnter,
        .leave = onPointerLeave,
        .motion = onPointerMotion,
        .button = onPointerButton,
        .axis = onPointerAxis,
        .frame = onPointerFrame,
        .axis_source = onPointerAxisSource,
        .axis_stop = onPointerAxisStop,
        .axis_discrete = onPointerAxisDiscrete,
        .axis_value120 = onPointerAxisValue120,
        .axis_relative_direction = onPointerAxisRelativeDirection,
    };

    fn onPointerFrame(_: ?*anyopaque, _: ?*c.wl_pointer) callconv(.c) void {}
    fn onPointerAxisSource(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32) callconv(.c) void {}
    fn onPointerAxisStop(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn onPointerAxisDiscrete(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPointerAxisValue120(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPointerAxisRelativeDirection(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}

    fn isPopupSurface(self: *Client, surface: ?*c.wl_surface) bool {
        const p = self.popup orelse return false;
        return p.surface == surface;
    }

    fn isShieldSurface(self: *Client, surface: ?*c.wl_surface) bool {
        const p = self.popup orelse return false;
        const sh = p.shield orelse return false;
        return sh.surface == surface;
    }

    fn onPointerEnter(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        const self = fromData(data);
        if (self.isShieldSurface(surface)) {
            self.pointer_in_shield = true;
            self.setCursor(serial);
            return;
        }
        if (!self.isPopupSurface(surface)) return;
        self.pointer_in_popup = true;
        self.setCursor(serial);
        self.cbs.pointer_motion(self.cbs.ctx, c.wl_fixed_to_double(sx), c.wl_fixed_to_double(sy));
    }

    fn onPointerLeave(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, surface: ?*c.wl_surface) callconv(.c) void {
        const self = fromData(data);
        if (self.isShieldSurface(surface)) self.pointer_in_shield = false;
        if (!self.pointer_in_popup or !self.isPopupSurface(surface)) return;
        self.pointer_in_popup = false;
        self.cbs.pointer_leave(self.cbs.ctx);
    }

    fn onPointerMotion(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        const self = fromData(data);
        if (!self.pointer_in_popup) return;
        self.cbs.pointer_motion(self.cbs.ctx, c.wl_fixed_to_double(sx), c.wl_fixed_to_double(sy));
    }

    fn onPointerButton(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        const self = fromData(data);
        if (self.pointer_in_shield and state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
            log.debug("click outside the popup", .{});
            self.cbs.dismiss(self.cbs.ctx);
            return;
        }
        if (!self.pointer_in_popup) return;
        self.cbs.pointer_button(self.cbs.ctx, button, state == c.WL_POINTER_BUTTON_STATE_PRESSED);
    }

    fn onPointerAxis(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
        const self = fromData(data);
        if (!self.pointer_in_popup or axis != c.WL_POINTER_AXIS_VERTICAL_SCROLL) return;
        self.cbs.axis(self.cbs.ctx, c.wl_fixed_to_double(value));
    }

    fn setCursor(self: *Client, serial: u32) void {
        const pointer = self.pointer orelse return;
        const shm = self.shm orelse return;
        const scale = if (self.popup) |p| p.scale else 1;
        if (self.cursor_theme == null or self.cursor_scale != scale) {
            if (self.cursor_theme) |t| c.wl_cursor_theme_destroy(t);
            self.cursor_theme = c.wl_cursor_theme_load(null, 24 * scale, shm);
            self.cursor_scale = scale;
        }
        const theme = self.cursor_theme orelse return;
        const cursor = c.wl_cursor_theme_get_cursor(theme, "default") orelse
            c.wl_cursor_theme_get_cursor(theme, "left_ptr") orelse return;
        if (cursor.*.image_count == 0) return;
        const image = cursor.*.images[0];
        const buffer = c.wl_cursor_image_get_buffer(image) orelse return;
        if (self.cursor_surface == null) {
            self.cursor_surface = c.wl_compositor_create_surface(self.compositor) orelse return;
        }
        const surface = self.cursor_surface.?;
        c.wl_surface_set_buffer_scale(surface, scale);
        c.wl_surface_attach(surface, buffer, 0, 0);
        c.wl_surface_damage(surface, 0, 0, @intCast(image.*.width), @intCast(image.*.height));
        c.wl_surface_commit(surface);
        c.wl_pointer_set_cursor(pointer, serial, surface, @divTrunc(@as(i32, @intCast(image.*.hotspot_x)), scale), @divTrunc(@as(i32, @intCast(image.*.hotspot_y)), scale));
    }

    const keyboard_listener: c.wl_keyboard_listener = .{
        .keymap = onKeymap,
        .enter = onKeyboardEnter,
        .leave = onKeyboardLeave,
        .key = onKey,
        .modifiers = onModifiers,
        .repeat_info = onRepeatInfo,
    };

    fn onRepeatInfo(_: ?*anyopaque, _: ?*c.wl_keyboard, _: i32, _: i32) callconv(.c) void {}

    fn onKeymap(data: ?*anyopaque, _: ?*c.wl_keyboard, format: u32, map_fd: i32, size: u32) callconv(.c) void {
        const self = fromData(data);
        defer _ = c.close(map_fd);
        if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;
        const map = std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, map_fd, 0) catch |err| {
            log.warn("cannot map keymap: {t}", .{err});
            return;
        };
        defer std.posix.munmap(map);
        const keymap = c.xkb_keymap_new_from_string(self.xkb_context, @ptrCast(map.ptr), c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse {
            log.warn("cannot compile keymap", .{});
            return;
        };
        const state = c.xkb_state_new(keymap) orelse {
            c.xkb_keymap_unref(keymap);
            return;
        };
        if (self.xkb_state) |s| c.xkb_state_unref(s);
        if (self.xkb_keymap) |k| c.xkb_keymap_unref(k);
        self.xkb_keymap = keymap;
        self.xkb_state = state;
    }

    fn onKeyboardEnter(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, surface: ?*c.wl_surface, _: [*c]c.wl_array) callconv(.c) void {
        const self = fromData(data);
        if (self.isPopupSurface(surface)) {
            self.keyboard_in_popup = true;
            log.debug("popup gained keyboard focus", .{});
        }
    }

    fn onKeyboardLeave(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.c) void {
        const self = fromData(data);
        if (!self.keyboard_in_popup) return;
        self.keyboard_in_popup = false;
        log.debug("popup lost keyboard focus", .{});
    }

    fn onKey(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const self = fromData(data);
        if (!self.keyboard_in_popup or state != c.WL_KEYBOARD_KEY_STATE_PRESSED) return;
        const xkb_state = self.xkb_state orelse return;
        const keycode: c.xkb_keycode_t = key + 8;
        const sym = c.xkb_state_key_get_one_sym(xkb_state, keycode);
        var buf: [32]u8 = undefined;
        const n = c.xkb_state_key_get_utf8(xkb_state, keycode, &buf, buf.len);
        const text: []const u8 = if (n > 0) buf[0..@min(@as(usize, @intCast(n)), buf.len - 1)] else "";
        self.cbs.key(self.cbs.ctx, sym, text, self.mods);
    }

    fn onModifiers(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        const self = fromData(data);
        const xkb_state = self.xkb_state orelse return;
        _ = c.xkb_state_update_mask(xkb_state, depressed, latched, locked, 0, 0, group);
        self.mods = .{
            .ctrl = c.xkb_state_mod_name_is_active(xkb_state, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) > 0,
            .shift = c.xkb_state_mod_name_is_active(xkb_state, c.XKB_MOD_NAME_SHIFT, c.XKB_STATE_MODS_EFFECTIVE) > 0,
            .alt = c.xkb_state_mod_name_is_active(xkb_state, c.XKB_MOD_NAME_ALT, c.XKB_STATE_MODS_EFFECTIVE) > 0,
        };
    }

    // ---- popup ---------------------------------------------------------

    const surface_listener: c.wl_surface_listener = .{
        .enter = onSurfaceEnter,
        .leave = onSurfaceLeave,
        .preferred_buffer_scale = onPreferredScale,
        .preferred_buffer_transform = onPreferredTransform,
    };

    fn onSurfaceLeave(_: ?*anyopaque, _: ?*c.wl_surface, _: ?*c.wl_output) callconv(.c) void {}
    fn onPreferredTransform(_: ?*anyopaque, _: ?*c.wl_surface, _: u32) callconv(.c) void {}

    const layer_listener: c.zwlr_layer_surface_v1_listener = .{
        .configure = onLayerConfigure,
        .closed = onLayerClosed,
    };

    const shield_listener: c.zwlr_layer_surface_v1_listener = .{
        .configure = onShieldConfigure,
        .closed = onShieldClosed,
    };

    fn onShieldConfigure(data: ?*anyopaque, layer: ?*c.zwlr_layer_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
        const self = fromData(data);
        c.zwlr_layer_surface_v1_ack_configure(layer, serial);
        const p = &(self.popup orelse return);
        const sh = p.shield orelse return;
        if (width == 0 or height == 0) return;
        // Stretch the 1x1 transparent buffer over the whole output.
        c.wp_viewport_set_destination(sh.viewport, @intCast(width), @intCast(height));
        c.wl_surface_attach(sh.surface, sh.buffer.wl, 0, 0);
        c.wl_surface_damage(sh.surface, 0, 0, @intCast(width), @intCast(height));
        c.wl_surface_commit(sh.surface);
    }

    fn onShieldClosed(_: ?*anyopaque, _: ?*c.zwlr_layer_surface_v1) callconv(.c) void {}

    fn createShield(self: *Client) !Shield {
        const viewporter = self.viewporter orelse return error.NoViewporter;
        const buffer = try Buffer.create(self.gpa, self.shm.?, 1, 1);
        errdefer buffer.destroy();
        @memset(buffer.map, 0);
        const surface = c.wl_compositor_create_surface(self.compositor) orelse return error.Surface;
        errdefer c.wl_surface_destroy(surface);
        const viewport = c.wp_viewporter_get_viewport(viewporter, surface) orelse return error.Surface;
        errdefer c.wp_viewport_destroy(viewport);
        const layer = c.zwlr_layer_shell_v1_get_layer_surface(self.layer_shell, surface, null, c.ZWLR_LAYER_SHELL_V1_LAYER_TOP, "wayman-shield") orelse return error.Surface;
        _ = c.zwlr_layer_surface_v1_add_listener(layer, &shield_listener, self);
        c.zwlr_layer_surface_v1_set_anchor(layer, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer, -1);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(layer, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
        c.wl_surface_commit(surface);
        return .{ .surface = surface, .layer = layer, .viewport = viewport, .buffer = buffer };
    }

    fn destroyShield(sh: Shield) void {
        c.zwlr_layer_surface_v1_destroy(sh.layer);
        c.wp_viewport_destroy(sh.viewport);
        c.wl_surface_destroy(sh.surface);
        sh.buffer.destroy();
    }

    fn onSurfaceEnter(data: ?*anyopaque, _: ?*c.wl_surface, output: ?*c.wl_output) callconv(.c) void {
        const self = fromData(data);
        // With wl_compositor >= 6 the compositor tells us the scale directly.
        if (self.compositor_version >= 6) return;
        self.setPopupScale(self.outputScale(output));
    }

    fn onPreferredScale(data: ?*anyopaque, _: ?*c.wl_surface, factor: i32) callconv(.c) void {
        fromData(data).setPopupScale(factor);
    }

    fn setPopupScale(self: *Client, scale: i32) void {
        const p = &(self.popup orelse return);
        if (scale < 1 or p.scale == scale) return;
        p.scale = scale;
        if (p.configured) self.cbs.popup_ready(self.cbs.ctx);
    }

    fn onLayerConfigure(data: ?*anyopaque, layer: ?*c.zwlr_layer_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
        const self = fromData(data);
        c.zwlr_layer_surface_v1_ack_configure(layer, serial);
        const p = &(self.popup orelse return);
        if (width > 0) p.width = width;
        if (height > 0) p.height = height;
        p.configured = true;
        log.debug("popup configured {d}x{d} (scale {d})", .{ p.width, p.height, p.scale });
        self.cbs.popup_ready(self.cbs.ctx);
    }

    fn onLayerClosed(data: ?*anyopaque, _: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
        const self = fromData(data);
        log.debug("compositor closed the popup", .{});
        self.destroyPopup();
        self.cbs.popup_closed(self.cbs.ctx);
    }

    pub fn popupReady(self: *Client) bool {
        const p = self.popup orelse return false;
        return p.configured;
    }

    pub fn popupOpen(self: *Client) bool {
        return self.popup != null;
    }

    /// Create the popup anchored to the top-right corner of the focused
    /// output, just below the bar. Nothing is drawn until `popup_ready`.
    pub fn openPopup(self: *Client, width: u32, height: u32) !void {
        if (self.popup != null) return;
        // The shield is created first so that the popup stacks above it.
        const shield: ?Shield = self.createShield() catch |err| blk: {
            log.warn("no click-outside shield: {t}", .{err});
            break :blk null;
        };
        errdefer if (shield) |sh| destroyShield(sh);
        const surface = c.wl_compositor_create_surface(self.compositor) orelse return error.Surface;
        errdefer c.wl_surface_destroy(surface);
        const layer = c.zwlr_layer_shell_v1_get_layer_surface(self.layer_shell, surface, null, c.ZWLR_LAYER_SHELL_V1_LAYER_TOP, "wayman") orelse return error.Surface;
        self.popup = .{ .surface = surface, .layer = layer, .width = width, .height = height, .shield = shield };
        _ = c.wl_surface_add_listener(surface, &surface_listener, self);
        _ = c.zwlr_layer_surface_v1_add_listener(layer, &layer_listener, self);
        c.zwlr_layer_surface_v1_set_anchor(layer, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
        c.zwlr_layer_surface_v1_set_margin(layer, 6, 8, 0, 0);
        c.zwlr_layer_surface_v1_set_size(layer, width, height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer, 0);
        // Exclusive focus: sway drops on-demand focus from layer surfaces
        // whenever it re-arranges layers, so the popup would close itself.
        // Clicks outside are caught by the shield instead.
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(layer, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE);
        c.wl_surface_commit(surface);
        self.flush();
    }

    pub fn closePopup(self: *Client) void {
        self.destroyPopup();
        self.flush();
    }

    fn destroyPopup(self: *Client) void {
        const p = self.popup orelse return;
        for (p.buffers) |maybe| {
            if (maybe) |b| b.destroy();
        }
        c.zwlr_layer_surface_v1_destroy(p.layer);
        c.wl_surface_destroy(p.surface);
        if (p.shield) |sh| destroyShield(sh);
        self.popup = null;
        self.pointer_in_popup = false;
        self.pointer_in_shield = false;
        self.keyboard_in_popup = false;
    }

    /// Ask for a new size. Returns true when a configure round trip was
    /// started, in which case `popup_ready` follows.
    pub fn popupResize(self: *Client, width: u32, height: u32) bool {
        const p = &(self.popup orelse return false);
        if (p.width == width and p.height == height) return false;
        c.zwlr_layer_surface_v1_set_size(p.layer, width, height);
        c.wl_surface_commit(p.surface);
        self.flush();
        return true;
    }

    fn acquireBuffer(self: *Client, p: *Popup, width: u32, height: u32) !*Buffer {
        for (&p.buffers) |*slot| {
            if (slot.*) |b| {
                if (b.busy) continue;
                if (b.width == width and b.height == height) return b;
                b.destroy();
                slot.* = null;
            }
            const b = try Buffer.create(self.gpa, self.shm.?, width, height);
            slot.* = b;
            return b;
        }
        // Both slots are still held by the compositor; use a throwaway.
        const b = try Buffer.create(self.gpa, self.shm.?, width, height);
        b.orphan = true;
        return b;
    }

    /// Start drawing a frame for the popup. Returns null until configured.
    pub fn beginFrame(self: *Client) ?Frame {
        const p = &(self.popup orelse return null);
        if (!p.configured) return null;
        const scale: u32 = @intCast(p.scale);
        const pw = p.width * scale;
        const ph = p.height * scale;
        const buffer = self.acquireBuffer(p, pw, ph) catch |err| {
            log.err("cannot allocate a {d}x{d} buffer: {t}", .{ pw, ph, err });
            return null;
        };
        const surface = c.cairo_image_surface_create_for_data(buffer.map.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(pw), @intCast(ph), @intCast(buffer.stride)) orelse return null;
        const cr = c.cairo_create(surface) orelse {
            c.cairo_surface_destroy(surface);
            return null;
        };
        c.cairo_scale(cr, @floatFromInt(scale), @floatFromInt(scale));
        return .{
            .cr = cr,
            .surface = surface,
            .buffer = buffer,
            .width = @floatFromInt(p.width),
            .height = @floatFromInt(p.height),
        };
    }

    pub fn endFrame(self: *Client, frame: Frame) void {
        c.cairo_destroy(frame.cr);
        c.cairo_surface_flush(frame.surface);
        c.cairo_surface_destroy(frame.surface);
        const p = &(self.popup orelse return);
        c.wl_surface_set_buffer_scale(p.surface, p.scale);
        c.wl_surface_attach(p.surface, frame.buffer.wl, 0, 0);
        frame.buffer.busy = true;
        if (self.compositor_version >= 4) {
            c.wl_surface_damage_buffer(p.surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        } else {
            c.wl_surface_damage(p.surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        }
        c.wl_surface_commit(p.surface);
        self.flush();
    }
};
