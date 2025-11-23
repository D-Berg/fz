const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Tty = @import("Tty.zig");
const App = @import("App.zig");
const cli = @import("cli.zig");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const is_debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

pub fn main() !void {
    const gpa: std.mem.Allocator = switch (is_debug) {
        true => debug_allocator.allocator(),
        false => std.heap.smp_allocator,
    };
    defer if (is_debug) {
        assert(debug_allocator.deinit() == .ok);
    };

    var threaded: std.Io.Threaded = .init(gpa);
    defer threaded.deinit();

    const io = threaded.io();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    const args = try std.process.argsAlloc(arena);
    const commands = try cli.parse(args, null);

    if (std.posix.isatty(std.posix.STDIN_FILENO)) {
        std.debug.print("you werent piped to\n", .{});
        // TODO: get data from default command
    } else {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
        const stdin = &stdin_reader.interface;

        var stdout_buf: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        const stdout = &stdout_writer.interface;

        var lines: std.ArrayList([]const u8) = .empty;
        while (try stdin.takeDelimiter('\n')) |line| {
            try lines.ensureUnusedCapacity(arena, 1);
            lines.appendAssumeCapacity(try arena.dupe(u8, line));
        }

        switch (commands) {
            .run => {
                if (try findStr(io, gpa, lines.items)) |result| {
                    try stdout.print("{s}\n", .{result});
                    try stdout.flush();
                }
            },
            .filter => |search_str| {
                std.debug.print("search str = {s}\n", .{search_str});
                @panic("TODO");
            },
        }
    }
}

pub fn findStr(io: Io, gpa: Allocator, lines: []const []const u8) !?[]const u8 {
    var write_buf: [1024]u8 = undefined;

    var tty: Tty = try .init(io, "/dev/tty", &.{}, &write_buf);
    defer tty.deinit();

    var app: App = try .init(gpa, &tty, lines);
    defer app.deinit(gpa);

    var result: ?[]const u8 = null;

    try app.run(io, gpa, &result);

    return result;
}

test "all" {
    std.testing.refAllDeclsRecursive(@This());
}
