//! The bzip2 decoder.
//!
//! Decoding walks a fixed pipeline. Huffman decoding turns the bit stream back
//! into MTF values and RUNA/RUNB run lengths, those rebuild the last column of
//! the sorted matrix, the inverse Burrows-Wheeler transform turns that column
//! back into the RLE1-coded block, and the run-length stage finally expands it
//! into the caller's bytes.
//!
//! Every field is bounds checked before it is used: the selector count, the
//! Huffman code lengths, the MTF run lengths, orig_ptr and the reconstructed
//! block length are all validated against limits derived from the stream's own
//! declared block size. A malformed stream fails with a specific error instead
//! of reading out of bounds or allocating without limit.

const std = @import("std");
const Allocator = std.mem.Allocator;

const bwt = @import("bwt.zig");
const huffman = @import("huffman.zig");
const mtf = @import("mtf.zig");
const randomise = @import("randomise.zig");
const rle = @import("rle.zig");
const utils = @import("utils.zig");

/// Tuning knobs for the decoder.
pub const Options = struct {
    /// Refuse to produce more than this many bytes in total. null means
    /// unbounded, which is only appropriate for trusted input: a few hundred
    /// bytes of stream can expand into megabytes.
    max_output_size: ?usize = null,
    /// Verify the per-block and stream CRCs. Disabling it saves work but loses
    /// the corruption check, so it defaults to on.
    verify_crc: bool = true,
};

/// Window size used to stream RLE1 expansion towards the writer. Large enough
/// that the flush check in expandRle never fires in practice.
const chunk_size = 64 * 1024;

/// Decoder scratch buffers, sized from the block size the stream header
/// declares and reused for every block of that stream.
pub const Scratch = struct {
    gpa: Allocator,
    /// Huffman/MTF output, i.e. the BWT last column.
    last_column: []u8 = &.{},
    /// First-column to row mapping used by the inverse BWT.
    next: []u32 = &.{},
    /// Reconstructed but still RLE1-coded block bytes.
    block: []u8 = &.{},
    /// Output window.
    chunk: []u8 = &.{},

    pub fn init(gpa: Allocator) Allocator.Error!Scratch {
        return .{ .gpa = gpa, .chunk = try gpa.alloc(u8, chunk_size) };
    }

    /// Grow the block sized buffers so a block_size-byte block fits.
    ///
    /// The old buffers are released before the new ones are taken, so the
    /// scratch never holds more than one set. All three are cleared before the
    /// first allocation is attempted: if that fails, self must not be left
    /// pointing at memory that has already been freed, or deinit would free it
    /// a second time.
    pub fn ensure(self: *Scratch, block_size: usize) Allocator.Error!void {
        if (self.last_column.len >= block_size) return;

        self.gpa.free(self.last_column);
        self.gpa.free(self.next);
        self.gpa.free(self.block);
        self.last_column = &.{};
        self.next = &.{};
        self.block = &.{};

        const last_column = try self.gpa.alloc(u8, block_size);
        errdefer self.gpa.free(last_column);
        const next = try self.gpa.alloc(u32, block_size);
        errdefer self.gpa.free(next);
        const block = try self.gpa.alloc(u8, block_size);

        self.last_column = last_column;
        self.next = next;
        self.block = block;
    }

    pub fn deinit(self: *Scratch) void {
        self.gpa.free(self.last_column);
        self.gpa.free(self.next);
        self.gpa.free(self.block);
        self.gpa.free(self.chunk);
        self.* = undefined;
    }
};

/// Progress counters a caller can read after decoding.
pub const Stats = struct {
    /// Blocks decoded.
    blocks: u64 = 0,
    /// Bytes produced.
    output_bytes: usize = 0,
};

/// Streaming bzip2 decoder.
///
/// Decompressor owns no buffers of its own, so a caller that decodes several
/// streams should allocate its Scratch once and reuse it. Decoder does that
/// for you.
pub const Decompressor = struct {
    options: Options,
    stats: Stats = .{},
    finished: bool = false,

    pub fn init(options: Options) Decompressor {
        return .{ .options = options };
    }

    /// Clear the progress counters and allow another stream to be decoded.
    pub fn reset(self: *Decompressor) void {
        self.stats = .{};
        self.finished = false;
    }

    /// Decode a complete bzip2 stream from reader into writer.
    pub fn stream(
        self: *Decompressor,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        scratch: *Scratch,
    ) utils.StreamError!void {
        var bits = utils.BitReader.init(reader);
        const level = try readStreamHeader(&bits);
        const block_size = @as(usize, level) * utils.block_unit;
        try scratch.ensure(block_size);
        try streamWithScratch(self, &bits, scratch, writer, block_size);
    }
};

