//! bzip2.zig - a native, memory-safe Zig implementation of the BZip2 stream
//! format.
//!
//! The library implements the real format: initial run-length coding, the
//! Burrows-Wheeler transform, move-to-front coding with RUNA/RUNB runs, and
//! canonical Huffman coding, framed with the standard stream header, block
//! markers, end-of-stream marker and bzip2's own CRC-32. Streams produced here
//! are readable by any conforming bzip2 implementation, and streams produced
//! elsewhere decode here.
//!
//! Usage:
//!
//!     const std = @import("std");
//!     const bzip2 = @import("bzip2");
//!
//!     pub fn main() !void {
//!         const gpa = std.heap.page_allocator;
//!         const compressed = try bzip2.compress(gpa, "hello hello hello", .{});
//!         defer gpa.free(compressed);
//!
//!         const restored = try bzip2.decompress(gpa, compressed, .{});
//!         defer gpa.free(restored);
//!         std.debug.print("{s}\n", .{restored});
//!     }
//!
//!
//! Ownership:
//!
//! compress and decompress return slices owned by the caller and
//! allocated with the allocator passed in; free them with that allocator. The
//! streaming types (Compressor, Decompressor, Decoder) never take
//! ownership of the buffers they read from or write to, and their own buffers
//! are released by deinit.
//!
//! Levels:
//!
//! bzip2 has no notion of "fast versus dense": a level is a block size. Level
//! N uses N * 100 kB blocks, and levels 1 through 9 are all accepted. Larger
//! blocks usually compress slightly
//! better because the BWT sees more context, and cost proportionally more
//! memory and time.
//!
//! Format support:
//!
//! Compression: levels 1..9, multi-block streams, all 256 byte values.
//! Decompression: all valid blocks including blocks marked randomised, which
//! only bzip2 versions before 0.9.5 produced.
//! Concatenated streams: this decoder stops at the first end-of-stream
//! marker, and nothing beyond that marker is promised to remain in the
//! reader. The bytes the decoder pulled ahead into its scratch buffer to
//! read the end marker are not handed back to the caller, so the reader
//! position after stream is unspecified. Split concatenated streams at
//! the end-of-stream markers yourself, then decode one stream after
//! another using the byte slices; decompress and the file helpers
//! decode one stream per call, like open input files.

const std = @import("std");
const Allocator = std.mem.Allocator;

const compress_impl = @import("compress.zig");
const decompress_impl = @import("decompress.zig");
const utils = @import("utils.zig");

pub const Error = utils.Error;
pub const StreamError = utils.StreamError;
/// Return type of the whole-file helpers, which can also fail to open a file.
pub const FileStreamError = utils.FileStreamError;

/// Regression fixtures with the metadata used to keep this library
/// byte-compatible with the BZip2 format. See fixtures.zig for the manifest.
pub const fixtures = @import("fixtures.zig");

/// Streaming encoder. Write chunks with write, then close with finish.
pub const Compressor = compress_impl.Compressor;
/// Compression level in units of 100 kB, 1..9.
pub const Level = u8;

/// Streaming decoder without owned buffers; pair it with a Scratch.
pub const Decompressor = decompress_impl.Decompressor;
/// Streaming decoder that owns its scratch buffers.
pub const Decoder = decompress_impl.Decoder;
/// Reusable decoder scratch buffers.
pub const Scratch = decompress_impl.Scratch;
/// What a decoder produced, readable after stream.
pub const Stats = decompress_impl.Stats;

/// Largest block the format allows, 900 kB.
pub const max_block_size = utils.max_block_size;

/// Lowercase letters are used for options, matching Zig conventions.
pub const CompressionOptions = compress_impl.Options;
pub const DecompressionOptions = decompress_impl.Options;

/// Library version.
pub const version_string = "0.0.1";
/// Major version of the library, for callers that gate on it.
pub const version_major: u32 = 0;

pub fn version() struct { major: u32, minor: u32, patch: u32 } {
    return .{ .major = 0, .minor = 0, .patch = 1 };
}

/// Compress input into a freshly allocated bzip2 stream.
///
/// Returns a slice owned by the caller. options.level must be 1..9. The
/// returned slice is allocated with gpa; free it with the same allocator.
pub fn compress(
    gpa: Allocator,
    input: []const u8,
    options: CompressionOptions,
) StreamError![]u8 {
    var sink: std.Io.Writer.Allocating = .init(gpa);
    errdefer sink.deinit();

    var source = std.Io.Reader.fixed(input);
    try compressStream(gpa, &source, &sink.writer, options);
    return sink.toOwnedSlice();
}

