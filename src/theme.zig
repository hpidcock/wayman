// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

//! Colours and fonts for the popup and the tray icon.
//!
//! By default the theme is derived from waybar's stylesheet so the popup
//! matches the bar: the bar's background and text colour, its font, and an
//! accent picked from the focused-workspace / mode rules. A plain CSS file
//! can be given instead with `--style`. Only a small CSS subset is
//! understood: rules with simple selectors, `@define-color`, `@import`, and
//! colours written as hex, rgb()/rgba(), names, or GTK's alpha()/shade()/mix().
const std = @import("std");
const icon = @import("icon.zig");

const Allocator = std.mem.Allocator;
const Color = icon.Color;
const log = std.log.scoped(.theme);

pub const Theme = struct {
    /// Popup panel background.
    bg: Color,
    /// Primary text.
    text: Color,
    /// Secondary text (labels such as "Saved").
    muted: Color,
    /// Active network, toggle, filled buttons.
    accent: Color,
    /// Text drawn on top of `accent`.
    on_accent: Color,
    /// Row hover highlight.
    hover: Color,
    /// Panel outline and separators.
    border: Color,
    /// Empty signal bars.
    dim: Color,
    /// Text field background.
    field: Color,
    /// Error text.
    danger: Color,
    /// Tray icon colour (normally the bar's text colour).
    tray: Color,
    font_regular: [:0]const u8,
    font_bold: [:0]const u8,
    font_title: [:0]const u8,
    font_small: [:0]const u8,
    /// Set when the font strings were allocated and must be freed.
    owned: bool = false,

    pub const builtin: Theme = .{
        .bg = Color.rgb(0x1e1e2e).withAlpha(0.97),
        .text = Color.rgb(0xcdd6f4),
        .muted = Color.rgb(0xa6adc8),
        .accent = Color.rgb(0x89b4fa),
        .on_accent = Color.rgb(0x1e1e2e),
        .hover = Color.rgb(0xffffff).withAlpha(0.06),
        .border = Color.rgb(0xffffff).withAlpha(0.08),
        .dim = Color.rgb(0xffffff).withAlpha(0.22),
        .field = Color.rgb(0xffffff).withAlpha(0.05),
        .danger = Color.rgb(0xf38ba8),
        .tray = Color.rgb(0xffffff),
        .font_regular = "Sans 10.5",
        .font_bold = "Sans Bold 10.5",
        .font_title = "Sans Bold 12",
        .font_small = "Sans 9",
    };

    pub fn deinit(self: *Theme, gpa: Allocator) void {
        if (!self.owned) return;
        gpa.free(self.font_regular);
        gpa.free(self.font_bold);
        gpa.free(self.font_title);
        gpa.free(self.font_small);
        self.owned = false;
    }

    /// Looks for waybar's stylesheet in the places waybar itself looks and
    /// derives a theme from it. Returns null when none is found.
    pub fn fromWaybar(gpa: Allocator, io: std.Io, environ: *std.process.Environ.Map) !?Theme {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidates = [_]struct { env: ?[]const u8, suffix: []const u8 }{
            .{ .env = "XDG_CONFIG_HOME", .suffix = "/waybar/style.css" },
            .{ .env = "HOME", .suffix = "/.config/waybar/style.css" },
            .{ .env = "HOME", .suffix = "/waybar/style.css" },
            .{ .env = null, .suffix = "/etc/xdg/waybar/style.css" },
        };
        for (candidates) |cand| {
            const prefix: []const u8 = if (cand.env) |name| environ.get(name) orelse continue else "";
            if (prefix.len == 0 and cand.env != null) continue;
            const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, cand.suffix }) catch continue;
            var sheet = Stylesheet.load(gpa, io, path) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.AccessDenied => continue,
                else => {
                    log.warn("cannot read {s}: {t}", .{ path, err });
                    continue;
                },
            };
            defer sheet.deinit();
            log.info("theme derived from {s}", .{path});
            return try fromStylesheet(gpa, &sheet);
        }
        return null;
    }

    pub fn fromCssFile(gpa: Allocator, io: std.Io, path: []const u8) !Theme {
        var sheet = try Stylesheet.load(gpa, io, path);
        defer sheet.deinit();
        log.info("theme loaded from {s}", .{path});
        return try fromStylesheet(gpa, &sheet);
    }

    pub fn fromStylesheet(gpa: Allocator, sheet: *Stylesheet) !Theme {
        const bar = [_][]const u8{ "window#waybar", "#waybar", "window", "*" };
        const bg_props = [_][]const u8{ "background-color", "background" };
        const fg_props = [_][]const u8{"color"};

        var t = Theme.builtin;

        if (sheet.getColor(&bar, &bg_props)) |bg| {
            if (bg.a > 0.05) {
                // A translucent bar is fine; a translucent popup over a
                // window full of text is not, so keep it mostly opaque.
                t.bg = bg.withAlpha(@max(bg.a, 0.9));
            }
        }
        if (sheet.getColor(&bar, &fg_props)) |fg| t.text = fg.withAlpha(1.0);

        const opaque_bg = t.bg.withAlpha(1.0);
        const text_on_bg = composite(t.text, opaque_bg);

        // Accent: the first candidate that stands out against the background.
        const accent_candidates = [_]struct { sel: []const u8, props: []const []const u8 }{
            .{ .sel = "#workspaces button.focused", .props = &.{ "background-color", "background" } },
            .{ .sel = "#workspaces button.active", .props = &.{ "background-color", "background" } },
            .{ .sel = "#workspaces button.focused", .props = &.{ "border-bottom", "border-top", "border", "color" } },
            .{ .sel = "#mode", .props = &.{ "background-color", "background" } },
            .{ .sel = "#workspaces button.urgent", .props = &.{ "background-color", "background" } },
            .{ .sel = "#clock", .props = &.{ "background-color", "background" } },
        };
        var accent: ?Color = null;
        for (accent_candidates) |cand| {
            const c = sheet.getColor(&.{cand.sel}, cand.props) orelse continue;
            if (c.a < 0.2) continue;
            const flat = composite(c, opaque_bg);
            if (contrast(flat, opaque_bg) >= 1.8 and contrast(flat, text_on_bg) >= 1.15) {
                accent = flat;
                break;
            }
        }
        t.accent = accent orelse text_on_bg;
        t.on_accent = if (luminance(t.accent) > 0.4) Color.rgb(0x111111) else Color.rgb(0xf4f4f4);

        const danger_candidates = [_]struct { sel: []const u8, props: []const []const u8 }{
            .{ .sel = "#battery.critical", .props = &.{ "color", "background-color", "background" } },
            .{ .sel = "#battery.critical:not(.charging)", .props = &.{ "color", "background-color", "background" } },
            .{ .sel = "#workspaces button.urgent", .props = &.{ "background-color", "background", "color" } },
        };
        for (danger_candidates) |cand| {
            const c = sheet.getColor(&.{cand.sel}, cand.props) orelse continue;
            if (c.a < 0.2) continue;
            const flat = composite(c, opaque_bg);
            if (contrast(flat, opaque_bg) >= 1.8) {
                t.danger = flat;
                break;
            }
        }

        t.muted = mix(t.text, opaque_bg, 0.35);
        t.hover = t.text.withAlpha(0.08);
        t.border = t.text.withAlpha(0.12);
        t.dim = t.text.withAlpha(0.25);
        t.field = t.text.withAlpha(0.06);
        t.tray = t.text;

        // Fonts.
        const family = sheet.getFontFamily(&bar) orelse "Sans";
        const size_px = sheet.getFontSizePx(&bar) orelse 14.0;
        t.font_regular = try std.fmt.allocPrintSentinel(gpa, "{s} {d}px", .{ family, size_px }, 0);
        errdefer gpa.free(t.font_regular);
        t.font_bold = try std.fmt.allocPrintSentinel(gpa, "{s} Bold {d}px", .{ family, size_px }, 0);
        errdefer gpa.free(t.font_bold);
        t.font_title = try std.fmt.allocPrintSentinel(gpa, "{s} Bold {d}px", .{ family, size_px + 2.0 }, 0);
        errdefer gpa.free(t.font_title);
        t.font_small = try std.fmt.allocPrintSentinel(gpa, "{s} {d}px", .{ family, @max(8.0, size_px - 2.0) }, 0);
        t.owned = true;
        return t;
    }
};