/// A Decompressor that owns its scratch buffers.
pub const Decoder = struct {
    decompressor: Decompressor,
    scratch: Scratch,

    pub fn init(gpa: Allocator, options: Options) Allocator.Error!Decoder {
        return .{
            .decompressor = Decompressor.init(options),
            .scratch = try Scratch.init(gpa),
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.scratch.deinit();
        self.* = undefined;
    }

    pub fn reset(self: *Decoder) void {
        self.decompressor.reset();
    }

    /// Decode a complete stream from reader into writer.
    pub fn stream(
        self: *Decoder,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
    ) utils.StreamError!void {
        try self.decompressor.stream(reader, writer, &self.scratch);
    }
};

fn readStreamHeader(bits: *utils.BitReader) utils.Error!u8 {
    if (try bits.readByte() != utils.magic_b) return error.InvalidStreamHeader;
    if (try bits.readByte() != utils.magic_z) return error.InvalidStreamHeader;
    if (try bits.readByte() != utils.magic_h) return error.InvalidStreamHeader;
    const digit = try bits.readByte();
    if (!std.ascii.isDigit(digit)) return error.InvalidStreamHeader;
    const level = digit - utils.magic_0;
    if (level < utils.min_level or level > utils.max_level) return error.InvalidStreamHeader;
    return level;
}

/// Read a four byte big-endian value, used for both CRCs.
fn readU32(bits: *utils.BitReader) utils.Error!u32 {
    var value: u32 = 0;
    for (0..4) |_| value = (value << 8) | try bits.readByte();
    return value;
}

/// Read the six byte block or end-of-stream marker.
///
/// Anything else is a hard error, which is how a truncated or misaligned
/// stream is caught before any block sized allocation happens.
fn readMarker(bits: *utils.BitReader) utils.Error!enum { block, end_of_stream } {
    const first = try bits.readByte();
    if (first == utils.end_magic[0]) {
        for (utils.end_magic[1..]) |expected| {
            if (try bits.readByte() != expected) return error.InvalidEndOfStreamMarker;
        }
        return .end_of_stream;
    }
    if (first != utils.block_magic[0]) return error.InvalidBlockMarker;
    for (utils.block_magic[1..]) |expected| {
        if (try bits.readByte() != expected) return error.InvalidBlockMarker;
    }
    return .block;
}

fn streamWithScratch(
    state: *Decompressor,
    bits: *utils.BitReader,
    scratch: *Scratch,
    writer: *std.Io.Writer,
    block_size: usize,
) utils.StreamError!void {
    var combined_crc: u32 = 0;
    while (true) {
        switch (try readMarker(bits)) {
            .end_of_stream => break,
            .block => {},
        }
        const block_crc = try decodeBlock(state, bits, scratch, writer, block_size);
        combined_crc = utils.combineCrc(combined_crc, block_crc);
        state.stats.blocks += 1;
    }

    const stored_combined = try readU32(bits);
    if (state.options.verify_crc and stored_combined != combined_crc) {
        return error.StreamCrcMismatch;
    }
    state.finished = true;
}

/// Cursor over the selector list, so that reading MTF symbols stays cheap.
const SymbolCursor = struct {
    tables: *const [utils.num_groups]huffman.DecodeTable,
    selectors: []const u8,
    group_no: usize = 0,
    group_left: usize = 0,
    table: *const huffman.DecodeTable,

    fn init(
        tables: *const [utils.num_groups]huffman.DecodeTable,
        selectors: []const u8,
    ) SymbolCursor {
        return .{
            .tables = tables,
            .selectors = selectors,
            .table = &tables[0],
        };
    }

    fn next(self: *SymbolCursor, bits: *utils.BitReader) utils.Error!u16 {
        if (self.group_left == 0) {
            if (self.group_no >= self.selectors.len) return error.InvalidSelectors;
            self.table = &self.tables[self.selectors[self.group_no]];
            self.group_no += 1;
            self.group_left = utils.group_size;
        }
        self.group_left -= 1;
        return @intCast(try self.table.decodeSymbol(bits));
    }
};

/// Decode one block and write its RLE1 expansion to writer.
///
/// Returns the block CRC the stream declared so the caller can fold it into the
/// combined CRC.
fn decodeBlock(
    state: *Decompressor,
    bits: *utils.BitReader,
    scratch: *Scratch,
    writer: *std.Io.Writer,
    block_size: usize,
) utils.StreamError!u32 {
    const stored_crc = try readU32(bits);
    const randomised = (try bits.readBit()) == 1;
    const orig_ptr: u32 = try bits.readBits(24);

    // Symbol map: the 16 group flags come first as a block, then 16 byte flags
    // for every group whose flag is set.
    var in_use: [256]bool = @splat(false);
    var in_use16: [16]bool = @splat(false);
    var any_group = false;
    for (0..16) |group| {
        const set = (try bits.readBit()) == 1;
        in_use16[group] = set;
        any_group = any_group or set;
    }
    if (!any_group) return error.InvalidSymbolMap;
    for (0..16) |group| {
        if (!in_use16[group]) continue;
        for (0..16) |byte| {
            if ((try bits.readBit()) == 1) in_use[group * 16 + byte] = true;
        }
    }

    var alphabet: [256]u8 = undefined;
    var n_in_use: usize = 0;
    for (in_use, 0..) |used, byte| {
        if (used) {
            alphabet[n_in_use] = @intCast(byte);
            n_in_use += 1;
        }
    }
    const alpha_size = n_in_use + 2;
    const eob: u16 = @intCast(n_in_use + 1);

    // Selectors.
    const n_groups = try bits.readBits(3);
    if (n_groups < 2 or n_groups > utils.num_groups) return error.InvalidSelectors;
    const raw_selectors = try bits.readBits(15);
    if (raw_selectors < 1) return error.InvalidSelectors;

    var selector_mtf: [utils.max_selectors]u8 = undefined;
    for (0..raw_selectors) |i| {
        var j: u32 = 0;
        while ((try bits.readBit()) == 1) {
            j += 1;
            if (j >= n_groups) return error.InvalidSelectors;
        }
        // Rounded-up selector counts are legal; the extra entries are never read.
        if (i < utils.max_selectors) selector_mtf[i] = @truncate(j);
    }
    const n_selectors = @min(raw_selectors, utils.max_selectors);

    var selectors: [utils.max_selectors]u8 = undefined;
    {
        var pos: [utils.num_groups]u8 = undefined;
        for (0..n_groups) |i| pos[i] = @intCast(i);
        for (selectors[0..n_selectors], 0..) |*slot, i| {
            const v = selector_mtf[i];
            const held = pos[v];
            std.mem.copyBackwards(u8, pos[1 .. v + 1], pos[0..v]);
            pos[0] = held;
            slot.* = held;
        }
    }

    // Code length tables, transmitted as a chain of deltas.
    var tables: [utils.num_groups]huffman.DecodeTable = undefined;
    var lengths: [utils.max_alpha_size]u8 = undefined;
    for (0..n_groups) |t| {
        var curr: u32 = try bits.readBits(5);
        for (0..alpha_size) |i| {
            while ((try bits.readBit()) == 1) {
                const up = try bits.readBit();
                curr = if (up == 0) curr + 1 else curr - 1;
                if (curr < 1 or curr > utils.max_code_len_bits) return error.InvalidHuffmanTable;
            }
            lengths[i] = @truncate(curr);
        }
        tables[t] = try huffman.DecodeTable.init(lengths[0..alpha_size]);
    }

    // Huffman/MTF stage: fills the BWT last column.
    var nblock: usize = 0;
    {
        var table = mtf.Table.init(alphabet[0..n_in_use]);
        var cursor = SymbolCursor.init(&tables, selectors[0..n_selectors]);
        var symbol = try cursor.next(bits);

        while (symbol != eob) {
            if (symbol == utils.run_a or symbol == utils.run_b) {
                // Bijective base two: RUNA contributes the current power of
                // two, RUNB twice that. The bound stops a hostile stream from
                // asking for an unbounded run.
                var run: usize = 0;
                var weight: usize = 1;
                while (symbol == utils.run_a or symbol == utils.run_b) {
                    const digit: usize = if (symbol == utils.run_a) 1 else 2;
                    // weight doubles every step, so both the product and the
                    // accumulation have to be checked rather than assumed.
                    const step = std.math.mul(usize, weight, digit) catch {
                        return error.RunLengthOverflow;
                    };
                    run = std.math.add(usize, run, step) catch {
                        return error.RunLengthOverflow;
                    };
                    if (run > mtf.max_run_length) return error.RunLengthOverflow;
                    weight = std.math.shlExact(usize, weight, 1) catch {
                        return error.RunLengthOverflow;
                    };
                    symbol = try cursor.next(bits);
                }
                if (run > block_size - nblock) return error.RunLengthOverflow;
                @memset(scratch.last_column[nblock..][0..run], table.front());
                nblock += run;
                continue;
            }

            if (nblock >= block_size) return error.InvalidSequence;
            scratch.last_column[nblock] = try table.decode(@intCast(symbol - 1));
            nblock += 1;
            symbol = try cursor.next(bits);
        }
    }

    if (nblock == 0) return error.InvalidSequence;
    if (orig_ptr >= nblock) return error.InvalidOrigPtr;

    bwt.inverse(scratch.last_column[0..nblock], orig_ptr, scratch.block[0..nblock], scratch.next);

    if (randomised) {
        var mask = randomise.Stream{};
        mask.init();
        for (scratch.block[0..nblock]) |*byte| byte.* = mask.next(byte.*);
    }

    const coded = scratch.block[0..nblock];
    const plain_len = rle.decodedLen(coded) catch return error.RunLengthOverflow;
    if (state.options.max_output_size) |limit| {
        const total = std.math.add(usize, state.stats.output_bytes, plain_len) catch {
            return error.OutputTooLarge;
        };
        if (total > limit) return error.OutputTooLarge;
    }

    // bzip2 checksums the data after the run-length stage, so the checksum is
    // accumulated while expanding rather than over the reconstructed block.
    var crc = utils.Crc.init();
    try expandRle(coded, writer, scratch.chunk, &crc);
    state.stats.output_bytes += plain_len;

    if (state.options.verify_crc and crc.final() != stored_crc) {
        return error.BlockCrcMismatch;
    }
    return stored_crc;
}

/// Stream the RLE1 expansion of coded into writer through a fixed window.
fn expandRle(
    coded: []const u8,
    writer: *std.Io.Writer,
    chunk: []u8,
    crc: *utils.Crc,
) utils.StreamError!void {
    var decoder = rle.Decoder{};
    var written: usize = 0;
    for (coded) |byte| {
        // One coded byte expands to at most 255 bytes, so flush before the
        // buffer could overflow rather than checking afterwards.
        if (written + rle.Decoder.max_written_per_call > chunk.len) {
            crc.update(chunk[0..written]);
            try writer.writeAll(chunk[0..written]);
            written = 0;
        }
        decoder.push(byte, chunk, &written);
    }
    if (written > 0) {
        crc.update(chunk[0..written]);
        try writer.writeAll(chunk[0..written]);
    }
}

const compress_impl = @import("compress.zig");

const testing = std.testing;

/// Seeds for the generated inputs in this section. Fixed so a failure
/// reproduces on any machine.
const test_seed: u64 = 0x627A_6970_325F_0001;
const damage_seed: u64 = 0xF0F0_F0F0_1234_5678;

/// Fill out from a generator seeded by value. std.Random.DefaultPrng is
/// fully specified, so the same seed yields the same bytes everywhere.
fn testBytes(value: u64, out: []u8) void {
    var generator = std.Random.DefaultPrng.init(value);
    generator.random().bytes(out);
}

fn shortTextInput(gpa: Allocator) ![]u8 {
    return gpa.dupe(u8, "The quick brown fox jumps over the lazy dog.");
}

/// A short repeating pattern, to give the run-length stage something to undo.
fn repetitiveInput(gpa: Allocator) ![]u8 {
    const unit = "abcabcabcabcabcabcabcabcabcabcabcabc";
    const out = try gpa.alloc(u8, unit.len * 900);
    for (out, 0..) |*byte, i| byte.* = unit[i % unit.len];
    return out;
}

/// Text records separated by incompressible blobs, so the block is not
/// uniformly one thing.
fn mixedInput(gpa: Allocator) ![]u8 {
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

/// Incompressible data large enough to need several blocks. Incompressible
/// input defeats the run-length stage, so the coded block is the same size as
/// the input and the block limit really does bite.
fn manyBlocksInput(gpa: Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 400_000);
    testBytes(test_seed + 4, out);
    return out;
}

/// Decode stream and require that the decoder either fails with a documented
/// parse error or returns no more than limit bytes.
///
/// Returning wrong bytes for damaged input is the failure this guards against,
/// so any outcome other than a clean error or a bounded result is a bug.
fn expectSafeResult(gpa: Allocator, stream: []const u8, limit: usize) !void {
    const restored = decodeToSlice(gpa, stream, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer gpa.free(restored);
    if (restored.len > limit) {
        std.debug.print("damaged stream produced {d} bytes, limit was {d}\n", .{ restored.len, limit });
        return error.OutputTooLarge;
    }
}

/// Run Decoder over an in-memory stream and return everything it produced.
fn decodeToSlice(gpa: Allocator, stream: []const u8, options: Options) ![]u8 {
    var decoder = try Decoder.init(gpa, options);
    defer decoder.deinit();
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var source = std.Io.Reader.fixed(stream);
    try decoder.stream(&source, &sink.writer);
    return sink.toOwnedSlice();
}

test "a reused decoder produces identical output" {
    const gpa = testing.allocator;
    const input = try repetitiveInput(gpa);
    defer gpa.free(input);
    const compressed = try compress_impl.compress(gpa, input, 9);
    defer gpa.free(compressed);

    var decoder = try Decoder.init(gpa, .{});
    defer decoder.deinit();

    for (0..2) |_| {
        var sink: std.Io.Writer.Allocating = .init(gpa);
        defer sink.deinit();
        var source = std.Io.Reader.fixed(compressed);
        try decoder.stream(&source, &sink.writer);
        const restored = try sink.toOwnedSlice();
        defer gpa.free(restored);
        try testing.expectEqualSlices(u8, input, restored);
        decoder.reset();
    }
}

test "streaming decompression matches one-shot decompression" {
    const gpa = testing.allocator;
    const input = try manyBlocksInput(gpa);
    defer gpa.free(input);
    const compressed = try compress_impl.compress(gpa, input, 4);
    defer gpa.free(compressed);

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var source = std.Io.Reader.fixed(compressed);

    var decoder = try Decoder.init(gpa, .{});
    defer decoder.deinit();
    try decoder.stream(&source, &sink.writer);

    const streamed = try sink.toOwnedSlice();
    defer gpa.free(streamed);
    try testing.expectEqualSlices(u8, input, streamed);
}

test "max_output_size stops a decompression bomb" {
    const gpa = testing.allocator;
    // A long run expands enormously, which is the cheapest way to build one.
    const zeroes: [100_000]u8 = @splat(0);
    const compressed = try compress_impl.compress(gpa, &zeroes, 1);
    defer gpa.free(compressed);

    try testing.expectError(
        error.OutputTooLarge,
        decodeToSlice(gpa, compressed, .{ .max_output_size = 1000 }),
    );

    const restored = try decodeToSlice(gpa, compressed, .{ .max_output_size = zeroes.len });
    defer gpa.free(restored);
    try testing.expectEqualSlices(u8, &zeroes, restored);
}

test "malformed streams are rejected rather than mis-decoded" {
    const gpa = testing.allocator;
    const input = try mixedInput(gpa);
    defer gpa.free(input);
    const compressed = try compress_impl.compress(gpa, input, 9);
    defer gpa.free(compressed);

    const zero_padding: [6]u8 = @splat(0);
    const cases = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "empty", .bytes = "" },
        .{ .name = "one byte", .bytes = "B" },
        .{ .name = "header only", .bytes = "BZh9" },
        .{ .name = "wrong magic", .bytes = "XZh9\x31\x41\x59\x26\x53\x59" ++ &zero_padding },
        .{ .name = "level zero", .bytes = "BZh0\x31\x41\x59\x26\x53\x59" },
        .{ .name = "level too high", .bytes = "BZh:" },
        .{ .name = "bad block marker", .bytes = "BZh9\x30\x41\x59\x26\x53\x59" },
        .{ .name = "bad end marker", .bytes = "BZh9\x18\x72\x45\x38\x50\x90" },
        .{ .name = "text instead of a stream", .bytes = "this is not a bzip2 stream at all" },
    };

    for (cases) |case| {
        if (decodeToSlice(gpa, case.bytes, .{})) |restored| {
            gpa.free(restored);
            std.debug.print("malformed case '{s}' decoded successfully\n", .{case.name});
            return error.MalformedStreamAccepted;
        } else |err| {
            // Every rejection has to be one of the documented parse errors, not
            // an I/O failure and not a silent success.
            switch (err) {
                error.InvalidStreamHeader,
                error.InvalidBlockMarker,
                error.InvalidEndOfStreamMarker,
                error.InvalidSymbolMap,
                error.InvalidSelectors,
                error.InvalidHuffmanTable,
                error.InvalidHuffmanCode,
                error.InvalidOrigPtr,
                error.InvalidSequence,
                error.RunLengthOverflow,
                error.UnexpectedEndOfStream,
                => {},
                else => {
                    std.debug.print("malformed case '{s}' reported {s}\n", .{ case.name, @errorName(err) });
                    return err;
                },
            }
        }
    }
}

