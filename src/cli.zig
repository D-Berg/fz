const std = @import("std");
const assert = std.debug.assert;

pub const Command = union(enum) {
    filter: []const u8,
    run: void,
};

const ArgIterator = struct {
    args: []const []const u8,
    idx: usize = 0,

    pub fn init(args: []const []const u8) ArgIterator {
        return .{
            .args = args,
        };
    }

    pub fn next(self: *ArgIterator) ?[]const u8 {
        if (self.idx == self.args.len) return null;
        const arg = self.args[self.idx];
        self.idx += 1;
        return arg;
    }

    pub fn skip(self: *ArgIterator) bool {
        if (self.idx == self.args.len) return false;
        self.idx += 1;
        return true;
    }
};

pub const Diagnostic = struct {
    gpa: std.mem.Allocator,
};

pub fn parse(args: []const []const u8, diag: ?*Diagnostic) !Command {
    var it: ArgIterator = .init(args);
    assert(it.skip());

    while (it.next()) |arg| {
        if (std.mem.eql(u8, "--filter", arg) or std.mem.eql(u8, "-f", arg)) {
            const search_str = it.next() orelse {
                if (diag) |d| _ = d; // TODO:
                return error.MissingArg;
            };
            return .{ .filter = search_str };
        }
    }

    return .run;
}