/// Decompress a complete bzip2 stream into a freshly allocated slice.
///
/// Returns a slice owned by the caller, allocated with gpa. Every structural
/// field is validated, and the block and stream CRCs are verified before the
/// result is handed back.
pub fn decompress(
    gpa: Allocator,
    input: []const u8,
    options: DecompressionOptions,
) StreamError![]u8 {
    var sink: std.Io.Writer.Allocating = .init(gpa);
    errdefer sink.deinit();

    var source = std.Io.Reader.fixed(input);
    try decompressStream(gpa, &source, &sink.writer, options);
    return sink.toOwnedSlice();
}

/// Compress everything readable from reader into writer.
///
/// Input is consumed incrementally; memory use is bounded by one block,
/// level * 100 kB, regardless of how much data flows through.
pub fn compressStream(
    gpa: Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: CompressionOptions,
) StreamError!void {
    var compressor = try Compressor.init(gpa, options);
    defer compressor.deinit();

    while (true) {
        // Already buffered bytes need no refill; fillMore would read again
        // and report the end of the stream on a reader whose buffer is preloaded.
        if (reader.buffered().len == 0) {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
        }
        const chunk = reader.buffered();
        if (chunk.len == 0) break;
        // The slice borrows the reader's buffer, so it has to be consumed
        // before those bytes are handed back to the source.
        try compressor.write(writer, chunk);
        reader.toss(chunk.len);
    }
    try compressor.finish(writer);
}

/// Decompress everything readable from reader into writer.
///
/// Output is produced block by block, so memory use is bounded by one block
/// plus a fixed output window.
pub fn decompressStream(
    gpa: Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: DecompressionOptions,
) StreamError!void {
    var decoder = try Decoder.init(gpa, options);
    defer decoder.deinit();
    try decoder.stream(reader, writer);
}

/// Compress src_path into dst_path, replacing any existing file.
///
/// io is the Zig 0.17 I/O interface used by std.Io.Dir and std.Io.File.
/// Neither path is fully loaded: memory use is one block of codec scratch plus
/// two 64 kB buffers, whatever the file size.
///
/// The output is written to a temporary file beside the destination and moved
/// into place only once compression has completed. That means a failure part
/// way through leaves any existing destination untouched and leaves no partial
/// archive behind that a later reader could mistake for a complete one. The
/// destination path is created or replaced at the moment of the final rename,
/// so the filesystem does the publishing.
///
/// src_path and dst_path must differ. Compressing a file onto itself would
/// destroy the input, so that is refused rather than attempted.
pub fn compressFile(
    gpa: Allocator,
    io: std.Io,
    src_path: []const u8,
    dst_path: []const u8,
    options: CompressionOptions,
) FileStreamError!void {
    if (std.mem.eql(u8, src_path, dst_path)) return error.SamePathAsSourceAndDestination;

    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, src_path, .{});
    defer file.close(io);

    const staging = try stagePath(gpa, dst_path);
    defer gpa.free(staging);

    const pump: Pump = .{ .gpa = gpa, .compress = true, .compression = options, .decompression = .{} };
    try writeStaged(dir, io, staging, dst_path, file, &pump);
}

/// Decompress the bzip2 file src_path into dst_path, replacing any existing
/// file.
///
/// Written through a staging file and published on success, for the same reason
/// as compressFile: a stream that fails part way through must not leave
/// partial plaintext where a caller expects a whole file.
pub fn decompressFile(
    gpa: Allocator,
    io: std.Io,
    src_path: []const u8,
    dst_path: []const u8,
    options: DecompressionOptions,
) FileStreamError!void {
    if (std.mem.eql(u8, src_path, dst_path)) return error.SamePathAsSourceAndDestination;

    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, src_path, .{});
    defer file.close(io);

    const staging = try stagePath(gpa, dst_path);
    defer gpa.free(staging);

    const pump: Pump = .{ .gpa = gpa, .compress = false, .compression = .{}, .decompression = options };
    try writeStaged(dir, io, staging, dst_path, file, &pump);
}

/// A staging path beside dst_path, so the final rename stays within one
/// directory and therefore within one filesystem.
fn stagePath(gpa: Allocator, dst_path: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.bzip2-partial", .{dst_path});
}

