// Image specifications
pub const WIDTH = 128;
pub const HEIGHT = 64;

// Text specifications
pub const FONT_WIDTH = 5;
pub const FONT_HEIGHT = 8;

pub const CHARS_PER_LINE = 25; // 25 * 5 = 125 so we have 3px left over
pub const BORDER_LEFT = 1; // 1 empty px left, 2 empty on right
pub const LINES = 8;

// Device specifications
pub const PAGES = 8;

// Device ID on this device is hardwired to 0x3c
pub const DEVICE_ID = 0x3c;

pub fn packPixelsToDeviceFormat(pixels: []const u8, packed_pixels: []u8) void {
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