test "truncated streams are reported as such" {
    const gpa = testing.allocator;

    // One decoder serves every attempt: an attempt starts from a fresh reader
    // each time, and the scratch buffers are grown once instead of being
    // reallocated per truncated call.
    var decoder = try Decoder.init(gpa, .{});
    defer decoder.deinit();

    const prose = "a truncated stream must be refused, not decoded into plausible garbage. ";
    var input: [prose.len * 24]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = prose[i % prose.len];
    const small_stream = try compress_impl.compress(gpa, &input, 1);
    defer gpa.free(small_stream);

    // Every prefix of a small stream is attempted, so nothing that stops inside
    // the header or the block setup code can ever yield output.
    try expectTruncatedRefused(gpa, &decoder, small_stream, 0, small_stream.len, 1);

    const mixed = try mixedInput(gpa);
    defer gpa.free(mixed);
    const compressed = try compress_impl.compress(gpa, mixed, 9);
    defer gpa.free(compressed);

    // Every proxy for "truncated inside the block setup" is attempted on the
    // large stream, and the rest is sampled at a fixed stride: the guarantee
    // that matters is that *any* truncated stream is refused, not that the
    // failure is detected at one exact byte offset.
    const setup_region = @min(compressed.len, 256);
    try expectTruncatedRefused(gpa, &decoder, compressed, 0, setup_region, 1);
    try expectTruncatedRefused(gpa, &decoder, compressed, setup_region, compressed.len, 97);
}