// ---- colour maths ---------------------------------------------------------

/// `fg` drawn over an opaque `bg`.
pub fn composite(fg: Color, bg: Color) Color {
    return .{
        .r = fg.r * fg.a + bg.r * (1.0 - fg.a),
        .g = fg.g * fg.a + bg.g * (1.0 - fg.a),
        .b = fg.b * fg.a + bg.b * (1.0 - fg.a),
        .a = 1.0,
    };
}

pub fn mix(a: Color, b: Color, amount: f64) Color {
    return .{
        .r = a.r * (1.0 - amount) + b.r * amount,
        .g = a.g * (1.0 - amount) + b.g * amount,
        .b = a.b * (1.0 - amount) + b.b * amount,
        .a = a.a * (1.0 - amount) + b.a * amount,
    };
}

fn linear(channel: f64) f64 {
    return if (channel <= 0.03928) channel / 12.92 else std.math.pow(f64, (channel + 0.055) / 1.055, 2.4);
}

/// WCAG relative luminance of an opaque colour.
pub fn luminance(c: Color) f64 {
    return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
}

/// WCAG contrast ratio between two opaque colours (1..21).
pub fn contrast(a: Color, b: Color) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

// ---- stylesheet -------------------------------------------------------------

const Rule = struct {
    selector: []const u8,
    property: []const u8,
    value: []const u8,
};

