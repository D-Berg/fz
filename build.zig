const std = @import("std");
const log = std.log.scoped(.build);

const manifest = @import("build.zig.zon");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = getVersion(b) catch |err| {
        std.debug.panic("Failed to get version: error: {t}", .{err});
    };

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
    build_options.addOption([]const u8, "version", version);

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

// https://codeberg.org/ziglang/zig/src/branch/master/build.zig
fn getVersion(b: *std.Build) ![]const u8 {
    const version = manifest.version;
    var code: u8 = undefined;
    const git_describe_untrimmed = b.runAllowFail(&[_][]const u8{
        "git", "-C", b.build_root.path orelse ".",
        "--git-dir", ".git", // affected by the -C argument
        "describe", "--match",    "*.*.*", //
        "--tags",   "--abbrev=8",
    }, &code, .Ignore) catch {
        return version;
    };

    const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");
    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            // Tagged release version (e.g. 0.10.0).
            if (!std.mem.eql(u8, git_describe, version)) {
                std.debug.panic(
                    "Fz version '{s}' does not match Git tag '{s}'\n",
                    .{ version, git_describe },
                );
            }
            return version;
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = it.first();
            const commit_height = it.next().?;
            const commit_id = it.next().?;

            const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
            var sem_ver = try std.SemanticVersion.parse(version);
            if (sem_ver.order(ancestor_ver) == .lt) {
                std.debug.panic(
                    "version '{f}' must be greater or equal to tagged ancestor '{f}'\n",
                    .{ sem_ver, ancestor_ver },
                );
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                log.err("Unexpected `git describe` output: {s}\n", .{git_describe});
                return version;
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version, commit_height, commit_id[1..] });
        },
        else => {
            log.err("Unexpected `git describe` output: {s}\n", .{git_describe});
            return version;
        },
    }
}