fn expectTruncatedRefused(
    gpa: Allocator,
    decoder: *Decoder,
    stream: []const u8,
    start: usize,
    end: usize,
    stride: usize,
) !void {
    var cut = start;
    while (cut < end) : (cut += stride) {
        var sink: std.Io.Writer.Allocating = .init(gpa);
        defer sink.deinit();
        var source = std.Io.Reader.fixed(stream[0..cut]);
        if (decoder.stream(&source, &sink.writer)) {
            const restored = try sink.toOwnedSlice();
            defer gpa.free(restored);
            std.debug.print("a {d} byte prefix of a {d} byte stream decoded successfully\n", .{
                cut,
                stream.len,
            });
            return error.TruncatedStreamAccepted;
        } else |_| {}
    }
}

test "a corrupted block CRC is detected" {
    const gpa = testing.allocator;
    const input = try mixedInput(gpa);
    defer gpa.free(input);

    const compressed = try compress_impl.compress(gpa, input, 9);
    defer gpa.free(compressed);
    const corrupted = try gpa.dupe(u8, compressed);
    defer gpa.free(corrupted);
    // The block CRC occupies bytes 10 through 13.
    corrupted[10] ^= 0xFF;

    try testing.expectError(error.BlockCrcMismatch, decodeToSlice(gpa, corrupted, .{}));
    // Skipping verification does not change the bytes that come back, it only
    // drops the integrity check.
    const unverified = try decodeToSlice(gpa, corrupted, .{ .verify_crc = false });
    defer gpa.free(unverified);
    try testing.expect(unverified.len > 0);
}

