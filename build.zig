const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    });
    const vt = ghostty.module("ghostty-vt");
    const version = @import("build.zig.zon").version;

    const exe_opts = b.addOptions();
    exe_opts.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "den",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ghostty-vt", .module = vt },
                .{ .name = "build_options", .module = exe_opts.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    // Tests get the built binary's path so the end-to-end test can drive it.
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    opts.addOptionPath("den_bin", exe.getEmittedBin());
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ghostty-vt", .module = vt },
            .{ .name = "build_options", .module = opts.createModule() },
        },
    }) });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}
