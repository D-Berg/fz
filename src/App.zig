const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Tty = @import("Tty.zig");
const util = @import("util.zig");
const App = @This();

const Match = struct {
    original_str: []const u8,
    lower_str: []const u8,
    pattern: []bool,
    score: f64,
};

tty: *Tty,
arena_state: std.heap.ArenaAllocator.State,
/// indexes into choices
matches: []Match,
selected: usize = 0,
search_str: []u8,
search_buf: [256]u8,

pub fn init(gpa: Allocator, tty: *Tty, choices: []const []const u8) !App {
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_impl.deinit();

    const arena = arena_impl.allocator();

    var app: App = undefined;
    const matches = try arena.alloc(Match, choices.len);
    for (choices, 0..) |choice, i| {
        const pattern = try arena.alloc(bool, choice.len);
        @memset(pattern, false);
        matches[i] = Match{
            .lower_str = try util.lowerStringAlloc(arena, choice),
            .original_str = choice,
            .pattern = pattern,
            .score = -std.math.floatMin(f64),
        };
    }
    app.tty = tty;
    app.selected = 0;
    app.matches = matches;
    app.search_buf = undefined;
    app.arena_state = arena_impl.state;

    return app;
}

pub fn deinit(app: *App, gpa: Allocator) void {
    var arena = app.arena_state.promote(gpa);
    arena.deinit();
}

pub fn run(app: *App, io: Io, gpa: Allocator) !void {
    const tty = app.tty;
    app.search_str = app.search_buf[0..0];
    _ = gpa;
    _ = io;

    var buf: [1]u8 = undefined;
    while (true) {
        const n_read = try tty.in.interface.readSliceShort(&buf);
        const maybe_c = if (n_read == 1) buf[0] else null;
        if (maybe_c) |c| switch (c) {
            util.ctrl('c') => return,
            util.ctrl('p') => {
                if (app.selected < app.matches.len) app.selected += 1;
            },
            util.ctrl('n') => {
                if (app.selected > 0) app.selected -= 1;
            },
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

    const max_window_height = @min(tty.max_height - 1, app.matches.len);
    var start: usize = 0;

    if (app.selected >= max_window_height) {
        start = app.selected - max_window_height + 1;
    }

    var end = start + max_window_height;
    if (end > app.matches.len) end = app.matches.len;

    var row = tty.max_height - 1;
    for (start..end) |i| {
        try tty.moveTo(row, 1);

        try tty.clearLine();

        const str = app.matches[i].original_str;

        const max_len = @min(tty.max_width, str.len);
        if (app.selected == i) {
            try tty.print("\x1b[38;2;197;41;96m", .{}); // red
            try tty.print("\x1b[48;2;100;100;100m", .{});
            try tty.print("▌", .{});
            try tty.print("\x1b[m", .{});

            try tty.print("\x1b[48;2;100;100;100m", .{});

            try tty.print("  {s}", .{str[0..max_len]});
            try tty.print("\x1b[m", .{});
        } else {
            try tty.print("\x1b[38;2;100;100;100m▌\x1b[m", .{});
            try tty.print("  {s}", .{str[0..max_len]});
        }

        row -= 1;
    }

    try tty.moveTo(tty.max_height, prompt.len + app.search_str.len + 1);

    // Show cursor
    try tty.showCursor();

    try tty.flush();
}
