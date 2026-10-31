// Copyright (C) 2026 by Harry Pidcock
// Licensed under 0BSD, see LICENCE file for details.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Wayland protocols that are not part of libwayland-client itself. Each
    // one is turned into a C header (for translate-c) and a C source file
    // (interface tables) by wayland-scanner at build time.
    const protocols = [_][]const u8{ "xdg-shell", "viewporter", "wlr-layer-shell-unstable-v1" };
    const system_libs = [_][]const u8{
        "wayland-client",
        "wayland-cursor",
        "xkbcommon",
        "cairo",
        "pangocairo",
        "dbus-1",
    };

    // All C headers are translated once from src/c.h and exposed as the "c" module.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    for (system_libs) |lib| translate_c.linkSystemLibrary(lib, .{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (system_libs) |lib| exe_mod.linkSystemLibrary(lib, .{});

    for (protocols) |name| {
        const xml = b.path(b.fmt("protocols/{s}.xml", .{name}));

        const gen_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        gen_header.addFileArg(xml);
        const header = gen_header.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{name}));

        const gen_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        gen_code.addFileArg(xml);
        const code = gen_code.addOutputFileArg(b.fmt("{s}-protocol.c", .{name}));

        translate_c.addIncludePath(header.dirname());
        exe_mod.addIncludePath(header.dirname());
        exe_mod.addCSourceFile(.{ .file = code, .flags = &.{} });
    }

    exe_mod.addImport("c", translate_c.createModule());

    const exe = b.addExecutable(.{
        .name = "wayman",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run wayman");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
