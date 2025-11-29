const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;

const Semaphore = @This();

mutex: Io.Mutex = .{ .state = .unlocked },
cond: Io.Condition = .{},
/// It is OK to initialize this field to any value.
permits: usize = 0,

pub fn wait(sem: *Semaphore, io: Io) error{Canceled}!void {
    try sem.mutex.lock(io);
    defer sem.mutex.unlock(io);

    while (sem.permits == 0)
        try sem.cond.wait(io, &sem.mutex);

    sem.permits -= 1;
    if (sem.permits > 0)
        sem.cond.signal(io);
}

pub fn post(sem: *Semaphore, io: Io) error{Canceled}!void {
    try sem.mutex.lock(io);
    defer sem.mutex.unlock(io);

    sem.permits += 1;
    sem.cond.signal(io);
}

test Semaphore {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const io = testing.io;

    const TestContext = struct {
        sem: *Semaphore,
        n: *i32,
        io: Io,
        fn worker(ctx: *@This()) !void {
            try ctx.sem.wait(io);
            ctx.n.* += 1;
            try ctx.sem.post(io);
        }
    };
    const num_threads = 3;
    var sem = Semaphore{ .permits = 1 };
    var threads: [num_threads]std.Thread = undefined;
    var n: i32 = 0;
    var ctx = TestContext{ .sem = &sem, .n = &n, .io = io };

    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, TestContext.worker, .{&ctx});
    for (threads) |t| t.join();
    try sem.wait(io);
    try testing.expect(n == num_threads);
}