/// Run pump from src into a staging file, then publish it as dst_path.
///
/// The staging file is removed on every failure path, and dst_path is only
/// touched by the final rename. That is what keeps a half-written result from
/// being mistaken for a complete one, and what keeps an existing destination
/// intact when the new data never arrives.
///
/// The file is closed exactly once, before the rename, which matters on Windows
/// where a rename onto an open file is rejected.
fn writeStaged(
    dir: std.Io.Dir,
    io: std.Io,
    staging: []const u8,
    dst_path: []const u8,
    src: std.Io.File,
    pump: *const Pump,
) FileStreamError!void {
    // Clear any leftovers so the new run cannot inherit them.
    dir.deleteFile(io, staging) catch {};

    var closed = false;
    const out_file = dir.createFile(io, staging, .{}) catch |err| {
        return err;
    };
    defer {
        if (!closed) out_file.close(io);
        // Only a successfully renamed staging file leaves the filesystem, so
        // reaching this point without a rename means the contents are partial.
        dir.deleteFile(io, staging) catch {};
    }

    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader = src.readerStreaming(io, &read_buffer);
    var write_buffer: [64 * 1024]u8 = undefined;
    var file_writer = out_file.writerStreaming(io, &write_buffer);

    try pump.run(&file_reader.interface, &file_writer.interface);

    // Flush before closing so a write error surfaces here rather than being
    // swallowed by the close.
    try file_writer.interface.flush();
    out_file.close(io);
    closed = true;

    try std.Io.Dir.rename(dir, staging, dir, dst_path, io);
}

/// What the whole-file helpers run between the source reader and the
/// destination writer. Holding the caller's options here keeps them out of the
/// streaming path, where they do not belong.
const Pump = struct {
    gpa: Allocator,
    compress: bool,
    compression: CompressionOptions,
    decompression: DecompressionOptions,

    fn run(self: *const Pump, reader: *std.Io.Reader, writer: *std.Io.Writer) StreamError!void {
        if (self.compress) return compressStream(self.gpa, reader, writer, self.compression);
        return decompressStream(self.gpa, reader, writer, self.decompression);
    }
};

/// Read the block size (the stream's level) from a stream header without
/// decoding anything. Returns error.InvalidStreamHeader if data does not
/// start with a well formed BZh<1..9> header.
pub fn blockSizeOfStream(data: []const u8) Error!usize {
    if (data.len < 4) return error.InvalidStreamHeader;
    if (data[0] != utils.magic_b or data[1] != utils.magic_z or data[2] != utils.magic_h) {
        return error.InvalidStreamHeader;
    }
    if (!std.ascii.isDigit(data[3])) return error.InvalidStreamHeader;
    const level: usize = data[3] - utils.magic_0;
    if (level < utils.min_level or level > utils.max_level) return error.InvalidStreamHeader;
    return level * utils.block_unit;
}

/// Upper bound on the compressed size of input_size bytes.
///
/// Worst case each input byte becomes a four byte run group plus a count byte,
/// and every block carries a fixed overhead. The bound is generous; it exists
/// so callers can size a single buffer, not to predict the result.
pub fn maxCompressedSize(input_size: usize, level: u8) Error!usize {
    const options: CompressionOptions = .{ .level = level };
    const block_size = try options.checkedBlockSize();
    // Nineteen coded bytes per block are reserved for framing, so this many
    // blocks is never fewer than the input needs.
    const usable = block_size - 19;
    const blocks = std.math.divCeil(usize, input_size, usable) catch return error.OutOfMemory;
    // Header, trailer, per-block framing, the worst case 5/4 expansion of RLE1
    // and a conservative allowance for the symbol and selector tables.
    const per_block = std.math.add(
        usize,
        std.math.mul(usize, block_size / 4, 5) catch return error.OutOfMemory,
        4096,
    ) catch return error.OutOfMemory;
    const total = std.math.mul(usize, blocks, per_block) catch return error.OutOfMemory;
    return std.math.add(usize, total, 64) catch return error.OutOfMemory;
}

const testing = std.testing;

/// Seeds for the generated inputs in this section. Fixed so a failure
/// reproduces on any machine.
const test_seed: u64 = 0x627A_6970_325F_0001;

/// Fill out from a generator seeded by value. std.Random.DefaultPrng is
/// fully specified, so the same seed yields the same bytes everywhere.
fn testBytes(value: u64, out: []u8) void {
    var generator = std.Random.DefaultPrng.init(value);
    generator.random().bytes(out);
}

/// A distinct input shape, named so a failing case reports what it was.
const Shape = struct {
    name: []const u8,
    build: *const fn (gpa: std.mem.Allocator) anyerror![]u8,
};

fn emptyInput(gpa: std.mem.Allocator) ![]u8 {
    return gpa.alloc(u8, 0);
}

fn oneByteInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 1);
    out[0] = 0x42;
    return out;
}

fn twoBytesInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 2);
    @memcpy(out, "ab");
    return out;
}

fn shortTextInput(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8, "The quick brown fox jumps over the lazy dog.");
}

fn repeatedBytesInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 100_000);
    @memset(out, 'A');
    return out;
}

fn repeatedByteWithTailInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 50_000);
    @memset(out, 'A');
    out[out.len - 1] = 'B';
    return out;
}

fn alternatingInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 40_000);
    for (out, 0..) |*byte, i| byte.* = if (i % 2 == 0) 0xAA else 0x55;
    return out;
}