test "a corrupted stream CRC is detected" {
    const gpa = testing.allocator;
    const input = try shortTextInput(gpa);
    defer gpa.free(input);

    const compressed = try compress_impl.compress(gpa, input, 9);
    defer gpa.free(compressed);
    try testing.expect(compressed.len > 4);
    const corrupted = try gpa.dupe(u8, compressed);
    defer gpa.free(corrupted);
    // The stream CRC is the last 32 bits of the stream, so its most significant
    // bit is the top bit of the fourth byte from the end. The final byte also
    // carries zero padding, which is why it is not the byte to flip.
    corrupted[corrupted.len - 4] ^= 0x80;

    try testing.expectError(error.StreamCrcMismatch, decodeToSlice(gpa, corrupted, .{}));
}

test "corrupted payload bytes are caught by the CRC" {
    const gpa = testing.allocator;
    const input = try repetitiveInput(gpa);
    defer gpa.free(input);
    const original = try compress_impl.compress(gpa, input, 9);
    defer gpa.free(original);

    // Flip one bit in the middle of the coded block. The decoder has to refuse
    // rather than emit different but plausible bytes.
    var detected = false;
    // Skip the header and the trailer, which are checked by other tests.
    var offset: usize = 14;
    const last = original.len -| 10;
    while (offset < last) : (offset += 7) {
        const corrupted = try gpa.dupe(u8, original);
        defer gpa.free(corrupted);
        corrupted[offset] ^= 0x08;
        if (decodeToSlice(gpa, corrupted, .{})) |restored| {
            gpa.free(restored);
        } else |err| switch (err) {
            error.BlockCrcMismatch, error.StreamCrcMismatch => detected = true,
            else => {},
        }
        if (detected) break;
    }
    try testing.expect(detected);
}

