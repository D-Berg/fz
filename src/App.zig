const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Tty = @import("Tty.zig");
const Match = @import("Match.zig");
const util = @import("util.zig");

const App = @This();
const MAX_SEARCH_LEN = 1024;

tty: *Tty,
arena_state: std.heap.ArenaAllocator.State,
matches: []Match,
/// window into matches
window: []const Match,
selected: usize = 0,
search_str: []u8,
search_buf: [MAX_SEARCH_LEN]u8,

pub fn init(gpa: Allocator, tty: *Tty, choices: []const []const u8) !App {
    assert(choices.len > 0);

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_impl.deinit();

    const arena = arena_impl.allocator();

    var app: App = undefined;
    const matches = try arena.alloc(Match, choices.len);
    for (choices, 0..) |choice, i| {
        matches[i] = try Match.init(arena, choice, i);
    }
    app.tty = tty;
    app.selected = 0;
    app.matches = matches;
    app.search_buf = undefined;
    app.arena_state = arena_impl.state;
    app.window = matches[0..];

    return app;
}

pub fn deinit(app: *App, gpa: Allocator) void {
    var arena = app.arena_state.promote(gpa);
    arena.deinit();
}

pub fn run(app: *App, io: Io, gpa: Allocator, result: *?[]const u8) !void {
    const tty = app.tty;
    app.search_str = app.search_buf[0..0];

    _ = io;

    try app.draw();

    app.window = try updateMatches(gpa, app.search_str, app.matches);

    var buf: [1]u8 = undefined;
    while (true) {
        const n_read = try tty.in.interface.readSliceShort(&buf);
        const maybe_c = if (n_read == 1) buf[0] else null;

        // TODO: vim mode
        if (maybe_c) |c| switch (c) {
            util.ctrl('c') => return,
            util.ctrl('p') => {
                if (app.selected + 1 < app.window.len) {
                    app.selected += 1;
                } else {
                    app.selected = 0;
                }
            },
            util.ctrl('n') => {
                if (app.selected > 0) {
                    app.selected -= 1;
                } else {
                    app.selected = if (app.window.len > 0)
                        app.window.len - 1
                    else
                        0;
                }
            },
            127 => {
                // backspace
                if (app.search_str.len > 0) {
                    app.search_str.len -= 1;
                }

                app.window = try updateMatches(gpa, app.search_str, app.matches);
            },

            '\r', '\n' => {
                if (app.selected < app.window.len) {
                    result.* = app.window[app.selected].original_str;
                }
                return;
            },
            else => {
                const at = app.search_str.len;
                if (at < MAX_SEARCH_LEN) {
                    app.search_str.len += 1;
                    app.search_str[at] = c;

                    app.window = try updateMatches(gpa, app.search_str, app.matches);
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

    // TODO: handle input longer than tty width
    try tty.print("{s}{s}", .{ prompt, app.search_str });

    const max_window_height = @min(tty.max_height - 1, app.window.len);

    var start: usize = 0;
    if (app.selected >= max_window_height) {
        start = app.selected - max_window_height;
    }

    var end = start + max_window_height;
    if (end >= app.window.len) end = app.window.len;

    assert(end >= start);

    var row = tty.max_height - 1;
    for (start..end) |i| {
        try tty.moveTo(row, 1);

        try tty.clearLine();

        const match = app.window[i];

        const str = match.original_str;
        const max_width = @min(tty.max_width - 10, str.len);

        if (app.selected == i) {
            try tty.print("\x1b[38;2;197;41;96m", .{}); // red
            try tty.print("\x1b[48;2;100;100;100m", .{});
            try tty.print("▌", .{});
            try tty.print("\x1b[m", .{});

            try tty.print("\x1b[48;2;100;100;100m", .{});

            if (builtin.mode == .Debug) try tty.print("({d:.2})", .{match.score});

            try tty.print("  {s}", .{str[0..max_width]});
            try tty.print("\x1b[m", .{});
        } else {
            try tty.print("\x1b[38;2;100;100;100m▌\x1b[m", .{});
            if (builtin.mode == .Debug) try tty.print("({d:.2})", .{match.score});
            try tty.print("  {s}", .{str[0..max_width]});
        }

        row -= 1;
    }
    while (row >= 1) : (row -= 1) {
        try tty.moveTo(row, 1);
        try tty.clearLine();
    }

    try tty.moveTo(tty.max_height, prompt.len + app.search_str.len + 1);

    // Show cursor
    try tty.showCursor();

    try tty.flush();
}

// TODO: update concurrently
/// Returns a slice into matches and update each match score
pub fn updateMatches(gpa: Allocator, search_str: []const u8, matches: []Match) ![]const Match {
    if (search_str.len == 0) {
        // restore to original
        Match.sortMatches(matches, Match.orderByIdx);
        for (matches) |*match| match.score = Match.score_min;
        return matches[0..];
    }

    var buf: [MAX_SEARCH_LEN]u8 = undefined;
    const needle = util.lowerString(&buf, search_str);

    for (matches) |*match| {
        try match.updateScore(gpa, needle);
    }

    Match.sortMatches(matches, Match.orderByScore);

    var len: usize = 0;
    for (matches) |match| {
        if (match.score <= 0) break;
        len += 1;
    }
    return matches[0..len];
}
