//! One-shot compression and decompression in memory, with verification.
//!
//! Run with: zig build run-basic_compression

const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // One call to compress, one call back. The buffers that come out are
    // owned by the caller and sized exactly to the result.
    const text = "The quick brown fox jumps over the lazy dog. ";
    var input: [text.len * 24]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = text[i % text.len];

    const compressed = try bzip2.compress(gpa, &input, .{});
    defer gpa.free(compressed);

    std.debug.print("input:      {d} bytes\n", .{input.len});
    std.debug.print("compressed: {d} bytes ({d:.2}x)\n", .{
        compressed.len,
        @as(f64, @floatFromInt(input.len)) / @as(f64, @floatFromInt(compressed.len)),
    });

    // The stream header records the block size, so it can be inspected
    // without decoding anything. The default level is 9: a 900 kB block.
    std.debug.print("block size: {d} bytes\n", .{try bzip2.blockSizeOfStream(compressed)});

    const restored = try bzip2.decompress(gpa, compressed, .{});
    defer gpa.free(restored);

    // Verify the round trip by value, not by trust: decompression already
    // checked both the block CRC and the whole-stream CRC, and this compares
    // the result against the original bytes.
    try std.testing.expectEqualSlices(u8, &input, restored);
    std.debug.print("round trip verified: {d} bytes identical\n", .{restored.len});
}
