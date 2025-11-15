const std = @import("std");

const manifest = @import("build.zig.zon");
pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = @tagName(manifest.name),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "run executable");
    run_step.dependOn(&run_exe.step);

    if (b.args) |args| run_exe.addArgs(args);
}
