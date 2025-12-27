const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

const Tty = @This();

in: Io.File.Reader,
out: Io.File.Writer,
original_termios: std.posix.termios,
fg_col: usize = 0,
max_width: usize = 80,
max_height: usize = 25,

pub fn init(io: std.Io, path: []const u8, read_buf: []u8, write_buf: []u8) !Tty {
    const tty_file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    errdefer tty_file.close(io);

    const reader = tty_file.reader(io, read_buf);
    const writer = tty_file.writer(io, write_buf);

    var termios = try std.posix.tcgetattr(tty_file.handle);
    var tty: Tty = .{
        .in = reader,
        .out = writer,
        .original_termios = termios,
    };

    // Disable all of
    // ICANON  Canonical input (erase and kill processing).
    // ECHO    Echo.
    // ISIG    Signals from control characters
    // ICRNL   Conversion of CR characters into NL
    termios.iflag.ICRNL = false;
    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.ISIG = false;

    const VMIN: usize = @intCast(@intFromEnum(std.posix.V.MIN));
    const VTIME: usize = @intCast(@intFromEnum(std.posix.V.TIME));

    termios.cc[VMIN] = 0;
    termios.cc[VTIME] = 1;

    try std.posix.tcsetattr(tty_file.handle, .NOW, termios);
    errdefer tty.resetTermios();

    tty.getWinSize();

    try tty.setNormal();

    try tty.enterAltScreen();
    try tty.flush();

    return tty;
}

pub fn deinit(self: *Tty) void {
    self.exitAltScreen() catch {};
    self.flush() catch {};
    self.resetTermios();
    self.in.file.close(self.in.io);
}

pub fn resetTermios(self: *Tty) void {
    std.posix.tcsetattr(self.in.file.handle, .NOW, self.original_termios) catch {};
}

pub fn getWinSize(self: *Tty) void {
    var winsize: std.posix.winsize = undefined;

    const rc = switch (builtin.os.tag) {
        // prevents need to link libc on linux
        .linux => std.os.linux.ioctl(self.out.file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize)),
        else => std.c.ioctl(self.out.file.handle, std.posix.T.IOCGWINSZ, &winsize),
    };
    if (rc == -1) {
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

pub fn print(self: *Tty, comptime fmt: []const u8, args: anytype) !void {
    try self.out.interface.print(fmt, args);
}

pub fn setNoWrap(self: *Tty) !void {
    try self.print("{c}{c}?7l", .{ 0x1b, '[' });
}

pub fn setWrap(self: *Tty) !void {
    try self.print("{c}{c}?7h", .{ 0x1b, '[' });
}

pub fn newLine(self: *Tty) !void {
    try self.print("{c}{c}K\n", .{ 0x1b, '[' });
}

pub fn clearLine(self: *Tty) !void {
    try self.print("{c}{c}K", .{ 0x1b, '[' });
}

pub fn clearScreen(self: *Tty) !void {
    try self.print("\x1b[1J", .{});
}

pub fn setCol(self: *Tty, col: usize) !void {
    try self.print("{c}{c}{d}G", .{ 0x1b, '[', col + 1 });
}

pub fn moveUp(self: *Tty, i: usize) !void {
    try self.print("{c}{c}{d}A", .{ 0x1b, '[', i });
}

pub fn moveDown(self: *Tty, i: usize) !void {
    try self.print("{c}{c}{d}B", .{ 0x1b, '[', i });
}

pub fn putChar(self: *Tty, c: u8) !void {
    try self.print("{c}", .{c});
}

pub fn enterAltScreen(self: *Tty) !void {
    try self.print("\x1b[?1049h", .{});
}

pub fn exitAltScreen(self: *Tty) !void {
    try self.print("\x1b[?1049l", .{});
}

pub fn moveTo(self: *Tty, row: usize, col: usize) !void {
    try self.print("\x1b[{d};{d}H", .{ row, col });
}

pub fn hideCursor(self: *Tty) !void {
    try self.print("\x1b[?25l", .{});
}

pub fn showCursor(self: *Tty) !void {
    try self.print("\x1b[?25h", .{});
}

pub fn writeByte(self: *Tty, byte: u8) !void {
    try self.out.interface.writeByte(byte);
}

const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
    bold,
    dim,
    fzf_red,
    highlight_gray,
    fzf_gray,
    reset,
};

pub fn setColor(self: *Tty, color: Color) !void {
    const color_string = switch (color) {
        .black => "\x1b[30m",
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .blue => "\x1b[34m",
        .magenta => "\x1b[35m",
        .cyan => "\x1b[36m",
        .white => "\x1b[37m",
        .bright_black => "\x1b[90m",
        .bright_red => "\x1b[91m",
        .bright_green => "\x1b[92m",
        .bright_yellow => "\x1b[93m",
        .bright_blue => "\x1b[94m",
        .bright_magenta => "\x1b[95m",
        .bright_cyan => "\x1b[96m",
        .bright_white => "\x1b[97m",
        .bold => "\x1b[1m",
        .dim => "\x1b[2m",
        .fzf_red => "\x1b[38;2;197;41;96m",
        .highlight_gray => "\x1b[48;2;100;100;100m",
        .fzf_gray => "\x1b[38;2;100;100;100m",
        .reset => "\x1b[0m",
    };
    try self.print("{s}", .{color_string});
}

pub fn readOne(self: *Tty) !u8 {
    var buf: [1]u8 = undefined;
    try self.in.interface.readSliceAll(&buf);
    return buf[0];
}
