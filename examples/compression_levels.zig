//! Every compression level at once: what each buys, what each costs, and
//! proof that all nine round trip.
//!
//! Run with: zig build run-compression_levels

const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Two megabytes of mixed content: structured runs for the transform to
    // find, embedded binary for the symbol alphabet, and one record per
    // block for level 1's small blocks.
    const total: usize = 2 * 1024 * 1024;
    var input = try std.ArrayList(u8).initCapacity(gpa, total);
    defer input.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(2_625_021_453);
    const random = prng.random();
    const head = "order form: quantity {d} units at {d}.{d:02}\n";
    while (input.items.len < total) {
        var line: [96]u8 = undefined;
        const rendered = try std.fmt.bufPrint(
            &line,
            head,
            .{ random.uintLessThan(u32, 5000), random.uintLessThan(u32, 99), random.uintLessThan(u32, 100) },
        );
        try input.appendSlice(gpa, rendered);
        var blob: [32]u8 = undefined;
        random.bytes(&blob);
        try input.appendSlice(gpa, &blob);
        try input.appendSlice(gpa, "\n");
    }
    try input.resize(gpa, total);

    // Sizing the worst case before compressing is the format's stored-mode
    // absence made honest: nothing can blow up past this.
    const bound = try bzip2.maxCompressedSize(input.items.len, 9);
    std.debug.print("input {d} bytes; worst-case bound {d} bytes\n\n", .{ input.items.len, bound });

    std.debug.print("level  time-ms    bytes      ratio      verifies  block-kB\n", .{});
    inline for (1..10) |level| {
        const compressed = try bzip2.compress(gpa, input.items, .{ .level = level });
        defer gpa.free(compressed);

        const started = std.Io.Clock.now(.awake, io);
        const restored = try bzip2.decompress(gpa, compressed, .{});
        defer gpa.free(restored);
        const us = started.durationTo(std.Io.Clock.now(.awake, io)).toNanoseconds();

        // Every level has to produce the input byte for byte.
        try std.testing.expectEqualSlices(u8, input.items, restored);

        // Larger levels use larger blocks; ask the header rather than assume.
        const block = try bzip2.blockSizeOfStream(compressed);

        std.debug.print("{d:3}    {d:7}    {d:8}    {d:6.2}x      yes       {d}\n", .{
            level,
            @divTrunc(us, std.time.ns_per_ms),
            compressed.len,
            @as(f64, @floatFromInt(input.items.len)) / @as(f64, @floatFromInt(compressed.len)),
            @as(u8, @intCast(block / 100_000)),
        });
    }
    std.debug.print(
        "\nratios differ at most slightly across levels here; the block size is\n" ++
            "the real difference. Larger blocks cost level * 100 kB of scratch RAM\n" ++
            "while compressing and decoding, regardless of input size.\n",
        .{},
    );
}
