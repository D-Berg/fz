const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Tty = @import("Tty.zig");
const util = @import("util.zig");
const App = @This();

tty: *Tty,
choices: []const []const u8,
/// indexes into choices
matching: []const usize,
match_buf: []usize,
selected: usize,
search_str: []u8,
search_buf: [256]u8,

pub fn init(gpa: Allocator, tty: *Tty, choices: []const []const u8) !App {
    var app: App = undefined;
    const match_buf = try gpa.alloc(usize, choices.len);
    app.tty = tty;
    app.choices = choices;
    app.selected = 0;
    app.match_buf = match_buf;
    app.search_buf = undefined;
    return app;
}

pub fn deinit(app: *App, gpa: Allocator) void {
    gpa.free(app.match_buf);
}

pub fn run(app: *App, io: Io, gpa: Allocator) !void {
    const tty = app.tty;
    app.search_str = app.search_buf[0..0];
    app.matching = app.match_buf[0..0];
    _ = gpa;
    _ = io;

    var buf: [1]u8 = undefined;
    while (true) {
        const n_read = try tty.in.interface.readSliceShort(&buf);
        const maybe_c = if (n_read == 1) buf[0] else null;
        if (maybe_c) |c| switch (c) {
            util.ctrl('c') => return,
            127 => {
                // backspace
                if (app.search_str.len > 0) {
                    app.search_str.len -= 1;
                }
            },

            else => {
                const at = app.search_str.len;
                if (at < app.search_buf.len) {
                    app.search_str.len += 1;
                    app.search_str[at] = c;
                }
            },
        };

        try app.draw();
    }
}

const prompt = "> ";
pub fn draw(app: *App) !void {
    const tty = app.tty;
    tty.getWinSize();

    try tty.hideCursor();

    try tty.moveTo(tty.max_height, 1);
    try tty.clearLine();
    try tty.print("{s}{s}", .{ prompt, app.search_str });

    const min = @min(5, app.choices.len);
    for (0..min) |i| {
        const row = tty.max_height - 1 - i;

        try tty.moveTo(row, 1);

        try tty.clearLine();

        const str = app.choices[i];
        const max_len = @min(tty.max_width, str.len);
        try tty.print("{s}", .{str[0..max_len]});
    }

    try tty.moveTo(tty.max_height, prompt.len + app.search_str.len + 1);

    // Show cursor
    try tty.showCursor();

    try tty.flush();
}
