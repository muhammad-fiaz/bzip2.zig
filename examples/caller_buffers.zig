//! Caller-provided output buffers: size one up front with
//! maxCompressedSize, retry when the guess is too small, and decompress
//! straight into a caller-sized buffer.
//!
//! Run with: zig build run-caller_buffers

const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // High-entropy input: nearly incompressible, the hard case for a buffer
    // guesser, because the output is slightly LARGER than the input.
    var input: [50_000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x2452_9a11);
    prng.random().bytes(&input);

    const first_guess: usize = 40_000;
    std.debug.print("input is {d} entropy-heavy bytes; first buffer guess {d}\n", .{
        input.len,
        first_guess,
    });

    // Compress into a fixed buffer allocated by the caller.
    const encoded = try compressWithRetry(gpa, &input, first_guess);
    defer gpa.free(encoded.buffer);
    std.debug.print("accepted a {d} byte cap; used {d} bytes\n", .{ encoded.capacity, encoded.len });

    // Decompress into a caller-sized buffer as well. The exact size is known
    // here because we own the input; at the API boundary, decompression
    // either fits in the space given (writer fixed) or fails with
    // error.WriteFailed instead of reallocating.
    const out = try gpa.alloc(u8, input.len);
    defer gpa.free(out);

    var restored = std.Io.Writer.fixed(out);
    var decoder = try bzip2.Decoder.init(gpa, .{});
    defer decoder.deinit();
    var source = std.Io.Reader.fixed(encoded.buffer[0..encoded.len]);
    try decoder.stream(&source, &restored);

    try std.testing.expectEqualSlices(u8, &input, out[0..restored.end]);
    std.debug.print("decompressed {d} bytes into a caller buffer; verified\n", .{restored.end});
}

/// The compressor never allocates output storage; the sink does. This wraps
/// the retry pattern: try a guess, and when the writer overflows, start over
/// with a bigger buffer. Growing is cheap here because compression restarts
/// from a clean state, not from mid-stream.
fn compressWithRetry(
    gpa: std.mem.Allocator,
    input: []const u8,
    first_guess: usize,
) !struct { buffer: []u8, len: usize, capacity: usize } {
    var cap = first_guess;
    while (true) {
        const out = gpa.alloc(u8, cap) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer gpa.free(out);

        var writer = std.Io.Writer.fixed(out);
        var compressor = bzip2.Compressor.init(gpa, .{ .level = 9 }) catch |err| {
            gpa.free(out);
            return err;
        };
        defer compressor.deinit();

        const result = writeStream(&compressor, &writer, input);
        if (result) {
            return .{ .buffer = out, .len = writer.end, .capacity = cap };
        } else |err| switch (err) {
            error.WriteFailed => {
                gpa.free(out);
                // Not smaller than the format bound, and not unbounded.
                cap = @max(cap * 2, @min(bzip2.maxCompressedSize(input.len, 9) catch return error.OutOfMemory, cap * 4));
                std.debug.print("  buffer too small; retrying with {d}\n", .{cap});
            },
            else => {
                gpa.free(out);
                return err;
            },
        }
    }
}

/// Write one whole stream; the error only distinguishes buffer overflow.
fn writeStream(compressor: *bzip2.Compressor, writer: *std.Io.Writer, input: []const u8) !void {
    try compressor.write(writer, input);
    try compressor.finish(writer);
}