fn allByteValuesInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 256);
    for (out, 0..) |*byte, i| byte.* = @intCast(i);
    return out;
}

fn allByteValuesRepeatedInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 256 * 64);
    for (out, 0..) |*byte, i| byte.* = @intCast(i % 256);
    return out;
}

fn zeroByteInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 4096);
    for (out, 0..) |*byte, i| byte.* = if (i % 64 < 32) 0x00 else @truncate(i);
    return out;
}

fn longZeroRunInput(gpa: std.mem.Allocator) ![]u8 {
    // Far longer than the 255 byte maximum run length, which is the case the
    // run-length encoder has to split.
    const out = try gpa.alloc(u8, 150_000);
    @memset(out, 0);
    return out;
}

fn highEntropyInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 120_000);
    testBytes(test_seed, out);
    return out;
}

fn structuredEntropyInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 100_000);
    testBytes(test_seed + 1, out);
    // Punch recognisable runs into the noise so the transform has something to
    // find and the block is not purely incompressible.
    for (0..40) |i| {
        const start = i * 2000;
        @memset(out[start .. start + 400], 'z');
    }
    return out;
}

fn repetitiveInput(gpa: std.mem.Allocator) ![]u8 {
    const unit = "abcabcabcabcabcabcabcabcabcabcabcabc";
    const out = try gpa.alloc(u8, unit.len * 900);
    for (out, 0..) |*byte, i| byte.* = unit[i % unit.len];
    return out;
}

fn periodicInput(gpa: std.mem.Allocator) ![]u8 {
    // A block whose period divides its length exactly, so every rotation is
    // identical. That is the hardest case for the block-sorting stage.
    const out = try gpa.alloc(u8, 40_000);
    @memset(out, 'a');
    return out;
}

fn justUnderOneBlockInput(gpa: std.mem.Allocator) ![]u8 {
    // Level 1 blocks hold 99981 coded bytes. Incompressible input leaves the
    // coded length equal to the input length, so this lands just under that.
    const out = try gpa.alloc(u8, 99_980);
    testBytes(test_seed + 2, out);
    return out;
}

fn justOverOneBlockInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 100_001);
    testBytes(test_seed + 3, out);
    return out;
}

fn manyBlocksInput(gpa: std.mem.Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 400_000);
    testBytes(test_seed + 4, out);
    return out;
}

