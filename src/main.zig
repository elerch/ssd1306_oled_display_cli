const std = @import("std");
const chars = @import("images/images.zig").chars;

// The package manager will install headers from our dependency in zig's build
// cache and include the cache directory as a "-I" option on the build command
// automatically.
const c = @cImport({
    @cInclude("MagickWand/MagickWand.h");
    @cInclude("i2cdriver.h");
});

// Image specifications
const WIDTH = 128;
const HEIGHT = 64;

// Text specifications
const FONT_WIDTH = 5;
const FONT_HEIGHT = 8;

const CHARS_PER_LINE = 25; // 25 * 5 = 125 so we have 3px left over
const BORDER_LEFT = 1; // 1 empty px left, 2 empty on right
const LINES = 8;

// Device specifications
const PAGES = 8;

var lines: [LINES]*const [:0]u8 = undefined;

fn usage(args: [][]u8) !void {
    const writer = std.io.getStdErr().writer();
    try writer.print("usage: {s} <device> [-bg <image file>] [-<num> text]...\n", .{args[0]});
    try writer.print("\t-<num> text: line number and text to display\n", .{});
    try writer.print("\te.g. \"-1 'hello world'\" will display \"hello world\" on line 1\n", .{});
    std.os.exit(1);
}
const Options = struct {
    background_filename: [:0]u8,
    device_file: [:0]u8,
};
pub fn main() !void {
    const alloc = std.heap.c_allocator;
    //defer alloc.deinit();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    defer bw.flush() catch unreachable; // don't forget to flush!

    // If we have stdin redirected, we want to process that before
    // we take command line options. So cli will overwrite any lines specified
    // from the file
    const stdin_file = std.io.getStdIn();
    var stdin_data: [WIDTH * HEIGHT + 1]u8 = undefined;
    var line_inx: usize = 0;
    defer {
        for (0..line_inx) |i| {
            alloc.free(@constCast(lines[i].*));
        }
    }
    if (!stdin_file.isTty()) {
        const read = try stdin_file.readAll(&stdin_data);
        if (read == stdin_data.len) {
            try std.io.getStdErr().writer().print("ERROR: data provided exceeds what can be sent to device!\n", .{});
            try usage(args);
        }
        var it = std.mem.split(u8, &stdin_data, "\n");
        while (it.next()) |line| {
            const bwahahaha = try alloc.dupeZ(u8, line);
            lines[line_inx] = &bwahahaha;
            line_inx += 1;
        }
    }
    const opts = try processArgs(alloc, args, &lines);
    defer alloc.destroy(opts);
    if (opts.background_filename.len > 0) try stdout.print("Converting {s}\n", .{opts.background_filename});
    var pixels: [WIDTH * HEIGHT]u8 = undefined;
    try convertImage(opts.background_filename, &pixels, textForLine);
    try bw.flush();

    // We should take the linux device file here, then inspect for ttyUSB vs
    // i2c whatever and do the right thing from there...
    try sendPixels(&pixels, opts.device_file, 0x3c);

    // try stdout.print("Run `zig build test` to run the tests.\n", .{});
}

fn processArgs(allocator: std.mem.Allocator, args: [][:0]u8, line_array: *[LINES]*const [:0]u8) !*Options {
    if (args.len < 2) try usage(args);
    const prefix = "/dev/ttyUSB";
    var opts = try allocator.create(Options);
    opts.device_file = args[1];
    if (!std.mem.eql(u8, opts.device_file, "-") and !std.mem.startsWith(u8, opts.device_file, prefix)) try usage(args);

    opts.background_filename = @constCast("");
    const nothing: [:0]u8 = @constCast("");
    for (line_array.*, 0..) |_, i| {
        line_array.*[i] = &nothing;
    }
    var is_filename = false;
    var line_number: ?usize = null;
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, "-bg", arg)) {
            is_filename = true;
            continue;
        }
        if (is_filename) {
            opts.background_filename = args[i]; // arg capture changes value...
            break;
        }
        if ((arg[0] == '-' and arg.len > 1) and areDigits(arg[1..])) {
            line_number = try std.fmt.parseInt(usize, arg[1..], 10);
            continue;
        }
        if (line_number) |line| {
            if (arg.len > CHARS_PER_LINE) {
                try std.io.getStdErr().writer().print(
                    "ERROR: text for line {d} has {d} chars, exceeding maximum length {d}\n",
                    .{ line, arg.len, CHARS_PER_LINE },
                );
                std.os.exit(1);
            }
            std.log.debug("line {d} text: \"{s}\"\n", .{ line, arg });
            line_array.*[line] = &args[i];
            line_number = null;
            continue;
        }
    }
    return opts;
}

