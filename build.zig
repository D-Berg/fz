const std = @import("std");

const manifest = @import("build.zig.zon");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_simd = b.option(bool, "simd", "Use simd") orelse true;
    const strip = b.option(bool, "strip", "strip executable") orelse false;

    const enable_tracy = b.option(
        bool,
        "trace",
        "Enables tracy",
    ) orelse false;
    const tracy_allocation = b.option(
        bool,
        "tracy-allocation",
        "Include allocation information with Tracy data. Does nothing if -Dtracy is not provided",
    ) orelse false;
    const tracy_callstack = b.option(
        bool,
        "tracy-callstack",
        "Include callstack information with Tracy data. Does nothing if -Dtracy is not provided",
    ) orelse false;
    const tracy_callstack_depth: u32 = b.option(
        u32,
        "tracy-callstack-depth",
        "Declare callstack depth for Tracy data. Does nothing if -Dtracy_callstack is not provided",
    ) orelse 10;

    const build_options = b.addOptions();
    build_options.addOption(@TypeOf(use_simd), "use_simd", use_simd);
    build_options.addOption(usize, "MAX_SEARCH_LEN", 1024);
    build_options.addOption(bool, "enable_tracy", enable_tracy);
    build_options.addOption(u32, "tracy_callstack_depth", tracy_callstack_depth);
    build_options.addOption(bool, "enable_tracy_allocation", tracy_allocation);
    build_options.addOption(bool, "enable_tracy_callstack", tracy_callstack);

    const tracy_dep = b.dependency("tracy", .{});
    const tracy_lib = b.addLibrary(.{
        .name = "tracy",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });
    tracy_lib.root_module.addIncludePath(tracy_dep.path("public"));
    tracy_lib.root_module.addCSourceFile(.{
        .file = tracy_dep.path("public/TracyClient.cpp"),
    });

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

    if (enable_tracy) {
        exe.root_module.linkLibrary(tracy_lib);
        tracy_lib.root_module.addCMacro("TRACY_ENABLE", "1");
    }

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