fn mixedInput(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var generator = std.Random.DefaultPrng.init(test_seed + 5);
    var random = generator.random();
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        try out.appendSlice(gpa, "record ");
        try out.append(gpa, '0' + random.uintLessThan(u8, 10));
        try out.appendSlice(gpa, ": payload with words and numbers 12345\n");
        var blob: [97]u8 = undefined;
        random.bytes(&blob);
        try out.appendSlice(gpa, &blob);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// Every input shape the format has to survive, from empty through to input
/// that spans several blocks.
const shapes = [_]Shape{
    .{ .name = "empty", .build = emptyInput },
    .{ .name = "one byte", .build = oneByteInput },
    .{ .name = "two bytes", .build = twoBytesInput },
    .{ .name = "short text", .build = shortTextInput },
    .{ .name = "repeated bytes", .build = repeatedBytesInput },
    .{ .name = "repeated bytes with a tail", .build = repeatedByteWithTailInput },
    .{ .name = "alternating pattern", .build = alternatingInput },
    .{ .name = "all byte values", .build = allByteValuesInput },
    .{ .name = "all byte values repeated", .build = allByteValuesRepeatedInput },
    .{ .name = "embedded zero bytes", .build = zeroByteInput },
    .{ .name = "long zero run", .build = longZeroRunInput },
    .{ .name = "high entropy", .build = highEntropyInput },
    .{ .name = "high entropy with structure", .build = structuredEntropyInput },
    .{ .name = "highly repetitive", .build = repetitiveInput },
    .{ .name = "periodic block", .build = periodicInput },
    .{ .name = "just under a level 1 block", .build = justUnderOneBlockInput },
    .{ .name = "just over a level 1 block", .build = justOverOneBlockInput },
    .{ .name = "many blocks", .build = manyBlocksInput },
    .{ .name = "text with embedded binary", .build = mixedInput },
};

/// Compress, decompress and compare over the public entry points.
fn expectRoundTrip(gpa: std.mem.Allocator, input: []const u8, level: u8) !void {
    const compressed = try compress(gpa, input, .{ .level = level });
    defer gpa.free(compressed);
    const restored = try decompress(gpa, compressed, .{});
    defer gpa.free(restored);
    try testing.expectEqualSlices(u8, input, restored);
}

test "every input shape round trips at the default level" {
    const gpa = testing.allocator;
    for (shapes) |shape| {
        const input = try shape.build(gpa);
        defer gpa.free(input);
        expectRoundTrip(gpa, input, 9) catch |err| {
            return err;
        };
    }
}

test "every input shape round trips at every level" {
    const gpa = testing.allocator;
    for (shapes) |shape| {
        const input = try shape.build(gpa);
        defer gpa.free(input);
        for (1..10) |level| {
            expectRoundTrip(gpa, input, @intCast(level)) catch {
                return error.RoundTripFailed;
            };
        }
    }
}

test {
    // Pull the fixture module's tests into this suite. Without a live
    // reference to the declaration, semantic analysis would skip the file
    // and its tests silently.
    _ = fixtures;
}

test "version matches the package metadata" {
    try testing.expectEqualStrings("0.0.1", version_string);
}

test "header introspection" {
    try testing.expectEqual(@as(usize, 900_000), try blockSizeOfStream("BZh9"));
    try testing.expectEqual(@as(usize, 100_000), try blockSizeOfStream("BZh1"));
    try testing.expectError(error.InvalidStreamHeader, blockSizeOfStream("BZh0"));
    try testing.expectError(error.InvalidStreamHeader, blockSizeOfStream("BZh:"));
    try testing.expectError(error.InvalidStreamHeader, blockSizeOfStream("BZh"));
    try testing.expectError(error.InvalidStreamHeader, blockSizeOfStream("XXXX9"));
}

test "round trip of a short string" {
    const gpa = testing.allocator;
    const compressed = try compress(gpa, "hello hello hello", .{});
    defer gpa.free(compressed);
    const restored = try decompress(gpa, compressed, .{});
    defer gpa.free(restored);
    try testing.expectEqualStrings("hello hello hello", restored);
}

test "round trip of empty input" {
    const gpa = testing.allocator;
    const compressed = try compress(gpa, "", .{});
    defer gpa.free(compressed);
    try testing.expectEqual(@as(usize, 14), compressed.len);
    const restored = try decompress(gpa, compressed, .{});
    defer gpa.free(restored);
    try testing.expectEqual(@as(usize, 0), restored.len);
}

test "compression bound is generous enough" {
    try testing.expect((try maxCompressedSize(0, 9)) > 0);
    try testing.expect((try maxCompressedSize(1_000_000, 1)) > 1_000_000);
}

test "every byte survives a round trip at every position" {
    const gpa = testing.allocator;
    // One stream per byte value would be slow; a single stream holding all 256
    // values in both orders exercises the same paths.
    var input: [256 * 4]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @truncate(i % 256);
    try expectRoundTrip(gpa, &input, 9);
    for (&input, 0..) |*byte, i| byte.* = @truncate(255 - (i % 256));
    try expectRoundTrip(gpa, &input, 1);
}

test "an invalid compression level is rejected" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidCompressionLevel, compress(gpa, "data", .{ .level = 0 }));
    try testing.expectError(error.InvalidCompressionLevel, compress(gpa, "data", .{ .level = 10 }));
    try testing.expectError(error.InvalidCompressionLevel, Compressor.init(gpa, .{ .level = 255 }));
}

test "the block size is reported from the stream header" {
    const gpa = testing.allocator;
    for (1..10) |level| {
        const compressed = try compress(gpa, "block size probe", .{ .level = @intCast(level) });
        defer gpa.free(compressed);
        try testing.expectEqual(
            @as(usize, level) * utils.block_unit,
            try blockSizeOfStream(compressed),
        );
    }
}

test "every input shape survives a streaming round trip" {
    const gpa = testing.allocator;
    for (shapes) |shape| {
        const input = try shape.build(gpa);
        defer gpa.free(input);

        var compressed_sink: std.Io.Writer.Allocating = .init(gpa);
        defer compressed_sink.deinit();
        var source = std.Io.Reader.fixed(input);
        try compressStream(gpa, &source, &compressed_sink.writer, .{ .level = 6 });
        const compressed = try compressed_sink.toOwnedSlice();
        defer gpa.free(compressed);

        var restored_sink: std.Io.Writer.Allocating = .init(gpa);
        defer restored_sink.deinit();
        var compressed_source = std.Io.Reader.fixed(compressed);
        try decompressStream(gpa, &compressed_source, &restored_sink.writer, .{});
        const restored = try restored_sink.toOwnedSlice();
        defer gpa.free(restored);

        try testing.expectEqualSlices(u8, input, restored);
    }
}

test "compressible and incompressible shapes stay within their bounds" {
    const gpa = testing.allocator;
    for (shapes) |shape| {
        const input = try shape.build(gpa);
        defer gpa.free(input);

        const compressed = try compress(gpa, input, .{ .level = 9 });
        defer gpa.free(compressed);

        // The format has no stored mode, so the worst case is a modest
        // expansion rather than unbounded growth.
        try testing.expect(compressed.len < input.len * 2 + 64);
        // The declared bound has to cover the real result.
        try testing.expect(compressed.len <= try maxCompressedSize(input.len, 9));
    }
}

