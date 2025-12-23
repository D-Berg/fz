const std = @import("std");
const build_options = @import("build_options");
const util = @import("util.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
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
positions: []bool,
bonus: []Score,

pub fn calculateBonus(bonus: []Score, haystack: []const u8) []Score {
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

    return bonus;
}

pub const Work = struct {
    match: *Match,
    needle: []const u8,
    result_queue: *Io.Queue(usize),
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
        for (matches) |*match| {
            match.score = Match.score_min;
            @memset(match.positions, false);
        }
        return matches[0..];
    }

    var buf: [MAX_SEARCH_LEN]u8 = undefined;
    const needle = util.lowerString(&buf, search_str);

    var result_queue_buf: [2048]usize = undefined;
    var result_queue: Io.Queue(usize) = .init(&result_queue_buf);

    var send_work = try io.concurrent(sendWork, .{ io, work_queue, &result_queue, needle, matches });
    defer send_work.cancel(io) catch {};

    var finnished: usize = 0;
    var result_buf: [64]usize = undefined;
    while (result_queue.get(io, &result_buf, 1)) |result_count| {
        for (result_buf[0..result_count]) |n| finnished += n;
        if (finnished >= matches.len) break;
    } else |err| return err;

    Match.sortMatches(matches, Match.orderByScore);

    var start: usize = 0;
    var len: usize = 0;
    for (matches) |match| {
        if (match.score <= 0) break;
        if (match.score == score_max) start += 1;
        len += 1;
    }
    assert(start <= len);
    return matches[start..len];
}

fn sendWork(
    io: Io,
    work_queue: *Io.Queue(Work),
    result_queue: *Io.Queue(usize),
    needle: []const u8,
    matches: []Match,
) !void {
    const tr = tracy.trace(@src());
    defer tr.end();
    for (0..matches.len) |i| {
        try work_queue.putOne(io, .{
            .match = &matches[i],
            .needle = needle,
            .result_queue = result_queue,
        });
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

    var work_buf: [256]Work = undefined;
    while (worker_queue.get(io, &work_buf, 1)) |n| {
        for (work_buf[0..n]) |work| {
            work.match.updateScore(work.needle, &d, &m);
        }
        work_buf[0].result_queue.putOne(io, n) catch return;
    } else |_| {
        tracy.message("worker got canceled");
    }
}

pub fn updateScore(self: *Match, needle: []const u8, d: *Matrix(Score), m: *Matrix(Score)) void {
    const tr = tracy.trace(@src());
    defer tr.end();

    // reset score
    self.score = score_min;
    @memset(self.positions, false);

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

    if (needle.len > match.lower_str.len or match.lower_str.len > MAX_SEARCH_LEN) {
        match.score = score_min;
        return;
    } else if (needle.len == match.lower_str.len) {
        //Since this method can only be called with a haystack which
        //matches needle. If the lengths of the strings are equal the
        //strings themselves must also be equal (ignoring case).
        for (0..match.positions.len) |i| {
            match.positions[i] = true;
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

    match.updateRow(0, needle, d.row(0), m.row(0), d.row(0), d.row(0));
    for (1..needle.len) |i| {
        match.updateRow(i, needle, d.row(i), m.row(i), d.row(i - 1), d.row(i - 1));
    }
}

fn updateRow(
    match: *Match,
    i: usize,
    needle: []const u8,
    curr_d: []Score,
    curr_m: []Score,
    last_d: []Score,
    last_m: []Score,
) void {
    const haystack = match.lower_str;

    var prev_score: Score = score_min;
    var prev_d: Score = score_min;
    var prev_m: Score = score_min;
    const gap_score: Score = if (i == needle.len - 1)
        SCORE_GAP_TRAILING
    else
        SCORE_GAP_INNER;

    for (0..haystack.len) |j| {
        if (needle[i] == haystack[j]) {
            var score = score_min;
            if (i == 0) {
                score = (@as(Score, @floatFromInt(j)) * SCORE_GAP_LEADING) + match.bonus[j];
            } else if (j > 0) {
                score = @max(
                    prev_m + match.bonus[j],
                    prev_d + SCORE_MATCH_CONSECUTIVE,
                );
            }

            prev_d = last_d[j];
            prev_m = last_m[j];
            curr_d[j] = score;
            prev_score = @max(score, prev_score + gap_score);
            curr_m[j] = prev_score;
        } else {
            prev_d = last_d[j];
            prev_m = last_m[j];
            curr_d[j] = score_min;
            prev_score += gap_score;
            curr_m[j] = prev_score;
        }
    }
}

/// Update Match.positions
fn updatePositions(match: *Match, needle: []const u8, d: *Matrix(Score), m: *Matrix(Score)) void {
    const tr = tracy.trace(@src());
    defer tr.end();

    var match_required: bool = false;
    var i = needle.len;
    while (i > 0) {
        i -= 1;
        const @"d[i]" = d.row(i);
        const @"m[i]" = m.row(i);
        const @"d[i - 1]" = if (i > 0) d.row(i - 1) else &.{};

        var j = match.lower_str.len;
        while (j > 0) {
            j -= 1;
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
                if (i > 0 and j > 0) {
                    match_required = @"m[i]"[j] == @"d[i - 1]"[j - 1] + SCORE_MATCH_CONSECUTIVE;
                }

                match.positions[j] = true;

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
            h = haystack[idx + 1 ..];
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
        const Chunk = @Vector(vec_len, u8);
        while (remaining.len >= vec_len) {
            const chunk_slice: Chunk = remaining[0..vec_len].*;
            for (values) |value| {
                const vector_value: Chunk = @splat(value);
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

        /// Change rows and cols size
        /// doesnt change data buffer
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
    std.mem.sortUnstable(Match, matches, {}, orderBy);
}

test hasMatch {
    try std.testing.expect(hasMatch("AxBxC", "abc"));
}

test "score" {
    try std.testing.expect(score_min < score_max);
}
