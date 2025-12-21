const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Tty = @import("Tty.zig");
const App = @import("App.zig");
const Match = @import("Match.zig");
const cli = @import("cli.zig");
const tracy = @import("tracy.zig");
const util = @import("util.zig");
const Input = util.Input;
const getInput = util.getInput;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const is_debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

pub fn main() !void {
    const tr = tracy.trace(@src());
    defer tr.end();

    const gpa: std.mem.Allocator = switch (is_debug) {
        true => debug_allocator.allocator(),
        false => std.heap.smp_allocator,
    };
    defer if (is_debug) {
        assert(debug_allocator.deinit() == .ok);
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    const args = try std.process.argsAlloc(arena);

    if (tracy.enable_allocation) {
        var gpa_tracy = tracy.tracyAllocator(gpa);
        return mainArgs(gpa_tracy.allocator(), arena, args);
    }

    try mainArgs(gpa, arena, args);
}

fn mainArgs(gpa: Allocator, arena: Allocator, args: []const []const u8) !void {
    const tr = tracy.trace(@src());
    defer tr.end();

    var threaded: std.Io.Threaded = .init(gpa);
    defer threaded.deinit();

    const io = threaded.io();

    const commands = try cli.parse(args, null);

    var child: ?std.process.Child = null;
    defer if (child) |*c| {
        _ = c.kill() catch {};
    };

    var env = try std.process.getEnvMap(arena);

    var stdin_buf: [4 * 65_536]u8 = undefined;
    var stdin_reader = blk: {
        if (std.posix.isatty(std.posix.STDIN_FILENO)) {
            var child_argv: std.ArrayList([]const u8) = .empty;

            const argv_str = env.get("FZF_DEFAULT_COMMAND") orelse "find . -type f";

            var it = std.mem.splitScalar(u8, argv_str, ' ');
            while (it.next()) |child_arg| {
                try child_argv.append(arena, child_arg);
            }

            child = std.process.Child.init(child_argv.items, gpa);
            child.?.stdout_behavior = .Pipe;

            try child.?.spawn();

            break :blk child.?.stdout.?.reader(io, &stdin_buf);
        }

        break :blk std.Io.File.stdin().reader(io, &stdin_buf);
    };

    const stdin = &stdin_reader.interface;

    // TODO: change to std.Io.File when writing works

    const input = try getInput(arena, stdin);

    switch (commands) {
        .run => |opts| {
            var stdout_buf: [8192]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_writer.interface;
            if (try run(io, gpa, input, opts)) |result| {
                try stdout.print("{s}\n", .{result});
                try stdout.flush();
            }
        },
        .filter => |opts| {
            try filter(io, gpa, arena, input, opts);
        },
    }

    if (builtin.mode == .ReleaseFast) std.process.exit(0);
}

fn run(
    io: Io,
    gpa: Allocator,
    input: Input,
    opts: cli.RunOptions,
) !?[]const u8 {
    const tr = tracy.trace(@src());
    defer tr.end();

    var tty_buf: [8192]u8 = undefined;

    var tty: Tty = try .init(io, "/dev/tty", &.{}, &tty_buf);
    defer tty.deinit();

    var app: App = try .init(gpa, &tty, input, opts);
    defer app.deinit(gpa);

    var result: ?[]const u8 = null;

    try app.run(io, gpa, &result);

    return result;
}

test "all" {
    std.testing.refAllDeclsRecursive(@This());
}

fn filter(io: Io, gpa: Allocator, arena: Allocator, input: Input, opts: cli.FilterOptions) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const matches = try arena.alloc(Match, input.lines.len);

    const lower_str_buf = try arena.alloc(u8, input.len_len);
    const positions_buf = try arena.alloc(bool, input.len_len);
    const bonus_buf = try arena.alloc(Match.Score, input.len_len);

    var max_input_len: usize = 0;
    var start: usize = 0;
    for (input.lines, 0..) |haystack, i| {
        const end = start + haystack.len;
        if (haystack.len >= max_input_len) max_input_len = haystack.len;
        const bonus = bonus_buf[start..end];
        Match.calculateBonus(bonus, haystack); // TODO: calc bonus

        matches[i] = Match{
            .original_str = haystack,
            .idx = i,
            .score = Match.score_min,
            .lower_str = util.lowerString(lower_str_buf[start..end], haystack),
            .positions = positions_buf[start..end],
            .bonus = bonus,
        };

        start += haystack.len;
    }

    const work_queue_buf = try arena.alloc(Match.Work, 2048);
    var work_queue: Io.Queue(Match.Work) = .init(work_queue_buf);

    var group: Io.Group = .init;
    defer group.cancel(io);

    const worker_count = std.Thread.getCpuCount() catch 1;
    for (0..worker_count) |_| {
        try group.concurrent(io, Match.worker, .{ io, gpa, &work_queue, max_input_len });
    }

    const window = try Match.updateMatches(io, opts.search_str, matches, &work_queue);
    for (window) |match| {
        if (opts.show_scores) {
            try stdout.print("({d:.2}) ", .{match.score});
        }
        try stdout.print("{s}\n", .{match.original_str});
    }
    try stdout.flush();
}
