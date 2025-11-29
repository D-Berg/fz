const std = @import("std");
const tracy = @import("tracy.zig");

const Io = std.Io;
const Mutex = Io.Mutex;
const Condition = Io.Condition;

const WaitGroup = @This();

mutex: Mutex,
cond: Condition,
counter: usize,

pub const init = WaitGroup{
    .mutex = .init,
    .cond = .{ .state = 0 },
    .counter = 0,
};

pub fn add(wg: *WaitGroup, io: Io, n: usize) error{Canceled}!void {
    const tr = tracy.trace(@src());
    defer tr.end();

    try wg.mutex.lock(io);
    defer wg.mutex.unlock(io);

    wg.counter += n;
}

pub fn done(wg: *WaitGroup, io: Io) error{Canceled}!void {
    const tr = tracy.trace(@src());
    defer tr.end();

    try wg.mutex.lock(io);
    defer wg.mutex.unlock(io);

    wg.counter -= 1;
    if (wg.counter == 0) {
        wg.cond.broadcast(io);
    }
}

pub fn wait(wg: *WaitGroup, io: Io) error{Canceled}!void {
    const tr = tracy.trace(@src());
    defer tr.end();

    try wg.mutex.lock(io);
    defer wg.mutex.unlock(io);

    while (wg.counter != 0) {
        try wg.cond.wait(io, &wg.mutex);
    }
    // std.debug.print("finished waiting\n", .{});
}
