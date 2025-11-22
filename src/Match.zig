const std = @import("std");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const score_min = -std.math.inf(f64);
pub const score_max = std.math.inf(f64);

const Match = @This();

original_str: []const u8,
lower_str: []const u8,
pattern: []bool,
idx: usize,
score: f64,

pub fn updateScore(self: *Match, needle: []const u8) void {
    const haystack = self.lower_str;

    self.score = score_min;

    if (hasMatch(haystack, needle)) {
        if (std.mem.find(u8, haystack, needle)) |_| {
            self.score = score_max;
        }
    }
}

fn match(haystack: []const u8, needle: []const u8) f64 {
    const m = haystack.len;
    const n = needle.len;

    if (n > m) {
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

test "score" {
    try std.testing.expect(score_min < score_max);
}