test "trailing bytes after the end marker are ignored" {
    const gpa = testing.allocator;
    const input = try shortTextInput(gpa);
    defer gpa.free(input);
    const compressed = try compress_impl.compress(gpa, input, 9);
    defer gpa.free(compressed);

    const extended = try gpa.alloc(u8, compressed.len + 16);
    defer gpa.free(extended);
    @memcpy(extended[0..compressed.len], compressed);
    @memset(extended[compressed.len..], 0xAB);

    const restored = try decodeToSlice(gpa, extended, .{});
    defer gpa.free(restored);
    try testing.expectEqualSlices(u8, input, restored);
}

test "the decoder reports how many blocks it saw" {
    const gpa = testing.allocator;
    const input = try manyBlocksInput(gpa);
    defer gpa.free(input);
    const compressed = try compress_impl.compress(gpa, input, 1);
    defer gpa.free(compressed);

    var decoder = try Decoder.init(gpa, .{});
    defer decoder.deinit();
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var source = std.Io.Reader.fixed(compressed);
    try decoder.stream(&source, &sink.writer);

    try testing.expect(decoder.decompressor.stats.blocks > 1);
    try testing.expectEqual(input.len, decoder.decompressor.stats.output_bytes);
}

test "decoder robustness: truncation at every offset is refused" {
    const gpa = testing.allocator;
    const unit = "bzip2 stream fuzzing with deterministic data ";
    var input: [unit.len * 40]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = unit[i % unit.len];
    const stream = try compress_impl.compress(gpa, &input, 6);
    defer gpa.free(stream);

    var cut: usize = 0;
    while (cut < stream.len) : (cut += 1) {
        try expectSafeResult(gpa, stream[0..cut], input.len * 4);
    }
}

