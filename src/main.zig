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

    if (std.posix.isatty(std.posix.STDIN_FILENO)) {
        std.debug.print("you werent piped to\n", .{});
        // TODO: get data from default command
    } else {
        var stdin_buf: [32_768]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
        const stdin = &stdin_reader.interface;

        // TODO: change to std.Io.File when writing works
        var stdout_buf: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        const stdout = &stdout_writer.interface;

        const choices = try getInput(arena, stdin);

        switch (commands) {
            .run => |opts| {
                if (try run(io, gpa, choices, opts)) |result| {
                    try stdout.print("{s}\n", .{result});
                    try stdout.flush();
                }
            },
            .filter => |opts| {
                const matches = try arena.alloc(Match, choices.len);
                for (choices, 0..) |choice, i| {
                    matches[i] = try Match.init(arena, choice, i);
                }

                const work_size = 8; // TODO: dont hardcode it
                const work_queue_buf = try gpa.alloc(Match.Work, 1024);
                defer gpa.free(work_queue_buf);

                var work_queue: Io.Queue(Match.Work) = .init(work_queue_buf);

                var group: Io.Group = .init;
                defer group.cancel(io);

                for (0..work_size) |_| {
                    try group.concurrent(io, Match.worker, .{ io, gpa, &work_queue });
                }

                const window = try Match.updateMatches(io, opts.search_str, matches, &work_queue);
                for (window) |match| {
                    if (opts.show_scores) {
                        try stdout.print("({d:.2}) {s}\n", .{ match.score, match.original_str });
                    } else {
                        try stdout.print("{s}\n", .{match.original_str});
                    }
                    try stdout.flush();
                }
            },
        }
    }
}

fn run(io: Io, gpa: Allocator, lines: []const []const u8, opts: cli.RunOptions) !?[]const u8 {
    const tr = tracy.trace(@src());
    defer tr.end();

    var write_buf: [1024]u8 = undefined;

    var tty: Tty = try .init(io, "/dev/tty", &.{}, &write_buf);
    defer tty.deinit();

    var app: App = try .init(gpa, &tty, lines, opts);
    defer app.deinit(gpa);

    var result: ?[]const u8 = null;

    try app.run(io, gpa, &result);

    return result;
}

fn getInput(gpa: Allocator, in: *Io.Reader) ![]const []const u8 {
    const tr = tracy.trace(@src());
    defer tr.end();

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| {
            gpa.free(line);
        }
        lines.deinit(gpa);
    }

    while (try in.takeDelimiter('\n')) |line| {
        try lines.ensureUnusedCapacity(gpa, 1);
        lines.appendAssumeCapacity(try gpa.dupe(u8, line));
    }

    return try lines.toOwnedSlice(gpa);
}

test "all" {
    std.testing.refAllDeclsRecursive(@This());
}