pub const Stylesheet = struct {
    arena: std.heap.ArenaAllocator,
    rules: std.ArrayList(Rule) = .empty,
    /// `@define-color` names (without the `@`) to their raw values.
    colors: std.StringHashMapUnmanaged([]const u8) = .empty,

    const max_import_depth = 4;
    const max_file_size = 1 << 20;

    pub fn init(gpa: Allocator) Stylesheet {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Stylesheet) void {
        self.arena.deinit();
    }

    pub fn load(gpa: Allocator, io: std.Io, path: []const u8) !Stylesheet {
        var self = Stylesheet.init(gpa);
        errdefer self.deinit();
        try self.loadFile(io, path, 0);
        return self;
    }

    const LoadError = error{OutOfMemory} || std.Io.Dir.ReadFileAllocError;

    fn loadFile(self: *Stylesheet, io: std.Io, path: []const u8, depth: u32) LoadError!void {
        const a = self.arena.allocator();
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_size));
        const dir = std.fs.path.dirname(path) orelse ".";
        try self.parse(text, dir, io, depth);
    }

    /// Parses CSS text. `base_dir` resolves relative `@import` paths; pass
    /// null to ignore imports.
    pub fn parse(self: *Stylesheet, text: []const u8, base_dir: ?[]const u8, io: ?std.Io, depth: u32) error{OutOfMemory}!void {
        const a = self.arena.allocator();
        const css = try stripComments(a, text);
        var i: usize = 0;
        while (i < css.len) {
            i = skipWhitespace(css, i);
            if (i >= css.len) break;
            if (css[i] == '@') {
                var j = i;
                while (j < css.len and css[j] != ';' and css[j] != '{') j += 1;
                const prelude = std.mem.trim(u8, css[i..j], &std.ascii.whitespace);
                if (j < css.len and css[j] == '{') {
                    i = skipBlock(css, j);
                    continue;
                }
                try self.atRule(prelude, base_dir, io, depth);
                i = j + 1;
                continue;
            }
            if (css[i] == '}') {
                i += 1;
                continue;
            }
            const open = std.mem.indexOfScalarPos(u8, css, i, '{') orelse break;
            const selectors = css[i..open];
            const close = blockEnd(css, open);
            const body = css[open + 1 .. close];
            try self.block(selectors, body);
            i = @min(close + 1, css.len);
        }
    }

    fn atRule(self: *Stylesheet, prelude: []const u8, base_dir: ?[]const u8, io: ?std.Io, depth: u32) error{OutOfMemory}!void {
        const a = self.arena.allocator();
        if (std.mem.startsWith(u8, prelude, "@define-color")) {
            const rest = std.mem.trim(u8, prelude["@define-color".len..], &std.ascii.whitespace);
            const space = std.mem.indexOfAny(u8, rest, &std.ascii.whitespace) orelse return;
            const name = rest[0..space];
            const value = std.mem.trim(u8, rest[space..], &std.ascii.whitespace);
            try self.colors.put(a, name, value);
        } else if (std.mem.startsWith(u8, prelude, "@import")) {
            const dir = base_dir orelse return;
            const io_ = io orelse return;
            if (depth >= max_import_depth) return;
            var target = std.mem.trim(u8, prelude["@import".len..], &std.ascii.whitespace);
            if (std.mem.startsWith(u8, target, "url(") and std.mem.endsWith(u8, target, ")")) {
                target = target[4 .. target.len - 1];
            }
            target = std.mem.trim(u8, target, " \t\"'");
            if (target.len == 0) return;
            const path = if (std.fs.path.isAbsolute(target)) target else try std.fs.path.join(a, &.{ dir, target });
            self.loadFile(io_, path, depth + 1) catch |err| {
                log.warn("cannot import {s}: {t}", .{ path, err });
            };
        }
    }

    fn block(self: *Stylesheet, selectors: []const u8, body: []const u8) error{OutOfMemory}!void {
        const a = self.arena.allocator();
        var decls = std.mem.splitScalar(u8, body, ';');
        while (decls.next()) |decl| {
            const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
            const property = std.mem.trim(u8, decl[0..colon], &std.ascii.whitespace);
            var value = std.mem.trim(u8, decl[colon + 1 ..], &std.ascii.whitespace);
            if (std.mem.endsWith(u8, value, "!important")) {
                value = std.mem.trimEnd(u8, value[0 .. value.len - "!important".len], &std.ascii.whitespace);
            }
            if (property.len == 0 or value.len == 0) continue;
            var sels = std.mem.splitScalar(u8, selectors, ',');
            while (sels.next()) |raw| {
                const selector = try normalizeSelector(a, raw);
                if (selector.len == 0) continue;
                try self.rules.append(a, .{ .selector = selector, .property = property, .value = value });
            }
        }
    }

    /// The raw value of the last declaration of any of `props` for the
    /// first of `selectors` that has one.
    pub fn get(self: *const Stylesheet, selectors: []const []const u8, props: []const []const u8) ?[]const u8 {
        for (selectors) |sel| {
            var found: ?[]const u8 = null;
            for (self.rules.items) |rule| {
                if (!std.mem.eql(u8, rule.selector, sel)) continue;
                for (props) |p| {
                    if (std.mem.eql(u8, rule.property, p)) found = rule.value;
                }
            }
            if (found) |v| return v;
        }
        return null;
    }

    pub fn getColor(self: *const Stylesheet, selectors: []const []const u8, props: []const []const u8) ?Color {
        for (selectors) |sel| {
            var found: ?Color = null;
            for (self.rules.items) |rule| {
                if (!std.mem.eql(u8, rule.selector, sel)) continue;
                for (props) |p| {
                    if (std.mem.eql(u8, rule.property, p)) {
                        if (self.colorIn(rule.value)) |c| found = c;
                    }
                }
            }
            if (found) |c| return c;
        }
        return null;
    }

    pub fn getFontFamily(self: *Stylesheet, selectors: []const []const u8) ?[]const u8 {
        const a = self.arena.allocator();
        if (self.get(selectors, &.{"font-family"})) |v| return cleanFamily(a, v) catch null;
        if (self.get(selectors, &.{"font"})) |v| {
            if (parseFontShorthand(v)) |f| return cleanFamily(a, f.family) catch null;
        }
        return null;
    }

    pub fn getFontSizePx(self: *const Stylesheet, selectors: []const []const u8) ?f64 {
        if (self.get(selectors, &.{"font-size"})) |v| {
            if (parseLengthPx(v)) |px| return px;
        }
        if (self.get(selectors, &.{"font"})) |v| {
            if (parseFontShorthand(v)) |f| return f.size_px;
        }
        return null;
    }

    /// Parses a colour value, resolving `@name` references and GTK functions.
    pub fn color(self: *const Stylesheet, value: []const u8) ?Color {
        return self.colorDepth(value, 0);
    }

    fn colorDepth(self: *const Stylesheet, raw: []const u8, depth: u32) ?Color {
        if (depth > 8) return null;
        const v = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (v.len == 0) return null;
        if (v[0] == '@') {
            var end: usize = 1;
            while (end < v.len and (std.ascii.isAlphanumeric(v[end]) or v[end] == '_' or v[end] == '-')) end += 1;
            const def = self.colors.get(v[1..end]) orelse return null;
            return self.colorDepth(def, depth + 1);
        }
        if (v[0] == '#') return parseHex(v[1..]);
        if (callArgs(v, "rgba")) |args| return parseRgb(args, true);
        if (callArgs(v, "rgb")) |args| return parseRgb(args, false);
        if (callArgs(v, "alpha")) |args| {
            var parts = splitArgs(args);
            const base = self.colorDepth(parts.next() orelse return null, depth + 1) orelse return null;
            const factor = parseNumber(parts.next() orelse return null) orelse return null;
            return base.withAlpha(std.math.clamp(base.a * factor, 0.0, 1.0));
        }
        if (callArgs(v, "shade")) |args| {
            var parts = splitArgs(args);
            const base = self.colorDepth(parts.next() orelse return null, depth + 1) orelse return null;
            const factor = parseNumber(parts.next() orelse return null) orelse return null;
            return .{
                .r = std.math.clamp(base.r * factor, 0.0, 1.0),
                .g = std.math.clamp(base.g * factor, 0.0, 1.0),
                .b = std.math.clamp(base.b * factor, 0.0, 1.0),
                .a = base.a,
            };
        }
        if (callArgs(v, "mix")) |args| {
            var parts = splitArgs(args);
            const first = self.colorDepth(parts.next() orelse return null, depth + 1) orelse return null;
            const second = self.colorDepth(parts.next() orelse return null, depth + 1) orelse return null;
            const amount = parseNumber(parts.next() orelse return null) orelse return null;
            return mix(first, second, std.math.clamp(amount, 0.0, 1.0));
        }
        return namedColor(v);
    }

    /// The first colour found inside a possibly compound value such as
    /// `2px solid rgba(...)` or `#123 url(x.png)`.
    fn colorIn(self: *const Stylesheet, value: []const u8) ?Color {
        var tokens = splitTopLevel(value, &std.ascii.whitespace);
        while (tokens.next()) |tok| {
            if (self.colorDepth(tok, 0)) |c| return c;
        }
        return null;
    }
};

