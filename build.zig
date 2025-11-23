const std = @import("std");

const manifest = @import("build.zig.zon");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_simd = b.option(bool, "simd", "Use simd") orelse true;
    const strip = b.option(bool, "strip", "strip executable") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(@TypeOf(use_simd), "use_simd", use_simd);
    build_options.addOption(usize, "MAX_SEARCH_LEN", 1024);

    const exe = b.addExecutable(.{
        .name = @tagName(manifest.name),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .link_libc = false,
            .strip = strip,
            .unwind_tables = if (strip) .none else null,
        }),
    });

    exe.root_module.addOptions("build_options", build_options);

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "run executable");
    run_step.dependOn(&run_exe.step);

    if (b.args) |args| run_exe.addArgs(args);

    const test_exe = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_test_exe = b.addRunArtifact(test_exe);
    run_test_exe.step.dependOn(&test_exe.step);

    const run_test_step = b.step("test", "run unit tests");
    run_test_step.dependOn(&run_test_exe.step);
}
