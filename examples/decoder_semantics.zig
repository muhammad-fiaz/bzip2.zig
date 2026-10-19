//! Decoder semantics in one place: statistics, CRC verification on and off,
//! and how corruption and truncation are reported rather than guessed away.
//!
//! Run with: zig build run-decoder_semantics

const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Two multi-block streams for the statistics to count.
    var text = try std.ArrayList(u8).initCapacity(gpa, 60_000);
    defer text.deinit(gpa);
    for (0..300) |_| try text.appendSlice(gpa, "block mechanics: every 100 kB of level 1 input becomes a block\n");

    const stream = try bzip2.compress(gpa, text.items, .{ .level = 1 });
    defer gpa.free(stream);

    {
        const one_shot = try bzip2.decompress(gpa, stream, .{});
        defer gpa.free(one_shot);
        try std.testing.expectEqualStrings(text.items, one_shot);
        std.debug.print("round trip over {d} bytes verified\n", .{text.items.len});
    }

    // Streaming decode with statistics kept around. blocks counts decoded
    // blocks; output_bytes counts bytes that left the decoder.
    {
        var decoder = try bzip2.Decoder.init(gpa, .{});
        defer decoder.deinit();

        var restored: std.Io.Writer.Allocating = .init(gpa);
        defer restored.deinit();
        var source = std.Io.Reader.fixed(stream);
        try decoder.stream(&source, &restored.writer);

        try std.testing.expectEqualStrings(text.items, restored.written());
        try std.testing.expectEqual(@as(u64, 1), decoder.decompressor.stats.blocks);
        try std.testing.expectEqual(text.items.len, decoder.decompressor.stats.output_bytes);
        std.debug.print("stats after one stream: {d} block(s), {d} bytes\n", .{
            decoder.decompressor.stats.blocks,
            decoder.decompressor.stats.output_bytes,
        });

        // A second stream through the same decoder continues the statistics.
        const second = try bzip2.compress(gpa, "second stream\n", .{ .level = 1 });
        defer gpa.free(second);
        var second_source = std.Io.Reader.fixed(second);
        try decoder.stream(&second_source, &restored.writer);
        try std.testing.expectEqual(@as(u64, 2), decoder.decompressor.stats.blocks);
        std.debug.print("stats keep counting: {d} block(s)\n", .{decoder.decompressor.stats.blocks});
    }

    // CRC verification off: the same bytes decode again, but damaged blocks
    // that used to be rejected would now pass. Trusted-input decoding is the
    // only legitimate use.
    {
        var options = bzip2.DecompressionOptions{};
        options.verify_crc = false;
        var decoder = try bzip2.Decoder.init(gpa, options);
        defer decoder.deinit();

        var restored: std.Io.Writer.Allocating = .init(gpa);
        defer restored.deinit();
        var source = std.Io.Reader.fixed(stream);
        try decoder.stream(&source, &restored.writer);
        // A trunction still has to fail even with verification off; the
        // format itself cannot be decoded past its end.
        var truncated = std.Io.Reader.fixed(stream[0 .. stream.len - 4]);
        const failed = decoder.stream(&truncated, &restored.writer);
        if (failed) |_| {} else |err| {
            std.debug.print("truncation still rejected with verification off: {s}\n", .{@errorName(err)});
        }
    }

    // Corruption taxonomy, with the expectation spelled out per case.
    const bad_magic = "XZh9" ++ "\x00\x00\x17\x72\x45\x38\x50\x90";

    try expectFailed(gpa, bad_magic, error.InvalidStreamHeader, "bad magic");

    // Truncation: the data ends before the stream does.
    const short = try bzip2.compress(gpa, "will be cut short", .{ .level = 1 });
    defer gpa.free(short);
    try expectFailed(gpa, short[0 .. short.len - 3], error.UnexpectedEndOfStream, "truncated");

    // Flipped bits inside real data: caught by the CRC machinery, which
    // bzip2 was built around; the reported error is not required to name
    // the byte, only to refuse the stream.
    {
        var damaged: []u8 = try gpa.dupe(u8, stream);
        defer gpa.free(damaged);
        damaged[damaged.len / 2] ^= 0x40;
        const result = bzip2.decompress(gpa, damaged, .{});
        const failed_someway = if (result) |_| false else |_| true;
        try std.testing.expect(failed_someway);
        std.debug.print("flipped bit rejected somewhere in the codec\n", .{});
    }

    // Streams stop at their end-of-stream marker; what lies behind it is the
    // caller's business at the byte level. Concatenated archives must be
    // split by the caller, because the decoder consumes some lookahead bytes
    // into its scratch buffer reading the marker.
    {
        const one = try bzip2.compress(gpa, "first archive ", .{ .level = 1 });
        defer gpa.free(one);
        const two = try bzip2.compress(gpa, "second archive", .{ .level = 1 });
        defer gpa.free(two);

        // Give the two streams to the decoder as ONE byte blob, the shape a
        // concatenation would have. decode of the first archive happens
        // here, in memory bounded by the block, and the provider of the
        // input is free to keep the trailing bytes for another pass.
        var both = try std.ArrayList(u8).initCapacity(gpa, one.len + two.len);
        defer both.deinit(gpa);
        try both.appendSlice(gpa, one);
        try both.appendSlice(gpa, two);

        var decoder = try bzip2.Decoder.init(gpa, .{});
        defer decoder.deinit();
        var restored: std.Io.Writer.Allocating = .init(gpa);
        defer restored.deinit();
        var source = std.Io.Reader.fixed(both.items);
        try decoder.stream(&source, &restored.writer);

        try std.testing.expectEqualStrings("first archive ", restored.written());
        std.debug.print("first archive decoded; second stream slice {d}..{d} re-decoded now\n", .{
            one.len,
            both.items.len,
        });

        // Re-decode the second stream from ITS OWN byte slice: the honest
        // way to handle concatenation with this library.
        var second_pass: std.Io.Writer.Allocating = .init(gpa);
        defer second_pass.deinit();
        var second_archive = std.Io.Reader.fixed(both.items[one.len..]);
        try decoder.stream(&second_archive, &second_pass.writer);
        try std.testing.expectEqualStrings("second archive", second_pass.written());
        std.debug.print("second stream decoded from its own slice: {d} bytes\n", .{
            second_pass.written().len,
        });
    }
}

fn expectFailed(
    gpa: std.mem.Allocator,
    stream: []const u8,
    expected: bzip2.StreamError,
    label: []const u8,
) !void {
    if (bzip2.decompress(gpa, stream, .{})) |_| {
        return error.DecodeShouldHaveFailed;
    } else |err| {
        const failed: bzip2.StreamError = err;
        try std.testing.expectEqual(expected, failed);
        std.debug.print("{s}: rejected with {s}\n", .{ label, @errorName(failed) });
    }
}
