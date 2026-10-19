//! File helpers: compression and decompression with safe publication, and
//! what happens to the destination when a stream fails part way through.
//!
//! Run with: zig build run-file_compression

const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const dir = std.Io.Dir.cwd();

    const work = try tempDir(gpa, init.minimal.environ, "file_compression");
    defer gpa.free(work);
    const source = try join(gpa, work, "ledger.txt");
    defer gpa.free(source);
    const archive = try join(gpa, work, "ledger.txt.bz2");
    defer gpa.free(archive);
    const restored = try join(gpa, work, "ledger_restored.txt");
    defer gpa.free(restored);
    dir.createDirPath(io, work) catch {};

    // A sortable, repetitive ledger: exactly the shape bzip2 handles well.
    {
        var file = try dir.createFile(io, source, .{});
        defer file.close(io);
        var buffer: [16 * 1024]u8 = undefined;
        var writer = file.writerStreaming(io, &buffer);
        var line: usize = 0;
        while (line < 20_000) : (line += 1) {
            try writer.interface.print(
                "line {d:06}: transfer {d} of {d} units\n",
                .{ line, line % 512, 1 + line % 7 },
            );
        }
        try writer.interface.flush();
    }
    const before = try dir.statFile(io, source, .{});

    // compressFile stages its output beside the destination and publishes by
    // rename only after the whole run succeeded. An existing destination can
    // be replaced; failure keeps the old one untouched.
    try dir.writeFile(io, .{ .sub_path = archive, .data = "stale archive; must be replaced entirely" });
    try bzip2.compressFile(gpa, io, source, archive, .{ .level = 9 });
    const after = try dir.statFile(io, archive, .{});
    std.debug.print("{d} -> {d} bytes ({d:.2}x), staged and published atomically\n", .{
        before.size,
        after.size,
        @as(f64, @floatFromInt(before.size)) / @as(f64, @floatFromInt(after.size)),
    });

    // Decompress to a second file, and prove the content by hash rather than
    // by reading both into memory.
    try bzip2.decompressFile(gpa, io, archive, restored, .{ .max_output_size = 1 << 30 });
    const original_hash = try hashFile(io, dir, source);
    const restored_hash = try hashFile(io, dir, restored);
    try std.testing.expectEqual(original_hash, restored_hash);
    std.debug.print("decompress verified by hash\n", .{});

    // Now the failure path: truncate the archive mid-block, then ask for a
    // decompression into an existing destination. The call must fail, the
    // destination must still hold what it did, and no partial staging file
    // may be left behind.
    {
        const damaged = try join(gpa, work, "damaged.txt");
        defer gpa.free(damaged);
        const sentinel = "the good bytes that must survive a failed decode\n";
        try dir.writeFile(io, .{ .sub_path = damaged, .data = sentinel });

        const bytes = try dir.readFileAlloc(io, archive, gpa, .limited(1 << 20));
        defer gpa.free(bytes);

        const short_path = try join(gpa, work, "damaged.bz2");
        defer gpa.free(short_path);
        try dir.writeFile(io, .{ .sub_path = short_path, .data = bytes[0 .. bytes.len / 2] });

        const failed = bzip2.decompressFile(gpa, io, short_path, damaged, .{});
        if (failed) {
            return error.DecodeShouldHaveFailed;
        } else |err| {
            std.debug.print("truncated stream rejected as expected: {s}\n", .{@errorName(err)});
        }

        const kept = try dir.readFileAlloc(io, damaged, gpa, .limited(1 << 20));
        defer gpa.free(kept);
        try std.testing.expectEqualStrings(sentinel, kept);

        // The staging companion of damaged must not exist.
        const staging = try std.fmt.allocPrint(gpa, "{s}.bzip2-partial", .{damaged});
        defer gpa.free(staging);
        const staging_gone = dir.statFile(io, staging, .{});
        if (staging_gone) |_| {
            return error.StagingFileSurvived;
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        }
    }

    dir.deleteFile(io, source) catch {};
    dir.deleteFile(io, archive) catch {};
    dir.deleteFile(io, restored) catch {};
    dir.deleteTree(io, work) catch {};
    std.debug.print("failure path verified: destination preserved, staging cleaned\n", .{});
}

/// Hash a file through a fixed buffer.
fn hashFile(io: std.Io, dir: std.Io.Dir, path: []const u8) !u64 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);

    var hasher = std.hash.XxHash3.init(0);
    while (true) {
        if (reader.interface.buffered().len == 0) {
            reader.interface.fillMore() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
        }
        const chunk = reader.interface.buffered();
        if (chunk.len == 0) break;
        hasher.update(chunk);
        reader.interface.toss(chunk.len);
    }
    return hasher.final();
}

fn tempDir(gpa: std.mem.Allocator, environ: std.process.Environ, name: []const u8) ![]u8 {
    for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |key| {
        if (std.process.Environ.getAlloc(environ, gpa, key)) |base| {
            if (base.len != 0) {
                defer gpa.free(base);
                return std.fmt.allocPrint(gpa, "{s}/bzip2-example-{s}", .{ base, name });
            }
            gpa.free(base);
        } else |_| {}
    }
    // Fall back to a scratch dir beside the executable's working directory.
    // A bare "." cannot be deleted on POSIX (unlinkat rejects a trailing
    // "." component), so the name always has a real component.
    return std.fmt.allocPrint(gpa, "bzip2-example-{s}", .{name});
}

fn join(gpa: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, name });
}
