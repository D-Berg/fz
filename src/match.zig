const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const MATCH_MAX_LEN = std.posix.PATH_MAX;
const score_min = -std.math.inf(f64);
const score_max = std.math.inf(f64);

const Match = struct {
    haystack_lower: []const u8,
    needle_lower: []const u8,
    match_bonus: []u8,

    pub fn init(gpa: Allocator, haystack: []const u8, needle: []const u8) !Match {
        _ = gpa;
        _ = haystack;
        _ = needle;
    }

    // pub fn findPositions(

};

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
