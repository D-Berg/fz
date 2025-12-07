const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Tty = @import("Tty.zig");
const Match = @import("Match.zig");
const util = @import("util.zig");
const tracy = @import("tracy.zig");
const cli = @import("cli.zig");

const updateMatches = Match.updateMatches;

const App = @This();
const MAX_SEARCH_LEN = build_options.MAX_SEARCH_LEN;

tty: *Tty,
arena_state: std.heap.ArenaAllocator.State,
matches: []Match,
/// window into matches
window: []const Match,
selected: usize = 0,
search_str: []u8,
search_buf: [MAX_SEARCH_LEN]u8,
opts: cli.RunOptions,
max_input_len: usize,

pub fn init(gpa: Allocator, tty: *Tty, choices: []const []const u8, len_len: usize, opts: cli.RunOptions) !App {
    assert(choices.len > 0);

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_impl.deinit();

    const arena = arena_impl.allocator();

    var app: App = undefined;
    const matches = try arena.alloc(Match, choices.len);

    const lower_str_buf = try arena.alloc(u8, len_len);
    const positions_buf = try arena.alloc(bool, len_len);
    const bonus_buf = try arena.alloc(Match.Score, len_len);

    var max_input_len: usize = 0;
    var start: usize = 0;
    for (choices, 0..) |choice, i| {
        const end = start + choice.len;
        if (choice.len >= max_input_len) max_input_len = choice.len;
        Match.calculateBonus(bonus_buf[start..end], choice);
        matches[i] = Match{
            .original_str = choice,
            .idx = i,
            .score = Match.score_min,
            .lower_str = util.lowerString(lower_str_buf[start..end], choice),
            .positions = positions_buf[start..end],
            .bonus = bonus_buf[start..end],
        };

        start += choice.len;
    }

    app.tty = tty;
    app.selected = 0;
    app.matches = matches;
    app.search_buf = undefined;
    app.arena_state = arena_impl.state;
    app.window = matches[0..];
    app.opts = opts;
    app.max_input_len = max_input_len;
    return app;
}

pub fn deinit(app: *App, gpa: Allocator) void {
    var arena = app.arena_state.promote(gpa);
    arena.deinit();
}

pub fn run(app: *App, io: Io, gpa: Allocator, result: *?[]const u8) !void {
    const tr = tracy.trace(@src());
    defer tr.end();

    const tty = app.tty;
    app.search_str = app.search_buf[0..0];

    try app.draw();

    const work_size = 8;
    const work_queue_buf = try gpa.alloc(Match.Work, work_size);
    defer gpa.free(work_queue_buf);

    var work_queue: Io.Queue(Match.Work) = .init(work_queue_buf);

    var group: Io.Group = .init;
    defer group.cancel(io);

    for (0..work_size) |_| {
        try group.concurrent(io, Match.worker, .{ io, gpa, &work_queue, app.max_input_len });
    }

    var buf: [1]u8 = undefined;
    while (true) {
        tracy.frameMark();
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

                app.window = try updateMatches(io, app.search_str, app.matches, &work_queue);
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

                    app.window = try updateMatches(io, app.search_str, app.matches, &work_queue);
                }
            },
        };

        try app.draw();
    }
}

const prompt = "> ";
pub fn draw(app: *App) !void {
    const tr = tracy.trace(@src());
    defer tr.end();

    const show_scores = app.opts.show_scores;

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
        const selected = app.selected == i;
        try tty.moveTo(row, 1);

        try tty.clearLine();

        const match = app.window[i];

        const str = match.original_str;
        const max_width = @min(tty.max_width - 10, str.len);

        if (selected) {
            try tty.setColor(.fzf_red);
            try tty.setColor(.highlight_gray);
        } else {
            try tty.setColor(.fzf_gray);
        }
        try tty.print("▌", .{});
        try tty.setColor(.reset);
        if (selected) try tty.setColor(.highlight_gray);
        if (builtin.mode == .Debug or show_scores) try tty.print("({d:.2})", .{match.score});

        try tty.print("  ", .{});
        for (0..max_width) |c_idx| {
            if (match.positions[c_idx]) {
                try tty.setColor(.green);
                try tty.setColor(.bold);
            } else {
                try tty.setColor(.reset);
                if (selected) try tty.setColor(.highlight_gray);
            }

            try tty.writeByte(str[c_idx]);
        }

        try tty.setColor(.reset);

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
