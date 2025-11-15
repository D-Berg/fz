const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Tty = @import("Tty.zig");
const App = @import("App.zig");

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

    if (std.posix.isatty(std.posix.STDIN_FILENO)) {
        std.debug.print("you werent piped to\n", .{});
        // TODO: get data from default command
    } else {
        std.debug.print("you got piped data\n", .{});
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
        const stdin = &stdin_reader.interface;

        var arena_impl: std.heap.ArenaAllocator = .init(gpa);
        defer arena_impl.deinit();

        const arena = arena_impl.allocator();

        var lines: std.ArrayList([]const u8) = .empty;

        while (try stdin.takeDelimiter('\n')) |line| {
            try lines.ensureUnusedCapacity(arena, 1);
            lines.appendAssumeCapacity(try arena.dupe(u8, line));
        }

        std.debug.print("got all input\n", .{});

        const args = try std.process.argsAlloc(gpa);
        defer std.process.argsFree(gpa, args);

        // const search_str = args[1];
        var read_buf: [1024]u8 = undefined;
        var write_buf: [1024]u8 = undefined;

        var tty: Tty = try .init(io, "/dev/tty", &read_buf, &write_buf);
        defer tty.deinit();

        var app: App = try .init(gpa, &tty, lines.items);
        defer app.deinit(gpa);

        try app.run(io, gpa);

        std.debug.print("goodbye\n", .{});
    }
}

const MATCH_MAX_LEN = 1024;
const score_min = -std.math.inf(f64);
const score_max = std.math.inf(f64);
fn match(haystack: []const u8, needle: []const u8) f64 {
    const m = haystack.len;
    const n = needle.len;

    if (m > MATCH_MAX_LEN or n > m) {
        return score_min;
    }

    if (n == m) {
        //Since this method can only be called with a haystack which
        //matches needle. If the lengths of the strings are equal the
        //strings themselves must also be equal (ignoring case).
        return score_max;
    }
}

fn hasMatch(haystack: []const u8, needle: []const u8) bool {
    var h = haystack;

    var search: [2]u8 = undefined;
    for (needle) |c| {
        search[0] = c;
        search[1] = std.ascii.toUpper(c);

        if (std.mem.findAny(u8, h, search[0..])) |idx| {
            h = haystack[idx + 1 ..];
            continue;
        }

        return false;
    }

    return true;
}

test hasMatch {
    try std.testing.expect(hasMatch("AxBxC", "abc"));
}
