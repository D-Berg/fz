const std = @import("std");
const build_options = @import("build_options");
const util = @import("util.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Semaphore = @import("Semaphore.zig");
const WaitGroup = @import("WaitGroup.zig");
const tracy = @import("tracy.zig");

/// Float
pub const Score = f16;

pub const score_min = -std.math.inf(Score);
pub const score_max = std.math.inf(Score);

const MAX_SEARCH_LEN = build_options.MAX_SEARCH_LEN;

const SCORE_GAP_LEADING = -0.005;
const SCORE_GAP_TRAILING = -0.005;
const SCORE_GAP_INNER = -0.01;
const SCORE_MATCH_CONSECUTIVE = 1.0;
const SCORE_MATCH_SLASH = 0.9;
const SCORE_MATCH_WORD = 0.8;
const SCORE_MATCH_CAPITAL = 0.7;
const SCORE_MATCH_DOT = 0.6;

const Match = @This();

/// Not owned by this
original_str: []const u8,
idx: usize,
score: Score = score_min,
/// memory owned by match
lower_str: []const u8,
positions: []usize,
bonus: []Score,

pub fn init(gpa: Allocator, original_str: []const u8, idx: usize) !Match {
    const lower_str = try util.lowerStringAlloc(gpa, original_str);
    errdefer gpa.free(lower_str);

    const positions = try gpa.alloc(usize, original_str.len);
    errdefer gpa.free(positions);
    @memset(positions, 0);

    const bonus = try gpa.alloc(Score, original_str.len);
    calculateBonus(bonus, original_str);

    return .{
        .original_str = original_str,
        .idx = idx,
        .lower_str = lower_str,
        .positions = positions,
        .bonus = bonus,
    };
}

fn calculateBonus(bonus: []Score, haystack: []const u8) void {
    const tr = tracy.trace(@src());
    defer tr.end();

    assert(bonus.len == haystack.len);

    var last_char: u8 = '/';
    for (haystack, 0..) |c, i| {
        bonus[i] = switch (last_char) {
            '/' => SCORE_MATCH_SLASH,
            '-', '_', ' ' => SCORE_MATCH_WORD,
            '.' => SCORE_MATCH_DOT,
            'a'...'z' => if (std.ascii.isUpper(c))
                SCORE_MATCH_CAPITAL
            else
                0,
            else => 0,
        };

        last_char = c;
    }
}

pub const Work = struct {
    matches: []Match,
    needle: []const u8,
    wg: *WaitGroup,

    pub fn finnish(self: *const Work, io: Io) !void {
        try self.wg.done(io);
    }
};

/// Returns a slice into matches and update each match score
/// window is not allocated
pub fn updateMatches(
    io: Io,
    search_str: []const u8,
    matches: []Match,
    work_queue: *Io.Queue(Work),
) ![]const Match {
    const tr = tracy.trace(@src());
    defer tr.end();

    if (search_str.len == 0) {
        // restore to original
        Match.sortMatches(matches, Match.orderByIdx);
        for (matches) |*match| match.score = Match.score_min;
        return matches[0..];
    }

    var buf: [MAX_SEARCH_LEN]u8 = undefined;
    const needle = util.lowerString(&buf, search_str);

    // var sema: Semaphore = .{ .permits = 0 };
    var wg: WaitGroup = .init;
    try sendWork(io, &wg, needle, matches, work_queue);
    // try waitForWorkToFinnish(io, tasks, &wg);
    try wg.wait(io);

    Match.sortMatches(matches, Match.orderByScore);

    var len: usize = 0;
    for (matches) |match| {
        if (match.score <= 0) break;
        len += 1;
    }
    return matches[0..len];
}

fn sendWork(
    io: Io,
    wg: *WaitGroup,
    needle: []const u8,
    matches: []Match,
    work_queue: *Io.Queue(Work),
) !void {
    const tr = tracy.trace(@src());
    defer tr.end();

    const max_chunk_size: usize = matches.len / work_queue.capacity();
    var remaining = matches[0..];
    while (remaining.len > 0) {
        const chunk_size = if (remaining.len > max_chunk_size)
            max_chunk_size
        else
            remaining.len;

        const chunk = remaining[0..chunk_size];
        try work_queue.putOne(io, .{
            .matches = chunk[0..],
            .needle = needle,
            .wg = wg,
        });
        remaining = remaining[chunk_size..];

        try wg.add(io, 1);
    }
}

pub fn worker(io: Io, gpa: Allocator, worker_queue: *Io.Queue(Work), max_input_len: usize) void {
    const tr = tracy.trace(@src());
    defer tr.end();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    var d = Matrix(Score).init(arena, MAX_SEARCH_LEN, max_input_len) catch {
        std.log.err("Failed to allocate matrix", .{});
        return;
    };
    var m = Matrix(Score).init(arena, MAX_SEARCH_LEN, max_input_len) catch {
        std.log.err("Failed to allocate matrix", .{});
        return;
    };

    while (worker_queue.getOne(io)) |work| {
        defer work.finnish(io) catch {};

        // std.debug.print("worker got work of size: {}\n", .{work.matches.len});
        for (work.matches) |*match| {
            match.updateScore(work.needle, &d, &m);
        }
    } else |_| {
        tracy.message("worker got canceled");
    }
}

pub fn updateScore(self: *Match, needle: []const u8, d: *Matrix(Score), m: *Matrix(Score)) void {
    const tr = tracy.trace(@src());
    defer tr.end();

    // reset score
    self.score = score_min;

    if (hasMatch(self.original_str, needle)) {
        d.resize(needle.len, self.lower_str.len);
        m.resize(needle.len, self.lower_str.len);
        try self.matchPositions(needle, d, m);
    }
}

fn matchPositions(
    match: *Match,
    needle: []const u8,
    d: *Matrix(Score),
    m: *Matrix(Score),
) !void {
    const tr = tracy.trace(@src());
    defer tr.end();

    if (needle.len > match.lower_str.len) {
        match.score = score_min;
        return;
    } else if (needle.len == match.lower_str.len) {
        //Since this method can only be called with a haystack which
        //matches needle. If the lengths of the strings are equal the
        //strings themselves must also be equal (ignoring case).
        for (0..match.positions.len) |i| {
            match.positions[i] = i;
        }

        match.score = score_max;
        return;
    }

    match.updateMatrixes(needle, d, m);
    match.updatePositions(needle, d, m);

    match.score = m.row(needle.len - 1)[match.lower_str.len - 1];
}

fn updateMatrixes(match: *Match, needle: []const u8, d: *Matrix(Score), m: *Matrix(Score)) void {
    const tr = tracy.trace(@src());
    defer tr.end();

    for (needle, 0..) |n, i| {
        var prev_score = score_min;
        const gap_score: Score = if (i == needle.len - 1)
            SCORE_GAP_TRAILING
        else
            SCORE_GAP_INNER;

        const @"d[i]" = d.row(i);
        const @"m[i]" = m.row(i);

        // will only be accessed when i > 0
        const @"d[i - 1]" = if (i > 0) d.row(i - 1) else &.{};
        const @"m[i - 1]" = if (i > 0) m.row(i - 1) else &.{};

        for (match.lower_str, 0..) |h, j| {
            if (n == h) {
                var score = score_min;

                if (i == 0) {
                    score = (@as(Score, @floatFromInt(j)) * SCORE_GAP_LEADING) + match.bonus[j];
                } else if (j > 0) {
                    score = @max(
                        @"m[i - 1]"[j - 1] + match.bonus[j],
                        @"d[i - 1]"[j - 1] + SCORE_MATCH_CONSECUTIVE,
                    );
                }

                @"d[i]"[j] = score;
                prev_score = @max(score, prev_score + gap_score);
                @"m[i]"[j] = prev_score;
            } else {
                @"d[i]"[j] = score_min;
                prev_score += gap_score;
                @"m[i]"[j] = prev_score;
            }
        }
    }
}

/// Update Match.positions
fn updatePositions(match: *Match, needle: []const u8, d: *Matrix(Score), m: *Matrix(Score)) void {
    const tr = tracy.trace(@src());
    defer tr.end();

    var match_required: bool = false;
    var i = needle.len - 1;
    while (i > 0) : (i -= 1) {
        const @"d[i]" = d.row(i);
        const @"m[i]" = m.row(i);
        const @"d[i - 1]" = d.row(i - 1);

        var j = match.lower_str.len - 1;
        while (j > 0) : (j -= 1) {
            // There may be multiple paths which result in
            // the optimal weight.
            //
            // For simplicity, we will pick the first one
            // we encounter, the latest in the candidate
            // string.

            if ((@"d[i]"[j] != score_min) and
                (match_required or @"d[i]"[j] == @"m[i]"[j]))
            {
                // If this score was determined using
                // SCORE_MATCH_CONSECUTIVE, the
                // previous character MUST be a match
                match_required = (i != 0) and (j != 0) and
                    @"m[i]"[j] == @"d[i - 1]"[j - 1] + SCORE_MATCH_CONSECUTIVE;

                match.positions[i] = j;
                j -= 1;

                break;
            }
        }
    }
}

fn hasMatch(haystack: []const u8, needle: []const u8) bool {
    const tr = tracy.trace(@src());
    defer tr.end();

    var h = haystack;

    var search: [2]u8 = undefined;
    for (needle) |c| {
        search[0] = c;
        search[1] = std.ascii.toUpper(c);

        if (findAny(h, search[0..])) |idx| {
            h = h[idx + 1 ..];
            continue;
        }

        return false;
    }

    return true;
}

fn findAny(slice: []const u8, values: []const u8) ?usize {
    const tr = tracy.trace(@src());
    defer tr.end();

    if (slice.len == 0) return null;

    var remaining = slice[0..];
    var i: usize = 0;
    if (build_options.use_simd) if (std.simd.suggestVectorLength(u8)) |vec_len| {
        while (remaining.len >= vec_len) {
            const chunk_slice: @Vector(vec_len, u8) = remaining[0..vec_len].*;
            for (values) |value| {
                const vector_value: @Vector(vec_len, u8) = @splat(value);
                const matches = chunk_slice == vector_value;
                const maybe_idx = std.simd.firstTrue(matches);
                if (maybe_idx) |idx| return i + idx;
            }
            i += vec_len;
            remaining = remaining[vec_len..];
        }
    };

    // std.mem.findAny
    for (remaining) |c| {
        for (values) |value| {
            if (c == value) return i;
        }
        i += 1;
    }
    return null;
}

fn Matrix(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []T,
        rows: usize,
        cols: usize,

        fn init(gpa: Allocator, rows: usize, cols: usize) !Self {
            const data = try gpa.alloc(T, rows * cols);
            @memset(data, 0);
            return .{
                .data = data,
                .rows = rows,
                .cols = cols,
            };
        }

        fn resize(self: *Self, rows: usize, cols: usize) void {
            assert(rows * cols < self.data.len);
            self.rows = rows;
            self.cols = cols;
        }

        inline fn row(self: *Self, i: usize) []T {
            const tr = tracy.trace(@src());
            defer tr.end();

            const start = i * self.cols;
            const end = start + self.cols;
            return self.data[start..end];
        }
    };
}

/// ascending based on idx
pub fn orderByIdx(_: void, a: Match, b: Match) bool {
    return a.idx < b.idx;
}

/// descending based on score
pub fn orderByScore(_: void, a: Match, b: Match) bool {
    return a.score > b.score;
}

pub fn sortMatches(matches: []Match, orderBy: fn (void, Match, Match) bool) void {
    const tr = tracy.trace(@src());
    defer tr.end();
    std.mem.sort(Match, matches, {}, orderBy);
}

test hasMatch {
    try std.testing.expect(hasMatch("AxBxC", "abc"));
}

test "score" {
    try std.testing.expect(score_min < score_max);
}