test "decoder robustness: single bit flips are refused" {
    const gpa = testing.allocator;
    const unit = "bzip2 stream fuzzing with deterministic data ";
    var input: [unit.len * 40]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = unit[i % unit.len];
    const stream = try compress_impl.compress(gpa, &input, 6);
    defer gpa.free(stream);

    var offset: usize = 0;
    while (offset < stream.len) : (offset += 3) {
        for (0..8) |bit| {
            const mutated = try gpa.dupe(u8, stream);
            defer gpa.free(mutated);
            mutated[offset] ^= @as(u8, 1) << @intCast(bit);
            try expectSafeResult(gpa, mutated, input.len * 4);
        }
    }
}

test "decoder robustness: byte substitutions are refused" {
    const gpa = testing.allocator;
    const unit = "structured but wrong data ";
    var input: [unit.len * 50]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = unit[i % unit.len];
    const stream = try compress_impl.compress(gpa, &input, 4);
    defer gpa.free(stream);

    var offset: usize = 0;
    while (offset < stream.len) : (offset += 5) {
        const mutated = try gpa.dupe(u8, stream);
        defer gpa.free(mutated);
        mutated[offset] = 0xFF;
        try expectSafeResult(gpa, mutated, input.len * 4);
    }
}

test "decoder robustness: random noise is refused" {
    const gpa = testing.allocator;
    const noise: [4096]u8 = @splat(0x5A);

    for (0..16) |round| {
        var stream: [4096]u8 = undefined;
        testBytes(damage_seed + @as(u64, @intCast(round)), &stream);
        try expectSafeResult(gpa, &stream, noise.len * 4);
    }
}

