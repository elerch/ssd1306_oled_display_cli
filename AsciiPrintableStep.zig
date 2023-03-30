//! Publish Date: 2021_10_17
//! This file is hosted at github.com/marler8997/zig-build-repos and is meant to be copied
//! to projects that use it.
const std = @import("std");
const AsciiPrintableStep = @This();

step: std.build.Step,
builder: *std.build.Builder,
path: []const u8,

pub fn create(b: *std.build.Builder, opt: struct {
    path: []const u8,
}) *AsciiPrintableStep {
    var result = b.allocator.create(AsciiPrintableStep) catch @panic("OOM");
    result.* = AsciiPrintableStep{
        .step = std.build.Step.init(.{
            .id = .custom,
            .name = "AsciiPrintable",
            .owner = b,
            .makeFn = make,
        }),
        .builder = b,
        .path = std.fs.path.resolve(b.allocator, &[_][]const u8{
            b.build_root.path.?, opt.path,
        }) catch @panic("memory"),
    };
    return result;
}

// TODO: this should be included in std.build, it helps find bugs in build files
fn hasDependency(step: *const std.build.Step, dep_candidate: *const std.build.Step) bool {
    for (step.dependencies.items) |dep| {
        // TODO: should probably use step.loop_flag to prevent infinite recursion
        //       when a circular reference is encountered, or maybe keep track of
        //       the steps encounterd with a hash set
        if (dep == dep_candidate or hasDependency(dep, dep_candidate))
            return true;
    }
    return false;
}

fn make(step: *std.build.Step, _: *std.Progress.Node) !void {
    const self = @fieldParentPtr(AsciiPrintableStep, "step", step);

    const zig_file = std.fmt.allocPrint(self.builder.allocator, "{s}/images.zig", .{self.path}) catch @panic("OOM");
    defer self.builder.allocator.free(zig_file);
    std.fs.accessAbsolute(zig_file, .{ .mode = .read_only }) catch {
        // Printables file does not exist
        // ASCII printables from 32 to 126
        const file = try std.fs.createFileAbsolute(zig_file, .{
            .read = false,
            .truncate = true,
            .lock = .Exclusive,
            .lock_nonblocking = false,
            .mode = 0o666,
            .intended_io_mode = .blocking,
        });
        defer file.close();
        const writer = file.writer();
        try writer.print("pub const chars = &[_][]const u8{{\n", .{});

        for (0..32) |_| {
            try writer.print("  \"\",\n", .{});
        }
        for (32..127) |i| {
            // if (i == 32) {
            //     try writer.print("  \"\",\n", .{});
            //     continue;
            // }
            const char_str = [_]u8{@intCast(u8, i)};
            // Need to escape the following chars: 32 (' ') 92 ('\')
            const label_param = parm: {
                switch (i) {
                    32 => break :parm "label:\\ ",
                    92 => break :parm "label:\\\\",
                    else => break :parm "label:" ++ char_str,
                }
            };

            const dest_file = std.fmt.allocPrint(self.builder.allocator, "{s}/{d}.bmp", .{ self.path, i }) catch @panic("OOM");
            defer self.builder.allocator.free(dest_file);

            // generate the file
            // magick -background transparent -fill black -font Hack-Regular -density 72 -pointsize 8 label:42 test.bmp
            try run(self.builder, &[_][]const u8{
                "magick",
                "-background",
                "white",
                "-fill",
                "black",
                "-font",
                "Hack-Regular",
                "-density",
                "72",
                "-pointsize",
                "8",
                label_param,
                "-extent",
                "5x8",
                dest_file,
            });
            // 36 ($) and 81 (Q) are widest and only 9 wide
            // Can chop right pixel I think
            // try writer.print("{s}\n", .{[_]u8{@intCast(u8, i)}});
            // add the embed
            try writer.print("  @embedFile(\"{d}.bmp\"),\n", .{i});
        }
        try writer.print("}};\n", .{});
        // if (!self.fetch_enabled) {
        //     step.addError("       Use -Dfetch to download it automatically, or run the following to clone it:", .{});
        //     std.os.exit(1);
        // }
    };
}

fn run(builder: *std.build.Builder, argv: []const []const u8) !void {
    // {
    //     var msg = std.ArrayList(u8).init(builder.allocator);
    //     defer msg.deinit();
    //     const writer = msg.writer();
    //     var prefix: []const u8 = "";
    //     for (argv) |arg| {
    //         try writer.print("{s}\"{s}\"", .{ prefix, arg });
    //         prefix = " ";
    //     }
    //     std.log.debug("[RUN] {s}", .{msg.items});
    // }

    var child = std.ChildProcess.init(argv, builder.allocator);

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.cwd = builder.build_root.path;
    child.env_map = builder.env_map;

    try child.spawn();
    const result = try child.wait();
    switch (result) {
        .Exited => |code| if (code != 0) {
            std.log.err("command failed with exit code {}", .{code});
            {
                var msg = std.ArrayList(u8).init(builder.allocator);
                defer msg.deinit();
                const writer = msg.writer();
                var prefix: []const u8 = "";
                for (argv) |arg| {
                    try writer.print("{s}\"{s}\"", .{ prefix, arg });
                    prefix = " ";
                }
                std.log.debug("[RUN] {s}", .{msg.items});
            }
            std.os.exit(0xff);
        },
        else => {
            std.log.err("command failed with: {}", .{result});
            std.os.exit(0xff);
        },
    }
}

// Get's the repository path and also verifies that the step requesting the path
// is dependent on this step.
pub fn getPath(self: anytype, who_wants_to_know: *const std.build.Step) []const u8 {
    if (!hasDependency(who_wants_to_know, &self.step))
        @panic("a step called AsciiPrintableStep.getPath but has not added it as a dependency");
    return self.path;
}