/// File tests need a working directory and a real std.Io.
fn testIo(gpa: std.mem.Allocator) !std.Io.Threaded {
    return std.Io.Threaded.init(gpa, .{});
}

test "compressing a file onto itself is refused rather than destroying it" {
    const gpa = testing.allocator;
    var threaded = try testIo(gpa);
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();

    const path = "zig-out/selftest_same_path.txt";
    dir.createDirPath(io, "zig-out") catch {};
    defer dir.deleteFile(io, path) catch {};
    const original = "data that must survive the attempt\n";
    try dir.writeFile(io, .{ .sub_path = path, .data = original });

    try testing.expectError(
        error.SamePathAsSourceAndDestination,
        compressFile(gpa, io, path, path, .{}),
    );
    try testing.expectError(
        error.SamePathAsSourceAndDestination,
        decompressFile(gpa, io, path, path, .{}),
    );

    // The file is untouched.
    const after = try dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(after);
    try testing.expectEqualStrings(original, after);
}

test "a failed decompression leaves no output and no staging file" {
    const gpa = testing.allocator;
    var threaded = try testIo(gpa);
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "zig-out") catch {};

    const archive = "zig-out/selftest_damaged.bz2";
    const output = "zig-out/selftest_damaged.out";
    const staging = "zig-out/selftest_damaged.out.bzip2-partial";
    defer dir.deleteFile(io, archive) catch {};
    defer dir.deleteFile(io, output) catch {};
    defer dir.deleteFile(io, staging) catch {};

    // A truncated stream must fail, and must not leave a partial file where the
    // caller expects either the old contents or nothing.
    var damage_payload: [1280]u8 = undefined;
    @memset(&damage_payload, 'x');
    const good = try compress(gpa, &damage_payload, .{ .level = 9 });
    defer gpa.free(good);
    try dir.writeFile(io, .{ .sub_path = archive, .data = good[0 .. good.len - 6] });

    // Put something at the destination so we can prove it was not clobbered.
    const sentinel = "previous contents\n";
    try dir.writeFile(io, .{ .sub_path = output, .data = sentinel });

    try testing.expectError(
        error.UnexpectedEndOfStream,
        decompressFile(gpa, io, archive, output, .{}),
    );

    // The destination still holds what it did before.
    const after = try dir.readFileAlloc(io, output, gpa, .limited(1 << 20));
    defer gpa.free(after);
    try testing.expectEqualStrings(sentinel, after);

    // No staging file survived.
    try testing.expectError(error.FileNotFound, dir.statFile(io, staging, .{}));
}

test "a completed file round trip replaces the destination" {
    const gpa = testing.allocator;
    var threaded = try testIo(gpa);
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "zig-out") catch {};

    const source = "zig-out/selftest_roundtrip.txt";
    const archive = "zig-out/selftest_roundtrip.txt.bz2";
    const restored = "zig-out/selftest_roundtrip_restored.txt";
    const staging = "zig-out/selftest_roundtrip.txt.bz2.bzip2-partial";
    defer dir.deleteFile(io, source) catch {};
    defer dir.deleteFile(io, archive) catch {};
    defer dir.deleteFile(io, restored) catch {};

    var payload: [40_000]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = if (i % 7 == 0) 0 else @truncate(i);
    try dir.writeFile(io, .{ .sub_path = source, .data = &payload });

    // The destination already exists and must be replaced, not appended to.
    try dir.writeFile(io, .{ .sub_path = archive, .data = "stale archive that must go away" });

    try compressFile(gpa, io, source, archive, .{ .level = 6 });
    try decompressFile(gpa, io, archive, restored, .{});

    const got = try dir.readFileAlloc(io, restored, gpa, .limited(1 << 20));
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, &payload, got);

    try testing.expectError(error.FileNotFound, dir.statFile(io, staging, .{}));
}

test "file helpers handle empty and one-byte inputs" {
    const gpa = testing.allocator;
    var threaded = try testIo(gpa);
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "zig-out") catch {};

    for ([_]usize{ 0, 1 }) |size| {
        const source = "zig-out/selftest_small.txt";
        const archive = "zig-out/selftest_small.txt.bz2";
        const restored = "zig-out/selftest_small_restored.txt";
        defer dir.deleteFile(io, source) catch {};
        defer dir.deleteFile(io, archive) catch {};
        defer dir.deleteFile(io, restored) catch {};

        var payload: [1]u8 = undefined;
        if (size == 1) payload[0] = 0xA7;
        try dir.writeFile(io, .{ .sub_path = source, .data = payload[0..size] });

        try compressFile(gpa, io, source, archive, .{ .level = 9 });
        try decompressFile(gpa, io, archive, restored, .{});

        const got = try dir.readFileAlloc(io, restored, gpa, .limited(1 << 20));
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, payload[0..size], got);
    }
}