// ---- CSS helpers ------------------------------------------------------------

fn stripComments(a: Allocator, text: []const u8) ![]u8 {
    const out = try a.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse text.len;
            out[n] = ' ';
            n += 1;
            i = @min(end + 2, text.len);
            continue;
        }
        out[n] = text[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

fn skipWhitespace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return i;
}

/// Index of the `}` matching the `{` at `open` (or the end of text).
fn blockEnd(text: []const u8, open: usize) usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        if (text[i] == '{') depth += 1;
        if (text[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return text.len;
}

fn skipBlock(text: []const u8, open: usize) usize {
    return @min(blockEnd(text, open) + 1, text.len);
}

/// Collapses whitespace runs to single spaces and trims.
fn normalizeSelector(a: Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, raw, &std.ascii.whitespace);
    while (tokens.next()) |tok| {
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, tok);
    }
    return out.items;
}

/// If `v` is `name(args)`, returns `args`.
fn callArgs(v: []const u8, name: []const u8) ?[]const u8 {
    if (v.len < name.len + 2) return null;
    if (!std.ascii.eqlIgnoreCase(v[0..name.len], name)) return null;
    if (v[name.len] != '(' or v[v.len - 1] != ')') return null;
    return v[name.len + 1 .. v.len - 1];
}

/// Splits on `delims` outside parentheses and quotes.
const TopLevelSplitter = struct {
    text: []const u8,
    delims: []const u8,
    pos: usize = 0,

    fn next(self: *TopLevelSplitter) ?[]const u8 {
        while (self.pos < self.text.len and std.mem.indexOfScalar(u8, self.delims, self.text[self.pos]) != null) self.pos += 1;
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        var depth: usize = 0;
        var quote: u8 = 0;
        while (self.pos < self.text.len) : (self.pos += 1) {
            const ch = self.text[self.pos];
            if (quote != 0) {
                if (ch == quote) quote = 0;
                continue;
            }
            if (ch == '"' or ch == '\'') {
                quote = ch;
                continue;
            }
            if (ch == '(') depth += 1;
            if (ch == ')' and depth > 0) depth -= 1;
            if (depth == 0 and std.mem.indexOfScalar(u8, self.delims, ch) != null) break;
        }
        return self.text[start..self.pos];
    }
};

