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

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const io = threaded.io();

    const args = try std.process.argsAlloc(arena);

    if (tracy.enable_allocation) {
        var gpa_tracy = tracy.tracyAllocator(gpa);
        return mainArgs(io, gpa_tracy.allocator(), arena, args);
    }

    try mainArgs(io, gpa, arena, args);
}

fn mainArgs(io: Io, gpa: Allocator, arena: Allocator, args: []const []const u8) !void {
    const tr = tracy.trace(@src());
    defer tr.end();

    const commands = try cli.parse(args, null);

    var child: ?std.process.Child = null;
    defer if (child) |*c| {
        _ = c.kill(io) catch {};
    };

    var env = try std.process.getEnvMap(arena);

    var stdin_buf: [4 * 65_536]u8 = undefined;
    var stdin_reader = blk: {
        if (try Io.File.stdin().isTty(io)) {
            var child_argv: std.ArrayList([]const u8) = .empty;

            const argv_str = env.get("FZF_DEFAULT_COMMAND") orelse "find . -type f";

            var it = std.mem.splitScalar(u8, argv_str, ' ');
            while (it.next()) |child_arg| {
                try child_argv.append(arena, child_arg);
            }

            child = std.process.Child.init(child_argv.items, gpa);
            child.?.stdout_behavior = .Pipe;

            try child.?.spawn(io);

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
            var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
            const stdout = &stdout_writer.interface;
            if (try run(io, gpa, input, opts)) |result| {
                try stdout.print("{s}\n", .{result});
                try stdout.flush();
            }
        },
        .filter => |opts| {
            try filter(io, gpa, arena, input, opts);
        },
        .version => |version| {
            var stdout_buf: [64]u8 = undefined;
            var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
            const stdout: *Io.Writer = &stdout_writer.interface;

            try stdout.print("{s}\n", .{version});
            try stdout.flush();
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

    var app: App = .init(&tty, input, opts);

    var result: ?[]const u8 = null;

    try app.run(io, gpa, &result);

    return result;
}

test "all" {
    std.testing.refAllDeclsRecursive(@This());
}

fn filter(io: Io, gpa: Allocator, arena: Allocator, input: Input, opts: cli.FilterOptions) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const work_queue_buf = try arena.alloc(Match.Work, input.matches.len);
    var work_queue: Io.Queue(Match.Work) = .init(work_queue_buf);

    var group: Io.Group = .init;
    defer group.cancel(io);

    const worker_count = std.Thread.getCpuCount() catch 1;
    for (0..worker_count) |_| {
        try group.concurrent(io, Match.worker, .{ io, gpa, &work_queue, input.max_input_len });
    }

    const window = try Match.updateMatches(io, opts.search_str, input.matches, &work_queue);
    for (window) |match| {
        if (opts.show_scores) {
            try stdout.print("({d:.2}) ", .{match.score});
        }
        try stdout.print("{s}\n", .{match.original_str});
    }
    try stdout.flush();
}
