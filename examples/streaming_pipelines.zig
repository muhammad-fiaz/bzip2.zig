//! Compress multi-block, then feed the result straight into the decompressor,
//! streaming API style: a bounded-memory pipeline in both directions.
//!
//! Run with: zig build run-streaming_pipelines

const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // 2.5 MB of mostly-repeating text or an input of any size, processed in
    // constant memory in each direction.
    const total: usize = 2_500_000;
    var input = try std.ArrayList(u8).initCapacity(gpa, total);
    defer input.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(9_199);
    const random = prng.random();
    while (input.items.len < total) {
        try input.appendSlice(gpa, "the quick brown fox jumps over the lazy dog 0123456789\n");
        if (random.uintLessThan(u32, 4) == 0) {
            var blob: [64]u8 = undefined;
            random.bytes(&blob);
            try input.appendSlice(gpa, &blob);
        }
    }
    try input.resize(gpa, total);

    // Compression through the streaming entry point. input is wrapped in a
    // fixed reader; the library pulls what it needs when it needs it. Memory
    // stays at one level * 100 kB block plus scratch, whatever the size.
    var compressed: std.Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var source = std.Io.Reader.fixed(input.items);
    try bzip2.compressStream(gpa, &source, &compressed.writer, .{ .level = 1 });
    const stream = try compressed.toOwnedSlice();
    defer gpa.free(stream);

    const stats_probe = try bzip2.blockSizeOfStream(stream);
    std.debug.print("input:       {d} bytes\n", .{input.items.len});
    std.debug.print("compressed:  {d} bytes at level 1 ({d:.2}x)\n", .{
        stream.len,
        @as(f64, @floatFromInt(input.items.len)) / @as(f64, @floatFromInt(stream.len)),
    });
    std.debug.print("block size:  {d} bytes (so {d} blocks were framed)\n", .{
        stats_probe,
        @divTrunc(input.items.len + stats_probe - 20, @max(stats_probe - 19, 1)),
    });

    // Decompress through the streaming entry point, into an allocating sink.
    var restored: std.Io.Writer.Allocating = .init(gpa);
    defer restored.deinit();
    var archive = std.Io.Reader.fixed(stream);
    try bzip2.decompressStream(gpa, &archive, &restored.writer, .{});
    const output = try restored.toOwnedSlice();
    defer gpa.free(output);

    // Verify: the stream decoder checked every block CRC and the stream CRC;
    // this checks the pipeline by value.
    try std.testing.expectEqualSlices(u8, input.items, output);
    std.debug.print("round trip verified: {d} bytes identical\n", .{output.len});
}
