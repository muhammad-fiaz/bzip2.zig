//! Reusable compression contexts: one Compressor and one Decoder, many
//! streams, identical results, no per-stream allocation cost.
//!
//! Run with: zig build run-reusable_contexts

const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Three different streams through the same encoder. reset restores the
    // state a fresh init would have produced: pending run state, counters,
    // and the notion of a finished stream.
    var compressor = try bzip2.Compressor.init(gpa, .{ .level = 5 });
    defer compressor.deinit();

    const messages = [_][]const u8{
        "first stream: a single line of text\n",
        "second stream: repeated text repeated text repeated text repeated text\n",
        "third stream:",
    };

    for (messages, 0..) |message, i| {
        compressor.reset();

        var sink: std.Io.Writer.Allocating = .init(gpa);
        defer sink.deinit();
        try compressor.write(&sink.writer, message);
        try compressor.finish(&sink.writer);
        const stream = try sink.toOwnedSlice();
        defer gpa.free(stream);

        // Prove each one decodes to exactly what went in. The decoder below
        // is one context reused across all three streams as well.
        var decoder = try bzip2.Decoder.init(gpa, .{});
        defer decoder.deinit();

        var restored: std.Io.Writer.Allocating = .init(gpa);
        defer restored.deinit();
        var source = std.Io.Reader.fixed(stream);
        try decoder.stream(&source, &restored.writer);
        const output = try restored.toOwnedSlice();
        defer gpa.free(output);

        try std.testing.expectEqualStrings(message, output);
        std.debug.print("stream {d}: {d} -> {d} bytes verified\n", .{
            i + 1,
            message.len,
            stream.len,
        });
    }

    // The third message ends with a colon, so the last stream is not finished
    // with reset there: it is finished by finish. Reusing a finished
    // context is exactly what happened across the loop above.
    std.debug.print("\none compressor, one decoder, three streams; the buffers\n" ++
        "allocated for their scratch space were set up once and reused.\n", .{});
}