fn areDigits(bytes: []u8) bool {
    for (bytes) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn sendPixels(pixels: []const u8, file: [:0]const u8, device_id: u8) !void {
    if (std.mem.eql(u8, file, "-"))
        return sendPixelsToStdOut(pixels);

    if (@import("builtin").os.tag != .linux)
        @compileError("Linux only please!");

    const is_i2cdriver = std.mem.startsWith(u8, file, "/dev/ttyUSB");
    if (is_i2cdriver)
        return sendPixelsThroughI2CDriver(pixels, file, device_id);

    // Send through linux i2c native
    return error.LinuxNativeNotImplemented;
}

fn sendPixelsToStdOut(pixels: []const u8) !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    defer bw.flush() catch unreachable; // don't forget to flush!
    for (0..HEIGHT) |i| {
        try stdout.print("{d:0>2}: {s}\n", .{ i, fmtSliceGreyscaleImage(pixels[(i * WIDTH)..((i + 1) * WIDTH)]) });
    }
}

fn sendPixelsThroughI2CDriver(pixels: []const u8, file: [*:0]const u8, device_id: u8) !void {
    var pixels_write_command = [_]u8{0x00} ** ((WIDTH * PAGES) + 1);
    pixels_write_command[0] = 0x40;
    packPixelsToDeviceFormat(pixels, pixels_write_command[1..]);
    var i2c = c.I2CDriver{
        .connected = 0,
        .port = 0,
        .model = [_]u8{0} ** 16,
        .serial = [_]u8{0} ** 9,
        .uptime = 0.0,
        .voltage_v = 0.0,
        .current_ma = 0.0,
        .temp_celsius = 0.0,
        .mode = 0,
        .sda = 0,
        .scl = 0,
        .speed = 0,
        .pullups = 0,
        .ccitt_crc = 0,
        .e_ccitt_crc = 0,
    };
    const c_file = @ptrCast([*c]const u8, file);
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    defer bw.flush() catch unreachable; // don't forget to flush!
    try stdout.print("Connecting to I2CDriver on {s}. If progress stalls, unplug device and re-insert.\n", .{c_file});
    try bw.flush();
    try stdout.print("Sending pixels to display...", .{});
    c.i2c_connect(&i2c, c_file);
    try stdout.print("Device connected\n", .{});
    if (i2c.connected != 1) return error.I2CConnectionFailed;

    // Initialize the device
    if (c.i2c_start(&i2c, device_id, 0) != 1) // 0 for write, 1 for read. Seems to be a mask
        return error.I2CStartFailed;
    try i2cWrite(&i2c, &[_]u8{ 0x00, 0x8d, 0x14 }); // Enable charge pump
    // Charge pump takes a few ms so let's do some other stuff in the meantime
    try i2cWrite(&i2c, &[_]u8{ 0x00, 0x20, 0x00 }); // Horizontal addressing mode
    try i2cWrite(&i2c, &[_]u8{ 0x00, 0x21, 0x00, 0x7F }); // Start column 0, end column 127
    try i2cWrite(&i2c, &[_]u8{ 0x00, 0x22, 0x00, 0x07 }); // Start page 0, end page 7
    try i2cWrite(&i2c, &[_]u8{ 0x00, 0xaf }); // Display on (should this be after our image is written?

    // We stop/start here since otherwise it seems our data goes nowhere. Not
    // sure it's actually our problem but this seems to fix it
    c.i2c_stop(&i2c);
    if (c.i2c_start(&i2c, device_id, 0) != 1) // 0 for write, 1 for read. Seems to be a mask
        return error.I2CStartFailed;

    // Write data to device
    try i2cWrite(&i2c, &pixels_write_command);
    // Leaving this here because we'll need it later I think
    // for (0..HEIGHT) |i| {
    //     std.log.debug("{d:0>2}: {s}\n", .{ i, fmtSliceGreyscaleImage(pixels[(i * WIDTH)..((i + 1) * WIDTH)]) });
    // }
    try stdout.print("done\n", .{});
}

