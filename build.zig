const std = @import("std");
const AsciiPrintableStep = @import("AsciiPrintableStep.zig");

pub fn build(b: *std.build.Builder) !void {
    // comptime {
    //     const current_zig = builtin.zig_version;
    //     const min_zig = std.SemanticVersion.parse("0.11.0-dev.1254+1f8f79cd5") catch return; // add helper functions to std.zig.Ast
    //     if (current_zig.order(min_zig) == .lt) {
    //         @compileError(std.fmt.comptimePrint("Your Zig version v{} does not meet the minimum build requirement of v{}", .{ current_zig, min_zig }));
    //     }
    // }
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Dependency based on the package manager MVP:
    // https://github.com/ziglang/zig/pull/14265
    // This is highly subject to change, and without tooling at the moment
    const im_dep = b.dependency("ImageMagick", .{});
    const z_dep = b.dependency("libz", .{});

    const i2cdriver = b.addStaticLibrary(.{
        .name = "i2cdriver",
        .target = target,
        .optimize = optimize,
    });
    i2cdriver.addCSourceFile("lib/i2cdriver/i2cdriver.c", &[_][]const u8{ "-Wall", "-Wpointer-sign", "-Werror" });
    i2cdriver.linkLibC();

    const exe = b.addExecutable(.{
        .name = "i2c",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(im_dep.artifact("MagickWand"));
    exe.linkLibrary(z_dep.artifact("z"));
    exe.linkLibrary(i2cdriver);
    exe.addIncludePath("lib/i2cdriver");
    exe.install();

    const exe_fontgen = b.addExecutable(.{
        .name = "fontgen",
        .root_source_file = .{ .path = "src/fontgen.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe_fontgen.linkLibrary(im_dep.artifact("MagickWand"));
    exe_fontgen.linkLibrary(z_dep.artifact("z"));
    exe.step.dependOn(&exe_fontgen.run().step);

    // TODO: I believe we can use runArtifact on a second
    // exe with a different source file for font generation
    // taking us to a series of 5 byte arrays for each
    // character in a font.
    exe.step.dependOn(&AsciiPrintableStep.create(b, .{ .path = "src/images" }).step);
    // exe.step.dependOn((try fontGeneration(b, target)));
    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe_tests.linkLibrary(im_dep.artifact("MagickWand"));
    exe_tests.linkLibrary(z_dep.artifact("z"));
    exe_tests.linkLibrary(i2cdriver);
    exe_tests.addIncludePath("lib/i2cdriver");

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.run().step);
}

// Should be able to remove this
fn fontGeneration(b: *std.build.Builder, target: anytype) !*std.build.Step {
    if (target.getOs().tag != .linux) return error.UnsupportedBuildOS;
    const fontgen = b.step("gen", "Generate font image files");
    fontgen.dependOn(&b.addSystemCommand(&.{ "/bin/sh", "-c", "./fontgen" }).step);

    // This can probably be triggered instead by GitRepoStep cloning the repo
    // exe.step.dependOn(cg);
    return fontgen;
}
