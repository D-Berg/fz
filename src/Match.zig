const std = @import("std");
const build_options = @import("build_options");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const score_min = -std.math.inf(f64);
pub const score_max = std.math.inf(f64);

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
score: f64 = score_min,
/// memory owned by match
lower_str: []const u8,
positions: []usize,
bonus: []f64,

pub fn init(gpa: Allocator, original_str: []const u8, idx: usize) !Match {
    const lower_str = try util.lowerStringAlloc(gpa, original_str);
    errdefer gpa.free(lower_str);

    const positions = try gpa.alloc(usize, original_str.len);
    errdefer gpa.free(positions);
    @memset(positions, 0);

    const bonus = try gpa.alloc(f64, original_str.len);
    calculateBonus(bonus, original_str);

    return .{
        .original_str = original_str,
        .idx = idx,
        .lower_str = lower_str,
        .positions = positions,
        .bonus = bonus,
    };
}

fn calculateBonus(bonus: []f64, haystack: []const u8) void {
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

pub fn updateScore(self: *Match, gpa: Allocator, needle: []const u8) !void {

    // reset score
    self.score = score_min;

    @memset(self.positions, 0);

    if (hasMatch(self.original_str, needle)) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        // if (std.mem.find(u8, self.lower_str, needle)) |_| self.score = score_max;

        try self.matchPositions(arena.allocator(), needle);
    }
}

fn matchPositions(match: *Match, arena: Allocator, needle: []const u8) !void {
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
    var d = try Matrix(f64).init(arena, needle.len, match.lower_str.len);
    var m = try Matrix(f64).init(arena, needle.len, match.lower_str.len);

    for (needle, 0..) |n, i| {
        var prev_score = score_min;
        const gap_score: f64 = if (i == needle.len - 1)
            SCORE_GAP_TRAILING
        else
            SCORE_GAP_INNER;

        for (match.lower_str, 0..) |h, j| {
            if (n == h) {
                var score = score_min;

                if (i == 0) {
                    score = (@as(f64, @floatFromInt(j)) * SCORE_GAP_LEADING) + match.bonus[j];
                } else if (j > 0) {
                    score = @max(
                        m.getRow(i - 1)[j - 1] + match.bonus[j],
                        d.getRow(i - 1)[j - 1] + SCORE_MATCH_CONSECUTIVE,
                    );
                }

                d.getRow(i)[j] = score;
                prev_score = @max(score, prev_score + gap_score);
                m.getRow(i)[j] = prev_score;
            } else {
                d.getRow(i)[j] = score_min;
                prev_score += gap_score;
                m.getRow(i)[j] = prev_score;
            }
        }
    }

    var match_required: bool = false;
    var i = needle.len - 1;
    while (i > 0) : (i -= 1) {
        var j = match.lower_str.len - 1;
        while (j > 0) : (j -= 1) {
            // There may be multiple paths which result in
            // the optimal weight.
            //
            // For simplicity, we will pick the first one
            // we encounter, the latest in the candidate
            // string.

            if ((d.getRow(i)[j] != score_min) and
                (match_required or d.getRow(i)[j] == m.getRow(i)[j]))
            {
                // If this score was determined using
                // SCORE_MATCH_CONSECUTIVE, the
                // previous character MUST be a match
                match_required = (i != 0) and (j != 0) and
                    m.getRow(i)[j] == d.getRow(i - 1)[j - 1] + SCORE_MATCH_CONSECUTIVE;

                match.positions[i] = j;
                j -= 1;

                break;
            }
        }
    }

    match.score = m.getVal(needle.len - 1, match.lower_str.len - 1);
}

fn hasMatch(haystack: []const u8, needle: []const u8) bool {
    var h = haystack;

    var search: [2]u8 = undefined;
    for (needle) |c| {
        search[0] = c;
        search[1] = std.ascii.toUpper(c);

        // TODO: simd
        if (std.mem.findAny(u8, h, search[0..])) |idx| {
            h = haystack[idx + 1 ..];
            continue;
        }

        return false;
    }

    return true;
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

        fn getRow(self: *Self, i: usize) []T {
            const start = i * self.cols;
            const end = (i + 1) * self.cols;
            return self.data[start..end];
        }

        fn getVal(self: *Self, i: usize, j: usize) T {
            return self.data[i * self.cols + j];
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
    std.mem.sort(Match, matches, {}, orderBy);
}

test hasMatch {
    try std.testing.expect(hasMatch("AxBxC", "abc"));
}

test "score" {
    try std.testing.expect(score_min < score_max);
}