test "a missing source file is reported rather than creating an output" {
    const gpa = testing.allocator;
    var threaded = try testIo(gpa);
    defer threaded.deinit();
    const io = threaded.io();
    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "zig-out") catch {};

    const output = "zig-out/selftest_absent.out";
    const staging = "zig-out/selftest_absent.out.bzip2-partial";
    defer dir.deleteFile(io, output) catch {};

    try testing.expectError(
        error.FileNotFound,
        compressFile(gpa, io, "zig-out/selftest_does_not_exist.txt", output, .{}),
    );
    // Nothing was created, not even the staging file.
    try testing.expectError(error.FileNotFound, dir.statFile(io, output, .{}));
    try testing.expectError(error.FileNotFound, dir.statFile(io, staging, .{}));
}

// Failure injection. checkAllAllocationFailures re-runs body once per
// allocation, refusing that one allocation and letting the rest succeed. It
// requires the body to report error.OutOfMemory when a failure was induced,
// and it checks that allocated and freed bytes balance on every such run.

// The payload and the output buffer are allocated from a separate allocator, so
// the only allocations that can fail are the ones inside the codec. That
// matters because std.Io.Writer.Allocating reports its own out-of-memory as
// error.WriteFailed, which would otherwise mask a real codec failure.

/// The payload the injection tests run on. Large enough to cross a block
/// boundary at level 1, which is where partial initialisation is most likely.
fn injectionPayload(gpa: std.mem.Allocator) ![]u8 {
    const prose = "allocation failures must not leak, and must not leave a half-built context behind. ";
    const out = try gpa.alloc(u8, prose.len * 1300);
    for (out, 0..) |*byte, i| byte.* = prose[i % prose.len];
    return out;
}

/// An owned buffer plus the number of bytes actually used. The whole buffer is
/// returned rather than a prefix, because an allocator has to be handed back
/// exactly what it handed out.
const Sized = struct {
    buffer: []u8,
    len: usize,

    fn free(self: Sized, gpa: std.mem.Allocator) void {
        gpa.free(self.buffer);
    }
};

/// Compress into a caller-sized buffer, so the sink never allocates.
fn compressIntoFixed(
    gpa: std.mem.Allocator,
    backing: std.mem.Allocator,
    input: []const u8,
    level: u8,
) !Sized {
    const capacity = try maxCompressedSize(input.len, level);
    const out = try backing.alloc(u8, capacity);
    errdefer backing.free(out);

    var writer = std.Io.Writer.fixed(out);
    var compressor = try Compressor.init(gpa, .{ .level = level });
    defer compressor.deinit();
    try compressor.write(&writer, input);
    try compressor.finish(&writer);
    return .{ .buffer = out, .len = writer.end };
}

/// Decompress into a caller-sized buffer. A round trip returns exactly
/// input.len bytes, so that is a sufficient capacity.
fn decompressIntoFixed(
    gpa: std.mem.Allocator,
    backing: std.mem.Allocator,
    stream: []const u8,
    capacity: usize,
) !Sized {
    const out = try backing.alloc(u8, capacity);
    errdefer backing.free(out);

    var writer = std.Io.Writer.fixed(out);
    var decoder = try Decoder.init(gpa, .{});
    defer decoder.deinit();
    var source = std.Io.Reader.fixed(stream);
    try decoder.stream(&source, &writer);
    return .{ .buffer = out, .len = writer.end };
}

fn compressionUnderAllocationFailure(gpa: std.mem.Allocator, backing: std.mem.Allocator) !void {
    const input = try injectionPayload(backing);
    defer backing.free(input);

    const compressed = try compressIntoFixed(gpa, backing, input, 1);
    defer compressed.free(backing);

    const restored = try decompressIntoFixed(gpa, backing, compressed.buffer[0..compressed.len], input.len);
    defer restored.free(backing);
    try testing.expectEqualSlices(u8, input, restored.buffer[0..restored.len]);
}

fn decompressionUnderAllocationFailure(gpa: std.mem.Allocator, backing: std.mem.Allocator) !void {
    const input = try injectionPayload(backing);
    defer backing.free(input);
    const compressed = try compressIntoFixed(backing, backing, input, 1);
    defer compressed.free(backing);

    const restored = try decompressIntoFixed(gpa, backing, compressed.buffer[0..compressed.len], input.len);
    defer restored.free(backing);
    try testing.expectEqualSlices(u8, input, restored.buffer[0..restored.len]);
}

