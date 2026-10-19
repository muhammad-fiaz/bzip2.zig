const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bzip2_mod = b.addModule("bzip2", .{
        .root_source_file = b.path("src/bzip2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    const lib = b.addLibrary(.{
        .name = "bzip2",
        .root_module = bzip2_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Tests live at the bottom of the module they cover, so the whole suite is
    // one artifact built from the library root.
    const tests = b.addTest(.{ .root_module = bzip2_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);

    const docs_step = b.step("docs", "Generate documentation");
    const docs = b.addTest(.{ .root_module = bzip2_mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    // Every example imports the library the same way, so the loop needs no
    // per-example wiring.
    const examples = [_]struct { name: []const u8, file: []const u8 }{
        .{ .name = "basic_compression", .file = "examples/basic_compression.zig" },
        .{ .name = "compression_levels", .file = "examples/compression_levels.zig" },
        .{ .name = "reusable_contexts", .file = "examples/reusable_contexts.zig" },
        .{ .name = "caller_buffers", .file = "examples/caller_buffers.zig" },
        .{ .name = "chunked_input", .file = "examples/chunked_input.zig" },
        .{ .name = "streaming_pipelines", .file = "examples/streaming_pipelines.zig" },
        .{ .name = "file_compression", .file = "examples/file_compression.zig" },
        .{ .name = "large_file", .file = "examples/large_file.zig" },
        .{ .name = "decoder_semantics", .file = "examples/decoder_semantics.zig" },
        .{ .name = "custom_allocator", .file = "examples/custom_allocator.zig" },
    };

    const run_all = b.step("run-all-examples", "Run all examples");
    const check_step = b.step("check", "Compile the library, tests and examples");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&tests.step);

    inline for (examples) |example| {
        const run_step = b.step(
            "run-" ++ example.name,
            "Run " ++ example.name ++ " example",
        );

        const exe = b.addExecutable(.{
            .name = "example-" ++ example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.file),
                .target = target,
                .optimize = optimize,
                .link_libc = false,
                .imports = &.{
                    .{ .name = "bzip2", .module = bzip2_mod },
                },
            }),
        });
        check_step.dependOn(&exe.step);

        const run_exe = b.addRunArtifact(exe);
        run_exe.has_side_effects = true;
        run_step.dependOn(&run_exe.step);
        run_all.dependOn(&run_exe.step);
        run_exe.step.dependOn(&lib.step);
    }
}
