const std = @import("std");

// The package manager will install headers from our dependency in zig's build
// cache and include the cache directory as a "-I" option on the build command
// automatically.
const c = @cImport({
    @cInclude("MagickWand/MagickWand.h");
});

// This is set in two places. If this needs adjustment be sure to change the
// magick CLI command (where it is a string)
const GLYPH_WIDTH = 5;
const GLYPH_HEIGHT = 8;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    //
    // var env = try std.process.getEnvMap(alloc);
    // defer env.deinit();
    // var env_iterator = env.iterator();
    // std.debug.print("\n", .{});
    // while (env_iterator.next()) |entry| {
    //     std.debug.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    // }
    // cwd is the root of the project - yay!
    const proj_path = std.fs.cwd(); //.realpath(".", &path_buf);

    // We will assume we own the src/fonts dir in entirety
    proj_path.makeDir("src/fonts/") catch {};

    if (!std.meta.isError(proj_path.statFile("src/fonts/fonts.zig"))) return;

    const generated_file = try proj_path.createFile("src/fonts/fonts.zig", .{
        .read = false,
        .truncate = true,
        .lock = .Exclusive,
        .lock_nonblocking = false,
        .mode = 0o666,
        .intended_io_mode = .blocking,
    });
    defer generated_file.close();

    // We need a temp file for the glyph bmp
    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

    const temp_file = try std.fs.path.joinZ(alloc, &[_][]const u8{ try proj_path.realpath("src/fonts/", &path_buf), ".tmp.bmp" });
    defer alloc.free(temp_file);
    defer std.fs.deleteFileAbsolute(temp_file) catch {};

    const file_writer = generated_file.writer();
    var buffered_writer = std.io.bufferedWriter(file_writer);
    defer buffered_writer.flush() catch unreachable;
    const writer = buffered_writer.writer();
    // std.debug.print("cwd: {s}", .{try std.fs.cwd().realpath(".", &path_buf)});

    // const args = try std.process.argsAlloc(alloc);
    // defer std.process.argsFree(alloc, args);
    //
    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();
    // defer bw.flush() catch unreachable; // don't forget to flush!
    //
    // // try stdout.print("Run `zig build test` to run the tests.\n", .{});
    var pixels: [GLYPH_WIDTH * GLYPH_HEIGHT]u8 = undefined;
    try writer.print("pub const @\"{s}\" = .{{\n", .{"Hack-Regular"});
    // TODO: Read and cache
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

        // generate the file
        // 36 ($) and 81 (Q) are widest and only 9 wide
        // We are chopping the right pixel
        try run(alloc, &[_][]const u8{
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
            temp_file,
        });

        // Grab pixels from the file
        try convertImage(temp_file, &pixels);

        packBits(&pixels);
        // unpackBits(&pixels);

        try writer.print("  .@\"{d}\" = &[_]u8{{ ", .{i});
        var first = true;
        for (pixels[0..(GLYPH_WIDTH * GLYPH_HEIGHT / 8)]) |byte| {
            // for (pixels) |byte| { // unpacked only
            if (!first) try writer.print(", ", .{});
            try writer.print("0x{s}", .{std.fmt.bytesToHex(&[_]u8{byte}, .lower)});
            first = false;
        }
        try writer.print(" }},\n", .{});
    }
    try writer.print("}};\n", .{});
}
const hi = .{
    .there = &[_]u8{0xff},
};

