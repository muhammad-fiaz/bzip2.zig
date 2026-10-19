//! Feeding a compressor in arbitrary chunk sizes, including one-byte trickles,
//! then proving that chunking has no effect on the produced stream at all.
//!
//! Run with: zig build run-chunked_input

const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Mixed content with long runs: chunk boundaries will fall inside runs,
    // inside blocks, and at the edges of the pending-run state, all of which
    // the compressor has to reconcile to produce identical bytes.
    const total: usize = 40_000;
    var input: [total]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7_717_531);
    const random = prng.random();
    var position: usize = 0;
    while (position < total) {
        const span = random.uintLessThan(usize, 500);
        const take = @min(span, total - position);
        const runner: u8 = if (random.boolean())
            @truncate(position % 10 + '0')
        else
            random.int(u8);
        for (input[position .. position + take]) |*byte| byte.* = runner;
        position += take;
    }

    // Reference: compress in one call.
    const reference = try bzip2.compress(gpa, &input, .{ .level = 6 });
    defer gpa.free(reference);

    // The same bytes, written in irregular chunks. The starts are chosen so
    // that some boundaries split a run and others fall right after one;
    // chunk lengths stay far from any block-size relation on purpose.
    const starts = [_]usize{ 0, 1, 2, 9, 122, 1_137, 1_138, 9_999 };

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var compressor = try bzip2.Compressor.init(gpa, .{ .level = 6 });
    defer compressor.deinit();

    var chunks: usize = 0;
    var last = starts[0];
    for (starts[1..]) |start| {
        const take = @min(start, total) - last;
        try compressor.write(&sink.writer, input[last .. last + take]);
        last = last + take;
        chunks += 1;
    }
    try compressor.write(&sink.writer, input[last..]);
    chunks += 1;
    try compressor.finish(&sink.writer);

    const chunked = try sink.toOwnedSlice();
    defer gpa.free(chunked);

    // The claim this example exists to hold: chunking changes nothing in the
    // wire format. One-shot and chunked output are compared by value.
    try std.testing.expectEqualSlices(u8, reference, chunked);
    std.debug.print("one-shot: {d} bytes; chunked in {d} writes: {d} bytes\n", .{
        reference.len,
        chunks + 1,
        chunked.len,
    });
    std.debug.print("verified: the two streams are byte for byte identical\n", .{});
}