fn streamingCompressionUnderAllocationFailure(gpa: std.mem.Allocator, backing: std.mem.Allocator) !void {
    const input = try injectionPayload(backing);
    defer backing.free(input);

    const compressed = try compressIntoFixed(gpa, backing, input, 1);
    defer compressed.free(backing);

    const restored = try decompressIntoFixed(gpa, backing, compressed.buffer[0..compressed.len], input.len);
    defer restored.free(backing);
    try testing.expectEqualSlices(u8, input, restored.buffer[0..restored.len]);
}

/// A compressor constructed under a failing allocator, then used for several
/// streams. A partial construction must not leave the encoder unusable.
fn compressorLifecycleUnderAllocationFailure(gpa: std.mem.Allocator, backing: std.mem.Allocator) !void {
    const input = try injectionPayload(backing);
    defer backing.free(input);

    var compressor = try Compressor.init(gpa, .{ .level = 1 });
    defer compressor.deinit();

    var passes: usize = 0;
    while (passes < 2) : (passes += 1) {
        compressor.reset();
        const stream = try compressIntoFixed(gpa, backing, input, 1);
        defer stream.free(backing);
        const restored = try decompressIntoFixed(gpa, backing, stream.buffer[0..stream.len], input.len);
        defer restored.free(backing);
        try testing.expectEqualSlices(u8, input, restored.buffer[0..restored.len]);
    }
}

/// A decoder constructed under a failing allocator, then used for several
/// streams. Scratch retention across calls must not become a leak.
fn decoderLifecycleUnderAllocationFailure(gpa: std.mem.Allocator, backing: std.mem.Allocator) !void {
    const input = try injectionPayload(backing);
    defer backing.free(input);
    const compressed = try compressIntoFixed(backing, backing, input, 9);
    defer compressed.free(backing);

    var decoder = try Decoder.init(gpa, .{});
    defer decoder.deinit();

    var passes: usize = 0;
    while (passes < 3) : (passes += 1) {
        const out = try backing.alloc(u8, input.len);
        defer backing.free(out);
        var writer = std.Io.Writer.fixed(out);
        var source = std.Io.Reader.fixed(compressed.buffer[0..compressed.len]);
        try decoder.stream(&source, &writer);
        try testing.expectEqualSlices(u8, input, out[0..writer.end]);
    }
}

/// A truncated stream, so the decoder fails part way through and has to unwind
/// whatever it had already allocated for the block.
fn malformedUnderAllocationFailure(gpa: std.mem.Allocator, backing: std.mem.Allocator) !void {
    const input = try injectionPayload(backing);
    defer backing.free(input);
    const compressed = try compressIntoFixed(backing, backing, input, 1);
    defer compressed.free(backing);

    const truncated = compressed.buffer[0 .. compressed.len / 2];
    const out = try backing.alloc(u8, input.len);
    defer backing.free(out);

    var writer = std.Io.Writer.fixed(out);
    var decoder = try Decoder.init(gpa, .{});
    defer decoder.deinit();
    var source = std.Io.Reader.fixed(truncated);
    decoder.stream(&source, &writer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Any other failure is the expected one: a truncated stream is refused.
        else => {},
    };
}

test "one-shot compression and decompression survive every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        compressionUnderAllocationFailure,
        .{testing.allocator},
    );
}

test "decompression of a valid stream survives every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        decompressionUnderAllocationFailure,
        .{testing.allocator},
    );
}

test "streaming compression survives every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        streamingCompressionUnderAllocationFailure,
        .{testing.allocator},
    );
}

test "a compressor built under allocation failure is reusable across streams" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        compressorLifecycleUnderAllocationFailure,
        .{testing.allocator},
    );
}

test "a decoder built under allocation failure is reusable across streams" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        decoderLifecycleUnderAllocationFailure,
        .{testing.allocator},
    );
}

test "a malformed stream survives every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        malformedUnderAllocationFailure,
        .{testing.allocator},
    );
}

test "allocation counts are stable, so nothing accumulates between calls" {
    const gpa = testing.allocator;
    const input = try injectionPayload(gpa);
    defer gpa.free(input);

    // Warm up so one-off allocations are already paid.
    {
        const warm = try compress(gpa, input, .{ .level = 9 });
        gpa.free(warm);
    }

    var counted = testing.FailingAllocator.init(gpa, .{});
    const before = counted.alloc_index;

    const first = try compress(counted.allocator(), input, .{ .level = 9 });
    const first_allocs = counted.alloc_index - before;
    counted.allocator().free(first);

    const second = try compress(counted.allocator(), input, .{ .level = 9 });
    const second_allocs = counted.alloc_index - before - first_allocs;
    counted.allocator().free(second);

    // A second compression of the same input must not cost more than the first.
    // Growth here would mean a buffer is being reallocated per call rather than
    // reused within one.
    try testing.expectEqual(first_allocs, second_allocs);
}
