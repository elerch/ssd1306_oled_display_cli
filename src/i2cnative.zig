const std = @import("std");
const display = @import("display.zig");
const linux = @import("linux.zig");
const log = std.log.scoped(.i2cnative);
const c = @cImport({
    @cInclude("linux/i2c-dev.h");
});

var pixels_write_command: [display.WIDTH * display.PAGES + 1]u8 = undefined;

pub fn sendPixels(pixels: []const u8, file: [:0]const u8, device_id: u8) !void {
    log.debug(
        "sendPixels start. File {s}, Device_id 0x{s}\n",
        .{ file, std.fmt.bytesToHex(&[_]u8{device_id}, .lower) },
    );

    const device_file = try openFile(file, device_id);
    defer device_file.close();

    try initializeDevice(device_file);

    // Do the write
    const write_cmds = &[_]u8{
        0x20, 0x00, // Set memory addressing mode to horizontal
        0x21, 0x00, 0x7F, // Start column 0, end column 127
        0x22, 0x00, 0x07, // Start page 0, end page 7
    };
    try device_file.writeAll(write_cmds);
    display.packPixelsToDeviceFormat(pixels, pixels_write_command[1..]);
    log.debug("pixel array length: {d}. After packing: {d}", .{ pixels.len, pixels_write_command.len - 1 });

    pixels_write_command[0] = 0x40;
    try device_file.writeAll(&pixels_write_command);
    log.debug("sendPixels end", .{});
}

fn openFile(file: [:0]const u8, device_id: u8) !std.fs.File {
    const device_file = try std.fs.openFileAbsoluteZ(file, .{
        .mode = .read_write,
    });
    errdefer device_file.close();
    try linux.ioctl(device_file.handle, c.I2C_SLAVE, device_id);
    return device_file;
}

fn initializeDevice(file: std.fs.File) !void {
    // Send initialization commands to the display
    // zig fmt: off
    const init_cmds = &[_]u8{
        // 0xAE,       // Display off
                       // oscillator frequency will manage flicker.
                       // Recommended at 0x80, I found we sometimes need higher
        // 0xD5, 0xF0, // Set display clock divide ratio/oscillator frequency
        0xD5,    0x80, // Set display clock divide ratio/oscillator frequency
        0xA8,    0x3F, // Set multiplex ratio. Correct for 128x64 devices
        // 0xA8, 0x80, // Set multiplex ratio
        0xD3,    0x00, // Set display offset. Should be 0 normally
        0x40,          // Set start line
        0xA0,          // Set segment remap
        // 0xC8,       // Set COM output scan direction (reversed)
        0xC0,          // Set COM output scan direction (normal)
        0xDA,    0x12, // Set COM pins hardware configuration. 0x12 for 128x64
        0x81,    0x7F, // Set contrast
                       // These next 4 should not be needed
        // 0xD9, 0xF1, // Set precharge period
        // 0xDB, 0x40, // Set VCOMH deselect level
        // 0xA4,       // Set entire display on/off
        // 0xA6,       // Set normal display
        0x8D,    0x14, // Charge pump
        0xAF,          // Display on
    };
    // zig fmt: on
    try file.writeAll(init_cmds);
}