fn run(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var child = std.ChildProcess.init(argv, allocator);

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.cwd = null; //std.fs.cwd();
    child.env_map = &env_map;

    try child.spawn();
    const result = try child.wait();
    switch (result) {
        .Exited => |code| if (code != 0) {
            std.log.err("command failed with exit code {}", .{code});
            {
                var msg = std.ArrayList(u8).init(allocator);
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
pub fn unpackBits(pixels: *[GLYPH_WIDTH * GLYPH_HEIGHT]u8) void {
    // bits packed: 0000 0001
    //                      ^
    //                      \- most significant bit

    // Need to start at the end and work forward to avoid
    // overwrites
    var i: isize = (GLYPH_WIDTH * GLYPH_HEIGHT / 8 - 1);
    while (i >= 0) {
        const start = @intCast(usize, i) * 8;
        const packed_byte = pixels[@intCast(usize, i)];
        pixels[start + 7] = ((packed_byte & 0b10000000) >> 7) * 0xFF;
        pixels[start + 6] = ((packed_byte & 0b01000000) >> 6) * 0xFF;
        pixels[start + 5] = ((packed_byte & 0b00100000) >> 5) * 0xFF;
        pixels[start + 4] = ((packed_byte & 0b00010000) >> 4) * 0xFF;
        pixels[start + 3] = ((packed_byte & 0b00001000) >> 3) * 0xFF;
        pixels[start + 2] = ((packed_byte & 0b00000100) >> 2) * 0xFF;
        pixels[start + 1] = ((packed_byte & 0b00000010) >> 1) * 0xFF;
        pixels[start + 0] = ((packed_byte & 0b00000001) >> 0) * 0xFF;
        i -= 1;
    }
}

fn packBits(pixels: *[GLYPH_WIDTH * GLYPH_HEIGHT]u8) void {
    for (0..(GLYPH_WIDTH * GLYPH_HEIGHT / 8)) |i| {
        const start = i * 8;
        pixels[i] = (pixels[start] & 0b00000001) |
            (pixels[(start + 1)] & 0b00000010) |
            (pixels[(start + 2)] & 0b00000100) |
            (pixels[(start + 3)] & 0b00001000) |
            (pixels[(start + 4)] & 0b00010000) |
            (pixels[(start + 5)] & 0b00100000) |
            (pixels[(start + 6)] & 0b01000000) |
            (pixels[(start + 7)] & 0b10000000);
    }
}

fn convertImage(filename: [:0]u8, pixels: *[GLYPH_WIDTH * GLYPH_HEIGHT]u8) !void {
    c.MagickWandGenesis();
    defer c.MagickWandTerminus();
    var mw = c.NewMagickWand();
    defer {
        if (mw) |w| mw = c.DestroyMagickWand(w);
    }

    // Reading an image into ImageMagick is problematic if it isn't a bmp
    // as the library needs a bunch of dependencies available
    var status = c.MagickReadImage(mw, filename);
    if (status == c.MagickFalse) {
        // try reportMagickError(mw);
        return error.CouldNotReadImage;
    }

    // We make the image monochrome by quantizing the image with 2 colors in the
    // gray colorspace. See:
    // https://www.imagemagick.org/Usage/quantize/#monochrome
    // and
    // https://stackoverflow.com/questions/18267432/using-the-c-api-for-imagemagick-on-iphone-to-convert-to-monochrome
    //
    // We do this at the end so we have pure black and white. Otherwise the
    // resizing oprations will generate some greyscale that we don't want
    status = c.MagickQuantizeImage(mw, // MagickWand
        2, // Target number colors
        c.GRAYColorspace, // Colorspace
        1, // Optimal depth
        c.MagickTrue, // Dither
        c.MagickFalse // Quantization error
    );

    if (status == c.MagickFalse)
        return error.CouldNotQuantizeImage;

    status = c.MagickExportImagePixels(mw, 0, 0, GLYPH_WIDTH, GLYPH_HEIGHT, "I", c.CharPixel, @ptrCast(*anyopaque, pixels));

    if (status == c.MagickFalse)
        return error.CouldNotExportImage;

    for (0..GLYPH_WIDTH * GLYPH_HEIGHT) |i| {
        switch (pixels[i]) {
            0x00 => pixels[i] = 0xFF,
            0xFF => pixels[i] = 0x00,
            else => {},
        }
    }
}