fn splitTopLevel(text: []const u8, delims: []const u8) TopLevelSplitter {
    return .{ .text = text, .delims = delims };
}

fn splitArgs(text: []const u8) TopLevelSplitter {
    return .{ .text = text, .delims = "," };
}

fn hexDigit(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn parseHex(digits: []const u8) ?Color {
    var v: [8]u8 = undefined;
    if (digits.len != 3 and digits.len != 4 and digits.len != 6 and digits.len != 8) return null;
    for (digits, 0..) |ch, i| v[i] = hexDigit(ch) orelse return null;
    const short = digits.len <= 4;
    const r: f64 = if (short) @floatFromInt(v[0] * 17) else @floatFromInt(v[0] * 16 + v[1]);
    const g: f64 = if (short) @floatFromInt(v[1] * 17) else @floatFromInt(v[2] * 16 + v[3]);
    const b: f64 = if (short) @floatFromInt(v[2] * 17) else @floatFromInt(v[4] * 16 + v[5]);
    var a: f64 = 255;
    if (digits.len == 4) a = @floatFromInt(v[3] * 17);
    if (digits.len == 8) a = @floatFromInt(v[6] * 16 + v[7]);
    return .{ .r = r / 255.0, .g = g / 255.0, .b = b / 255.0, .a = a / 255.0 };
}

fn parseNumber(raw: []const u8) ?f64 {
    const v = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (v.len == 0) return null;
    if (v[v.len - 1] == '%') {
        const pct = std.fmt.parseFloat(f64, v[0 .. v.len - 1]) catch return null;
        return pct / 100.0;
    }
    return std.fmt.parseFloat(f64, v) catch null;
}

/// A colour channel: `0..255` or `0%..100%`.
fn parseChannel(raw: []const u8) ?f64 {
    const v = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (v.len == 0) return null;
    if (v[v.len - 1] == '%') {
        const pct = std.fmt.parseFloat(f64, v[0 .. v.len - 1]) catch return null;
        return std.math.clamp(pct / 100.0, 0.0, 1.0);
    }
    const n = std.fmt.parseFloat(f64, v) catch return null;
    return std.math.clamp(n / 255.0, 0.0, 1.0);
}

fn parseRgb(args: []const u8, with_alpha: bool) ?Color {
    // Accept both `r, g, b, a` and the space-separated `r g b / a` form.
    var parts: [4]?[]const u8 = .{ null, null, null, null };
    var n: usize = 0;
    var it = splitTopLevel(args, ", /");
    while (it.next()) |p| : (n += 1) {
        if (n >= 4) return null;
        parts[n] = p;
    }
    if (n < 3) return null;
    const r = parseChannel(parts[0].?) orelse return null;
    const g = parseChannel(parts[1].?) orelse return null;
    const b = parseChannel(parts[2].?) orelse return null;
    var a: f64 = 1.0;
    if (n == 4) {
        a = std.math.clamp(parseNumber(parts[3].?) orelse return null, 0.0, 1.0);
    } else if (with_alpha) {
        a = 1.0;
    }
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn namedColor(v: []const u8) ?Color {
    const names = [_]struct { name: []const u8, hex: u24, alpha: f64 = 1.0 }{
        .{ .name = "transparent", .hex = 0x000000, .alpha = 0.0 },
        .{ .name = "black", .hex = 0x000000 },
        .{ .name = "white", .hex = 0xffffff },
        .{ .name = "red", .hex = 0xff0000 },
        .{ .name = "green", .hex = 0x008000 },
        .{ .name = "lime", .hex = 0x00ff00 },
        .{ .name = "blue", .hex = 0x0000ff },
        .{ .name = "yellow", .hex = 0xffff00 },
        .{ .name = "orange", .hex = 0xffa500 },
        .{ .name = "cyan", .hex = 0x00ffff },
        .{ .name = "aqua", .hex = 0x00ffff },
        .{ .name = "magenta", .hex = 0xff00ff },
        .{ .name = "fuchsia", .hex = 0xff00ff },
        .{ .name = "purple", .hex = 0x800080 },
        .{ .name = "pink", .hex = 0xffc0cb },
        .{ .name = "gray", .hex = 0x808080 },
        .{ .name = "grey", .hex = 0x808080 },
        .{ .name = "silver", .hex = 0xc0c0c0 },
        .{ .name = "navy", .hex = 0x000080 },
        .{ .name = "teal", .hex = 0x008080 },
        .{ .name = "maroon", .hex = 0x800000 },
        .{ .name = "olive", .hex = 0x808000 },
        .{ .name = "brown", .hex = 0xa52a2a },
        .{ .name = "gold", .hex = 0xffd700 },
        .{ .name = "coral", .hex = 0xff7f50 },
        .{ .name = "tomato", .hex = 0xff6347 },
        .{ .name = "crimson", .hex = 0xdc143c },
        .{ .name = "salmon", .hex = 0xfa8072 },
        .{ .name = "orchid", .hex = 0xda70d6 },
        .{ .name = "violet", .hex = 0xee82ee },
        .{ .name = "indigo", .hex = 0x4b0082 },
        .{ .name = "turquoise", .hex = 0x40e0d0 },
        .{ .name = "skyblue", .hex = 0x87ceeb },
        .{ .name = "steelblue", .hex = 0x4682b4 },
        .{ .name = "dodgerblue", .hex = 0x1e90ff },
        .{ .name = "slategray", .hex = 0x708090 },
        .{ .name = "slategrey", .hex = 0x708090 },
        .{ .name = "darkgray", .hex = 0xa9a9a9 },
        .{ .name = "darkgrey", .hex = 0xa9a9a9 },
        .{ .name = "lightgray", .hex = 0xd3d3d3 },
        .{ .name = "lightgrey", .hex = 0xd3d3d3 },
        .{ .name = "dimgray", .hex = 0x696969 },
        .{ .name = "dimgrey", .hex = 0x696969 },
        .{ .name = "whitesmoke", .hex = 0xf5f5f5 },
        .{ .name = "ivory", .hex = 0xfffff0 },
        .{ .name = "beige", .hex = 0xf5f5dc },
        .{ .name = "khaki", .hex = 0xf0e68c },
        .{ .name = "tan", .hex = 0xd2b48c },
        .{ .name = "wheat", .hex = 0xf5deb3 },
    };
    for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(v, entry.name)) return Color.rgb(entry.hex).withAlpha(entry.alpha);
    }
    return null;
}