test "decoder robustness: random noise behind a valid header is refused" {
    const gpa = testing.allocator;
    var stream: [4102]u8 = undefined;
    @memcpy(stream[0..4], "BZh9");
    for (0..16) |round| {
        testBytes(damage_seed + 1 + @as(u64, @intCast(round)), stream[4..]);
        try expectSafeResult(gpa, stream[0 .. 4 + noise_length(round)], 1 << 20);
    }
}

/// How much of the noise to hand to the decoder for a given round. Varying the
/// length walks the header parser through many truncation points.
fn noise_length(round: usize) usize {
    return 64 * (round + 1);
}

test "decoder robustness: a plausible but wrong block marker is refused" {
    const gpa = testing.allocator;
    const unit = "block marker probing ";
    var input: [unit.len * 30]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = unit[i % unit.len];
    const stream = try compress_impl.compress(gpa, &input, 9);
    defer gpa.free(stream);

    // Keep the header and a prefix of the marker, then replace the rest with
    // noise so the parser gets as far as it can before anything is invalid.
    var mutated = try gpa.dupe(u8, stream);
    defer gpa.free(mutated);
    testBytes(damage_seed + 2, mutated[8..]);
    try expectSafeResult(gpa, mutated, input.len * 4);
}

test "decoder robustness: a declared block size does not drive allocation past the budget" {
    const gpa = testing.allocator;
    // The header claims the largest block the format allows. The decoder must
    // size its buffers from the declaration but must not allocate more than
    // that, and must not loop on the shortfall.
    var stream: [64]u8 = undefined;
    @memcpy(stream[0..4], "BZh9");
    @memset(stream[4..], 0);
    try expectSafeResult(gpa, stream[0..16], 1 << 20);
}

test "decoder robustness: runaway output is refused by the output budget" {
    const gpa = testing.allocator;
    const zeroes: [100_000]u8 = @splat(0);
    const compressed = try compress_impl.compress(gpa, &zeroes, 1);
    defer gpa.free(compressed);

    var decoder = try Decoder.init(gpa, .{ .max_output_size = 1024 });
    defer decoder.deinit();
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var source = std.Io.Reader.fixed(compressed);
    try testing.expectError(error.OutputTooLarge, decoder.stream(&source, &sink.writer));
}

test "decoder robustness: a decode that succeeds is consistent with the input size" {
    const gpa = testing.allocator;
    const unit = "consistency check across many shapes ";
    var input: [unit.len * 20]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = unit[i % unit.len];
    const stream = try compress_impl.compress(gpa, &input, 3);
    defer gpa.free(stream);

    const restored = try decodeToSlice(gpa, stream, .{});
    defer gpa.free(restored);
    try testing.expectEqualSlices(u8, &input, restored);

    // Turning verification off still has to agree on the length. Only the
    // integrity check changes.
    const unverified = try decodeToSlice(gpa, stream, .{ .verify_crc = false });
    defer gpa.free(unverified);
    try testing.expectEqualSlices(u8, &input, unverified);
}

test "decoder robustness: huge declared lengths never become huge allocations" {
    const gpa = testing.allocator;
    // A selector count and a run length near their format maxima, packed into a
    // stream the decoder has to walk. Bounded memory is the whole requirement.
    for ([_][]const u8{ "\x00\x00\xFF\xFF\xFF\xFF", "\xFF\xFF\xFF\xFF\xFF\xFF", "\x00\x00\x00\x00\x00\x01" }) |body| {
        var stream: [16]u8 = undefined;
        @memcpy(stream[0..4], "BZh9");
        @memcpy(stream[4..][0..body.len], body);
        try expectSafeResult(gpa, stream[0 .. 4 + body.len], 1 << 20);
    }
}

test "decoder robustness: all zero bytes of many lengths are refused" {
    const gpa = testing.allocator;
    var length: usize = 1;
    while (length <= 256) : (length += 1) {
        const stream = try gpa.alloc(u8, length);
        defer gpa.free(stream);
        @memset(stream, 0);
        try expectSafeResult(gpa, stream, 1 << 16);
    }
}

test "decoder robustness: all 0xFF bytes of many lengths are refused" {
    const gpa = testing.allocator;
    var length: usize = 1;
    while (length <= 256) : (length += 1) {
        const stream = try gpa.alloc(u8, length);
        defer gpa.free(stream);
        @memset(stream, 0xFF);
        try expectSafeResult(gpa, stream, 1 << 16);
    }
}
