const std = @import("std");

const Tty = @This();

in: std.fs.File.Reader,
out: std.fs.File.Writer,
termios: std.posix.termios,
fg_col: usize = 0,
max_width: usize = 80,
max_height: usize = 25,

pub fn init(io: std.Io, path: []const u8, read_buf: []u8, write_buf: []u8) !Tty {
    const tty_file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    errdefer tty_file.close();

    const reader = tty_file.reader(io, read_buf);
    const writer = tty_file.writer(write_buf);

    var termios = try std.posix.tcgetattr(tty_file.handle);
    // Disable all of
    // ICANON  Canonical input (erase and kill processing).
    // ECHO    Echo.
    // ISIG    Signals from control characters
    // ICRNL   Conversion of CR characters into NL

    termios.iflag.ICRNL = false;
    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.ISIG = false;

    try std.posix.tcsetattr(tty_file.handle, .NOW, termios);
    var tty: Tty = .{
        .in = reader,
        .out = writer,
        .termios = termios,
    };
    errdefer tty.resetTermios();

    tty.getWinSize();

    try tty.setNormal();

    return tty;
}

pub fn deinit(self: *Tty) void {
    self.resetTermios();
    self.in.file.close(self.in.io);
}

pub fn resetTermios(self: *Tty) void {
    self.termios.iflag.ICRNL = true;
    self.termios.lflag.ECHO = true;
    self.termios.lflag.ICANON = true;
    self.termios.lflag.ISIG = true;

    std.posix.tcsetattr(self.in.file.handle, .NOW, self.termios) catch {};
}

pub fn getWinSize(self: *Tty) void {
    var winsize: std.posix.winsize = undefined;
    const result = std.c.ioctl(self.out.file.handle, std.posix.T.IOCGWINSZ, &winsize);

    if (result != -1) {
        self.max_width = 80;
        self.max_height = 25;
    } else {
        self.max_width = @intCast(winsize.col);
        self.max_height = @intCast(winsize.row);
    }
}

pub fn setNormal(self: *Tty) !void {
    try self.setSGR(0);
    self.fg_col = 9;
}

pub fn setSGR(self: *Tty, code: usize) !void {
    try self.out.interface.print("{c}{c}{d}m", .{ 0x1b, '[', code });
}

pub fn flush(self: *Tty) !void {
    try self.out.interface.flush();
}

pub fn setInvert(self: *Tty) !void {
    try self.setSGR(7);
}

pub fn setunderline(self: *Tty) !void {
    try self.setSGR(4);
}

pub fn setNoWrap(self: *Tty) !void {
    try self.out.interface.print("{c}{c}?7l", .{ 0x1b, '[' });
}

pub fn setWrap(self: *Tty) !void {
    try self.out.interface.print("{c}{c}?7h", .{ 0x1b, '[' });
}

pub fn newLine(self: *Tty) !void {
    try self.out.interface.print("{c}{c}K\n", .{ 0x1b, '[' });
}

pub fn clearLine(self: *Tty) !void {
    try self.out.interface.print("{c}{c}K", .{ 0x1b, '[' });
}

pub fn setCol(self: *Tty, col: usize) !void {
    try self.out.interface.print("{c}{c}{d}G", .{ 0x1b, '[', col + 1 });
}

pub fn moveUp(self: *Tty, i: usize) !void {
    try self.out.interface.print("{c}{c}{d}A", .{ 0x1b, '[', i });
}

pub fn putChar(self: *Tty, c: u8) !void {
    try self.out.interface.print("{c}", .{c});
}

pub fn print(self: *Tty, comptime fmt: []const u8, args: anytype) !void {
    try self.out.interface.print(fmt, args);
}