fn packPixelsToDeviceFormat(pixels: []const u8, packed_pixels: []u8) void {
    // Each u8 in pixels is a single bit. We need to pack these bits
    for (packed_pixels, 0..) |*b, i| {
        const column = i % WIDTH;
        const page = i / WIDTH;

        // if (column == 0) std.debug.print("{d}: ", .{page});
        // pixel array will be 8x as "high" as the data array we are sending to
        // the device. So the device column above is only our starter
        // Display has 8 pages, which is a set of 8 pixels with LSB at top of page
        //
        // To convert from the pixel array above, we need to:
        //   1. convert from device page to a base "row" in the pixel array
        const row = page * PAGES;
        //   2. We will have 8 rows for each base row
        //   3. Multiple each row by the width to get the index of the start of
        //      the row
        //   4. Add our current column index for the final pixel location in
        //      the pixel array.
        //
        // Now that we have the proper index in the pixel array, we need to
        // convert that into our destination byte. Each index will be a u8, either
        // 0xff for on or 0x00 for off. So...
        //
        //   1. We will take the value and bitwise and with 0x01 so we get one bit
        //      per source byte
        //   2. Shift that bit into the proper position in our destination byte

        b.* = (pixels[(0 + row) * WIDTH + column] & 0x01) << 0 |
            (pixels[(1 + row) * WIDTH + column] & 0x01) << 1 |
            (pixels[(2 + row) * WIDTH + column] & 0x01) << 2 |
            (pixels[(3 + row) * WIDTH + column] & 0x01) << 3 |
            (pixels[(4 + row) * WIDTH + column] & 0x01) << 4 |
            (pixels[(5 + row) * WIDTH + column] & 0x01) << 5 |
            (pixels[(6 + row) * WIDTH + column] & 0x01) << 6 |
            (pixels[(7 + row) * WIDTH + column] & 0x01) << 7;

        // std.debug.print("{s}", .{std.fmt.fmtSliceHexLower(&[_]u8{b.*})});
        // if (column == 127) std.debug.print("\n", .{});

        // Last 2 pages are yellow...16 pixels vertical
        // if (page == 6 or page == 7) b.* = 0xff;
        // b.* = 0xf0;
    }
}
fn i2cWrite(i2c: *c.I2CDriver, bytes: []const u8) !void {
    var rc = c.i2c_write(i2c, @ptrCast([*c]const u8, bytes), bytes.len); // nn is size of array
    if (rc != 1)
        return error.BadWrite;
}

