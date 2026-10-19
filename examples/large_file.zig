//! A large file through file-streaming helpers: constant memory, measured
//! throughput, and hash-verified content.
//!
//! Run with: zig build run-large_file

const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const dir = std.Io.Dir.cwd();

    const work = try tempDir(gpa, init.minimal.environ, "large_file");
    defer gpa.free(work);
    const source = try join(gpa, work, "large_source.txt");
    defer gpa.free(source);
    const archive = try join(gpa, work, "large_source.txt.bz2");
    defer gpa.free(archive);
    const restored = try join(gpa, work, "large_restored.txt");
    defer gpa.free(restored);
    dir.createDirPath(io, work) catch {};

    // 16 MiB of alternating compressible and incompressible regions. No
    // stage of the round trip ever holds more than one 900 kB block plus
    // two 64 kB buffers, whatever this number grows to.
    const total: u64 = 16 * 1024 * 1024;
    const made = try makeSource(io, dir, source, total);

    const compress_started = std.Io.Clock.now(.awake, io);
    try bzip2.compressFile(gpa, io, source, archive, .{ .level = 9 });
    const compress_us = compress_started.durationTo(std.Io.Clock.now(.awake, io)).toNanoseconds();

    const archive_stat = try dir.statFile(io, archive, .{});

    const decompress_started = std.Io.Clock.now(.awake, io);
    try bzip2.decompressFile(gpa, io, archive, restored, .{ .max_output_size = @intCast(total) });
    const decompress_us = decompress_started.durationTo(std.Io.Clock.now(.awake, io)).toNanoseconds();

    const restored_stat = try dir.statFile(io, restored, .{});

    // Size check first, then content check by streaming hash. Both files
    // would collapse any load-it-all comparison for large inputs.
    try std.testing.expectEqual(total, restored_stat.size);
    const original_hash = try hashFile(io, dir, source);
    const restored_hash = try hashFile(io, dir, restored);
    try std.testing.expectEqual(original_hash, restored_hash);
    std.debug.print("size and hash verified over {d} bytes\n", .{total});

    std.debug.print("\n", .{});
    std.debug.print("input:       {d} bytes\n", .{made});
    std.debug.print("compressed:  {d} bytes ({d:.2}x)\n", .{
        archive_stat.size,
        @as(f64, @floatFromInt(made)) / @as(f64, @floatFromInt(archive_stat.size)),
    });
    std.debug.print("compress:    {d}ms ({d:.1} MB/s)\n", .{
        @divTrunc(compress_us, std.time.ns_per_ms),
        mebibytesPerSecond(made, compress_us),
    });
    std.debug.print("decompress:  {d}ms ({d:.1} MB/s)\n", .{
        @divTrunc(decompress_us, std.time.ns_per_ms),
        mebibytesPerSecond(made, decompress_us),
    });
    std.debug.print("\n", .{});
    std.debug.print("peak memory was one block of scratch plus two 64 kB buffers\n", .{});

    dir.deleteFile(io, source) catch {};
    dir.deleteFile(io, archive) catch {};
    dir.deleteFile(io, restored) catch {};
    dir.deleteTree(io, work) catch {};
}

fn mebibytesPerSecond(bytes: u64, nanoseconds: i96) f64 {
    const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    const seconds = @as(f64, @floatFromInt(nanoseconds)) / 1_000_000_000.0;
    return mb / seconds;
}

/// Write total bytes with a mix of compressible and incompressible
/// regions, sized so at least one real block boundary is crossed at level 9.
fn makeSource(io: std.Io, dir: std.Io.Dir, path: []const u8, total: u64) !u64 {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);

    // Two buffers on purpose: one holds the data being written, the other is
    // the writer's interface buffer. Sharing one would alias the copies.
    var data: [64 * 1024]u8 = undefined;
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);

    var written: u64 = 0;
    var offset: u64 = 0;
    var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    const random = prng.random();
    const prose = "large file handling never buffers the whole thing. ";

    while (written < total) {
        const take: usize = @intCast(@min(total - written, data.len));
        // Offsets kept in usize so the arithmetic is correct on 32-bit
        // targets as well.
        const start: usize = @intCast(offset);
        const region = start / (4 * 1024 * 1024);
        for (data[0..take], 0..) |*byte, i| {
            byte.* = switch (region) {
                0, 2 => prose[(start + i) % prose.len],
                1 => random.int(u8),
                else => @truncate(start + i),
            };
        }
        try writer.interface.writeAll(data[0..take]);
        written += take;
        offset += take;
    }
    try writer.interface.flush();
    return written;
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