/// `12px`, `9pt`, `1.2em`, `110%` or a bare number, as CSS pixels.
fn parseLengthPx(raw: []const u8) ?f64 {
    const v = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (v.len == 0) return null;
    var end: usize = 0;
    while (end < v.len and (std.ascii.isDigit(v[end]) or v[end] == '.')) end += 1;
    if (end == 0) return null;
    const n = std.fmt.parseFloat(f64, v[0..end]) catch return null;
    const unit = v[end..];
    if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "px")) return n;
    if (std.ascii.eqlIgnoreCase(unit, "pt")) return n * 96.0 / 72.0;
    if (std.ascii.eqlIgnoreCase(unit, "em") or std.ascii.eqlIgnoreCase(unit, "rem")) return n * 16.0;
    if (std.mem.eql(u8, unit, "%")) return n * 16.0 / 100.0;
    return null;
}

/// Turns a CSS family list such as `"Noto Sans", sans-serif` into the
/// `Noto Sans,sans-serif` form Pango expects.
fn cleanFamily(a: Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var families = std.mem.splitScalar(u8, v, ',');
    while (families.next()) |raw| {
        var name: std.ArrayList(u8) = .empty;
        for (std.mem.trim(u8, raw, &std.ascii.whitespace)) |ch| {
            if (ch != '"' and ch != '\'') try name.append(a, ch);
        }
        const trimmed = std.mem.trim(u8, name.items, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (out.items.len > 0) try out.append(a, ',');
        try out.appendSlice(a, trimmed);
    }
    return out.items;
}

const FontShorthand = struct { family: []const u8, size_px: f64 };

/// `font: [style] [weight] size[/line-height] family`.
fn parseFontShorthand(v: []const u8) ?FontShorthand {
    var tokens = splitTopLevel(v, &std.ascii.whitespace);
    while (tokens.next()) |tok| {
        const size_part = if (std.mem.indexOfScalar(u8, tok, '/')) |slash| tok[0..slash] else tok;
        if (!std.ascii.isDigit(size_part[0])) continue;
        const size = parseLengthPx(size_part) orelse continue;
        const after = v[@intFromPtr(tok.ptr) - @intFromPtr(v.ptr) + tok.len ..];
        const family = std.mem.trim(u8, after, &std.ascii.whitespace);
        if (family.len == 0) return null;
        return .{ .family = family, .size_px = size };
    }
    return null;
}

// ---- tests ------------------------------------------------------------------

const sample_css =
    \\/* a comment { with braces } */
    \\@define-color base rgba(0, 43, 54, 0.8);
    \\@define-color fg #eee8d5;
    \\@define-color accent alpha(@fg, 0.5);
    \\* {
    \\  border: none;
    \\  font-family: "Noto Sans", sans-serif;
    \\  font-size: 12px;
    \\}
    \\window#waybar {
    \\  background: @base;
    \\  color: rgba(238, 232, 213, 1);
    \\}
    \\#workspaces button.focused {
    \\  background-color: rgba(7, 54, 66, 0.8);
    \\  border-bottom: 2px solid rgba(238, 232, 213, 1);
    \\}
    \\#mode, #clock {
    \\  padding: 3px;
    \\}
    \\#mode {
    \\  background: rgba(181, 137, 0, 0.8) !important;
    \\}
    \\@keyframes blink {
    \\  to { background-color: #ffffff; color: black; }
    \\}
    \\#battery.critical:not(.charging) { color: #f53c3c; }
;

fn expectColor(expected: Color, actual: ?Color) !void {
    const c = actual orelse return error.TestExpectedColor;
    try std.testing.expectApproxEqAbs(expected.r, c.r, 0.002);
    try std.testing.expectApproxEqAbs(expected.g, c.g, 0.002);
    try std.testing.expectApproxEqAbs(expected.b, c.b, 0.002);
    try std.testing.expectApproxEqAbs(expected.a, c.a, 0.002);
}

test "stylesheet rules and define-color" {
    var sheet = Stylesheet.init(std.testing.allocator);
    defer sheet.deinit();
    try sheet.parse(sample_css, null, null, 0);

    const bar = [_][]const u8{ "window#waybar", "*" };
    try expectColor(.{ .r = 0, .g = 43.0 / 255.0, .b = 54.0 / 255.0, .a = 0.8 }, sheet.getColor(&bar, &.{ "background-color", "background" }));
    try expectColor(.{ .r = 238.0 / 255.0, .g = 232.0 / 255.0, .b = 213.0 / 255.0, .a = 1 }, sheet.getColor(&bar, &.{"color"}));
    try expectColor(Color.rgb(0xeee8d5).withAlpha(0.5), sheet.color("@accent"));
    try expectColor(Color.rgb(0xb58900).withAlpha(0.8), sheet.getColor(&.{"#mode"}, &.{"background"}));
    // Colour inside a border shorthand; grouped selector split; @keyframes skipped.
    try expectColor(Color.rgb(0xeee8d5), sheet.getColor(&.{"#workspaces button.focused"}, &.{"border-bottom"}));
    try std.testing.expect(sheet.get(&.{"#clock"}, &.{"padding"}) != null);
    try std.testing.expect(sheet.get(&.{"to"}, &.{"color"}) == null);
    try expectColor(Color.rgb(0xf53c3c), sheet.getColor(&.{"#battery.critical:not(.charging)"}, &.{"color"}));

    try std.testing.expectEqualStrings("Noto Sans,sans-serif", sheet.getFontFamily(&bar).?);
    try std.testing.expectEqual(@as(f64, 12), sheet.getFontSizePx(&bar).?);
}

test "theme derived from the sample" {
    var sheet = Stylesheet.init(std.testing.allocator);
    defer sheet.deinit();
    try sheet.parse(sample_css, null, null, 0);
    var t = try Theme.fromStylesheet(std.testing.allocator, &sheet);
    defer t.deinit(std.testing.allocator);
    // Background keeps the bar colour but is made mostly opaque.
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), t.bg.a, 0.001);
    // The focused-workspace background is too close to the bar, so the
    // accent comes from #mode.
    try std.testing.expectApproxEqAbs(@as(f64, 181.0 / 255.0 * 0.8 + 0.0 * 0.2), t.accent.r, 0.01);
    try expectColor(Color.rgb(0xf53c3c), t.danger);
    try std.testing.expectEqualStrings("Noto Sans,sans-serif Bold 14px", t.font_title);
}

test "colour syntaxes" {
    var sheet = Stylesheet.init(std.testing.allocator);
    defer sheet.deinit();
    try expectColor(Color.rgb(0x112233), sheet.color("#123"));
    try expectColor(Color.rgb(0x112233).withAlpha(68.0 / 255.0), sheet.color("#11223344"));
    try expectColor(Color.rgb(0xff0000).withAlpha(0.5), sheet.color("rgb(100%, 0%, 0% / 50%)"));
    try expectColor(Color.rgb(0x808080), sheet.color("Gray"));
    try expectColor(.{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 }, sheet.color("mix(black, white, 0.5)"));
    try expectColor(.{ .r = 0.5, .g = 0, .b = 0, .a = 1 }, sheet.color("shade(red, 0.5)"));
    try std.testing.expect(sheet.color("url(x.png)") == null);
    try std.testing.expectEqual(@as(f64, 16), parseLengthPx("12pt").?);
    const f = parseFontShorthand("italic bold 13px/1.2 'JetBrains Mono', monospace").?;
    try std.testing.expectEqual(@as(f64, 13), f.size_px);
    try std.testing.expectEqualStrings("'JetBrains Mono', monospace", f.family);
}