fn fmtSliceGreyscaleImage(bytes: []const u8) std.fmt.Formatter(formatSliceGreyscaleImage) {
    return .{ .data = bytes };
}
fn formatSliceGreyscaleImage(
    bytes: []const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    for (bytes) |b| {
        switch (b) {
            0xff => try writer.writeByte('1'),
            0x00 => try writer.writeByte('0'),
            else => unreachable,
        }
    }
}
fn reportMagickError(mw: ?*c.MagickWand) !void {
    var severity: c.ExceptionType = undefined;
    var description = c.MagickGetException(mw, &severity);
    defer description = @ptrCast([*c]u8, c.MagickRelinquishMemory(description));
    try std.io.getStdErr().writer().print("{s}\n", .{description});
}
fn textForLine(line: usize) []u8 {
    return lines[line].*;
}
fn convertImage(filename: [:0]u8, pixels: *[WIDTH * HEIGHT]u8, text_fn: *const fn (usize) []u8) !void {
    c.MagickWandGenesis();
    defer c.MagickWandTerminus();
    var mw = c.NewMagickWand();
    defer {
        if (mw) |w| mw = c.DestroyMagickWand(w);
    }

    // Reading an image into ImageMagick is problematic if it isn't a bmp
    // as the library needs a bunch of dependencies available
    var status: c.MagickBooleanType = undefined;
    if (filename.len > 0) {
        status = c.MagickReadImage(mw, filename);
    } else {
        // TODO: if there is no background image AND
        // we precompute monochrome bit patterns for our font
        // we can completely avoid ImageMagick here. Even with
        // a background we can do the conversion, then do our
        // own text overlay after monochrome conversion.
        // Faster and smaller binary (maybe multi-font support?)
        const blob = @embedFile("images/blank.bmp");
        status = c.MagickReadImageBlob(mw, blob, blob.len);
    }
    if (status == c.MagickFalse) {
        if (!std.mem.eql(u8, filename[filename.len - 3 ..], "bmp"))
            try std.io.getStdErr().writer().print("File is not .bmp. That is probably the problem\n", .{});
        try reportMagickError(mw);
        return error.CouldNotReadImage;
    }

    // Get height and width of the image
    const w = c.MagickGetImageWidth(mw);
    const h = c.MagickGetImageHeight(mw);

    std.log.debug("Original dimensions: {d}x{d}\n", .{ w, h });
    // This should be 48x64 with our test
    // Command line resize works differently than this. Here we need to find
    // new width and height based on the input aspect ratio ourselves
    const resize_dimensions = getNewDimensions(w, h, WIDTH, HEIGHT);

    std.log.debug("Dimensions for resize: {d}x{d}\n", .{ resize_dimensions.width, resize_dimensions.height });

    status = c.MagickResizeImage(mw, resize_dimensions.width, resize_dimensions.height, c.UndefinedFilter);
    if (status == c.MagickFalse)
        return error.CouldNotResizeImage;

    var pw = c.NewPixelWand();
    defer {
        if (pw) |pixw| pw = c.DestroyPixelWand(pixw);
    }
    status = c.PixelSetColor(pw, "white");
    if (status == c.MagickFalse)
        return error.CouldNotSetColor;

    status = c.MagickSetImageBackgroundColor(mw, pw);
    if (status == c.MagickFalse)
        return error.CouldNotSetBackgroundColor;

    // This centers the original image on the new canvas.
    // Note that the extent's offset is relative to the
    // top left corner of the *original* image, so adding an extent
    // around it means that the offset will be negative
    status = c.MagickExtentImage(
        mw,
        WIDTH,
        HEIGHT,
        -@intCast(isize, (WIDTH - resize_dimensions.width) / 2),
        -@intCast(isize, (HEIGHT - resize_dimensions.height) / 2),
    );

    if (status == c.MagickFalse)
        return error.CouldNotSetExtent;

    for (0..LINES) |i| {
        const text = text_fn(i);
        if (text.len == 0) continue;
        // We have text!
        const y: isize = FONT_HEIGHT * @intCast(isize, i);
        var x: isize = BORDER_LEFT;
        var left_spaces: isize = 0;
        for (text) |ch| {
            if (ch == ' ') {
                left_spaces += 1;
                continue;
            }
            break;
        }
        x += (FONT_WIDTH * left_spaces);
        mw = try drawString(mw, text[@intCast(usize, left_spaces)..], x, y);
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

    status = c.MagickExportImagePixels(mw, 0, 0, WIDTH, HEIGHT, "I", c.CharPixel, @ptrCast(*anyopaque, pixels));

    if (status == c.MagickFalse)
        return error.CouldNotExportImage;

    for (0..WIDTH * HEIGHT) |i| {
        switch (pixels[i]) {
            0x00 => pixels[i] = 0xFF,
            0xFF => pixels[i] = 0x00,
            else => {},
        }
    }
}
fn drawString(mw: ?*c.MagickWand, str: []const u8, x: isize, y: isize) !?*c.MagickWand {
    var rc = mw;
    for (str, 0..) |ch, i| {
        rc = try drawCharacter(
            rc,
            ch,
            -(x + @intCast(isize, FONT_WIDTH * i)),
            -y,
        );
    }
    return rc;
}

fn drawCharacter(mw: ?*c.MagickWand, char: u8, x: isize, y: isize) !?*c.MagickWand {
    // Create a second wand. Does this need to exist after the block?
    var cw = c.NewMagickWand();
    defer {
        if (cw) |dw| cw = c.DestroyMagickWand(dw);
        // if (merged) |mergeme| {
        //     _ = c.DestroyMagickWand(mw);
        //     mw = mergeme;
        // }
    }
    const image_char = chars[char];
    if (image_char.len == 0) return error.CharacterNotSupported;
    var status = c.MagickReadImageBlob(cw, @ptrCast(?*const anyopaque, image_char), image_char.len);
    if (status == c.MagickFalse) unreachable; // Something is terribly wrong if this fails

    // For character placement, we need to set the image to the correct
    // extent, and offset the image as appropriate. When we set the extent,
    // we need the fill background to be transparent so we don't overwrite
    // the background. This also means our font needs a transparent background
    // (maybe?)
    {
        var pwc = c.NewPixelWand();
        defer {
            if (pwc) |pixwc| pwc = c.DestroyPixelWand(pixwc);
        }
        status = c.PixelSetColor(pwc, "transparent");
        if (status == c.MagickFalse)
            return error.CouldNotSetColor;

        status = c.MagickSetImageBackgroundColor(cw, pwc);
        if (status == c.MagickFalse)
            return error.CouldNotSetBackgroundColor;
        // I think our characters are offset by 6px in the x and 8 in the y
        status = c.MagickExtentImage(
            cw,
            WIDTH,
            HEIGHT,
            x,
            y,
        );
        if (status == c.MagickFalse)
            return error.CouldNotSetExtent;
    }

    // I think I need to add the image, then flatten this
    status = c.MagickAddImage(mw, cw);
    if (status == c.MagickFalse) return error.CouldNotAddImage;

    // This works, but idk exactly what it's doing. I get the sense
    // I this only works with two images...
    // c.MagickResetIterator(mw);
    c.MagickSetFirstIterator(mw);
    defer {
        if (mw) |w| _ = c.DestroyMagickWand(w);
    }
    return c.MagickMergeImageLayers(mw, c.FlattenLayer);
}

const Dimensions = struct {
    width: usize,
    height: usize,
};

fn getNewDimensions(width: usize, height: usize, desired_width: usize, desired_height: usize) Dimensions {
    // assuming we're shrinking for now.
    // TODO: Handle expansion
    const width_ratio = @intToFloat(f64, width) / @intToFloat(f64, desired_width);
    const height_ratio = @intToFloat(f64, height) / @intToFloat(f64, desired_height);
    const resize_ratio = if (width_ratio > height_ratio) width_ratio else height_ratio;

    return .{
        .width = @floatToInt(usize, @intToFloat(f64, width) / resize_ratio), // 48,
        .height = @floatToInt(usize, @intToFloat(f64, height) / resize_ratio), // 64,
    };
}

test "gets correct bytes" {
    const bg_file: [:0]u8 = @constCast("logo:");
    const opts = .{ .background_filename = bg_file, .device_file = "-" };
    const empty: [:0]u8 = @constCast("");
    for (&lines) |*line| {
        line.* = &empty;
    }
    const line: [:0]u8 = @constCast("Hello\\!");
    lines[5] = &line;
    var pixels: [WIDTH * HEIGHT]u8 = undefined;

    var expected_pixels: *const [WIDTH * HEIGHT]u8 = @embedFile("testExpectedBytes.bin");

    // [_]u8{..,..,..}
    try convertImage(opts.background_filename, &pixels, textForLine);
    // try writeBytesToFile("testExpectedBytes.bin", &pixels);
    try std.testing.expectEqualSlices(u8, expected_pixels, &pixels);
}
fn writeBytesToFile(filename: []const u8, bytes: []u8) !void {
    const file = try std.fs.cwd().createFile(filename, .{
        .read = false,
        .truncate = true,
        .lock = .Exclusive,
        .lock_nonblocking = false,
        .mode = 0o666,
        .intended_io_mode = .blocking,
    });
    defer file.close();
    const writer = file.writer();
    try writer.writeAll(bytes);
    // try writer.print("pub const chars = &[_][]const u8{{\n", .{});
}
test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
