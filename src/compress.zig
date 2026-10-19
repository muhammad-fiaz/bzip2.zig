//! The bzip2 encoder.
//!
//! A stream is produced by feeding bytes into Compressor.write and closing
//! with Compressor.finish. The compressor holds at most one block in memory,
//! which is unavoidable: bzip2's block-sorting stage cannot emit anything for a
//! block until the whole block has been seen.
//!
//! input -> RLE1 -> block -> BWT -> last column -> MTF and RUNA/RUNB -> Huffman -> bits
//!
//! The per-block CRC covers the RLE1-coded block, and the stream CRC is the
//! running combination of every block CRC.
//!
//! The encoder follows the same heuristics every other BZip2 implementation
//! uses (block splitting threshold, table count, refinement passes) so that
//! output is stable for a given level and input.

const std = @import("std");
const Allocator = std.mem.Allocator;

const bwt = @import("bwt.zig");
const huffman = @import("huffman.zig");
const mtf = @import("mtf.zig");
const rle = @import("rle.zig");
const utils = @import("utils.zig");

/// Tuning knobs for Compressor.
pub const Options = struct {
    /// Compression level, 1..9. The level is the block size in units of
    /// 100 kB: a higher level sorts fewer, larger blocks, which usually
    /// compresses slightly better at the cost of memory and time.
    level: u8 = 9,

    /// Validate the level and return the resulting block size in bytes.
    pub fn checkedBlockSize(self: Options) utils.Error!usize {
        if (self.level < utils.min_level or self.level > utils.max_level) {
            return error.InvalidCompressionLevel;
        }
        return @as(usize, self.level) * utils.block_unit;
    }
};

/// Per-block scratch buffers, allocated once and reused for every block.
const BlockScratch = struct {
    /// RLE1-coded block bytes. Carries headroom because one input byte can
    /// expand to five.
    block: []u8,
    /// BWT last column, one byte per block byte.
    last_column: []u8,
    /// MTF values: at most one per block byte, plus the end-of-block symbol.
    values: []u16,
    /// Which bytes occur in the current block.
    in_use: [256]bool = @splat(false),
    /// Histogram over the MTF alphabet of the current block.
    freq: [utils.max_alpha_size]u32 = @splat(0),
    /// Working frequencies while fitting the tables.
    rfreq: [utils.num_groups][utils.max_alpha_size]u32 = @splat(@as([utils.max_alpha_size]u32, @splat(0))),
    /// Code length per table per symbol.
    lengths: [utils.num_groups][utils.max_alpha_size]u8 = @splat(@as([utils.max_alpha_size]u8, @splat(0))),
    /// Canonical code per table per symbol.
    codes: [utils.num_groups][utils.max_alpha_size]u32 = @splat(@as([utils.max_alpha_size]u32, @splat(0))),
    /// Table chosen for each group of group_size MTF symbols.
    selectors: [utils.max_selectors]u8 = undefined,
    /// Selector identities after move-to-front coding.
    selector_mtf: [utils.max_selectors]u8 = undefined,

    /// Allocate the block-sized buffers. Each allocation is guarded so that a
    /// failure part way through releases what was already taken, rather than
    /// leaving the earlier buffers behind with no owner.
    fn init(gpa: Allocator, block_size: usize) Allocator.Error!BlockScratch {
        const block = try gpa.alloc(u8, block_size + rle.Encoder.max_written_per_call);
        errdefer gpa.free(block);
        const last_column = try gpa.alloc(u8, block_size);
        errdefer gpa.free(last_column);
        const values = try gpa.alloc(u16, block_size + 1);
        return .{ .block = block, .last_column = last_column, .values = values };
    }

    fn deinit(self: *BlockScratch, gpa: Allocator) void {
        gpa.free(self.block);
        gpa.free(self.last_column);
        gpa.free(self.values);
        self.* = undefined;
    }
};

/// Streaming bzip2 encoder.
pub const Compressor = struct {
    gpa: Allocator,
    options: Options,
    /// Block size in bytes, level * 100_000.
    block_size: usize,
    /// A block is closed once it holds this many RLE1-coded bytes.
    /// One input byte can still push it four further, which is why the
    /// scratch block buffer carries headroom.
    block_limit: usize,
    scratch: BlockScratch,
    bwt_scratch: bwt.Scratch,
    rle: rle.Encoder = .{},
    /// RLE1-coded bytes currently in scratch.block.
    nblock: usize = 0,
    /// Running checksum of the untransformed bytes that make up the block under
    /// construction. bzip2 checksums the data before the run-length stage, so
    /// this cannot be recomputed from scratch.block.
    block_crc: utils.Crc = utils.Crc.init(),
    combined_crc: u32 = 0,
    /// Blocks emitted so far; useful for tests and progress reporting.
    block_count: u64 = 0,
    header_written: bool = false,
    finished: bool = false,
    /// Set once the sink has rejected output. The stream is unrecoverable at
    /// that point: the bytes already handed to the sink cannot be taken back,
    /// and the encoder no longer knows how much of a block reached the sink.
    /// The compressor refuses further work until reset.
    poisoned: bool = false,
    /// Per-block shape, valid between fitTables and emitPayload.
    alpha_size: usize = 0,
    n_groups: usize = 0,
    n_selectors: usize = 0,
    /// Bits pending at a block boundary. A block rarely ends on a byte
    /// boundary, so the partial byte has to be carried into the next block.
    bit_state: utils.BitWriter.State = .{},

    /// Create a compressor. The level in options must be in 1..9.
    pub fn init(gpa: Allocator, options: Options) (Allocator.Error || utils.Error)!Compressor {
        const block_size = try options.checkedBlockSize();
        var scratch = try BlockScratch.init(gpa, block_size);
        errdefer scratch.deinit(gpa);
        var bwt_scratch = try bwt.Scratch.init(gpa, block_size);
        errdefer bwt_scratch.deinit(gpa);

        return .{
            .gpa = gpa,
            .options = options,
            .block_size = block_size,
            .block_limit = block_size - 19,
            .scratch = scratch,
            .bwt_scratch = bwt_scratch,
        };
    }

    pub fn deinit(self: *Compressor) void {
        self.scratch.deinit(self.gpa);
        self.bwt_scratch.deinit(self.gpa);
        self.* = undefined;
    }

    /// Drop everything buffered and start a fresh stream. The allocated
    /// buffers are kept, so a long-lived compressor never reallocates.
    ///
    /// This is also how a compressor that gave up on a full destination is
    /// recovered: after a write failure the caller discards whatever reached
    /// the sink, calls reset, and starts over.
    pub fn reset(self: *Compressor) void {
        self.rle.reset();
        self.nblock = 0;
        self.combined_crc = 0;
        self.block_count = 0;
        self.block_crc = utils.Crc.init();
        self.header_written = false;
        self.finished = false;
        self.poisoned = false;
        self.bit_state = .{};
    }

    /// Compress bytes, writing every block that becomes complete to writer.
    ///
    /// The call is lazy: nothing reaches writer until a block fills, so a
    /// destination can stay untouched for a long time on inputs smaller than one
    /// block. finish is what flushes the pending block and the trailer, and it
    /// is required.
    ///
    /// Because output is produced per block rather than per call, a caller
    /// supplying its own buffer has to size it for the whole stream.
    /// maxCompressedSize is an upper bound that is sufficient for that. If the
    /// sink runs out of room the call returns the sink's error and the
    /// compressor stops accepting input, because the bytes that did reach the
    /// sink cannot be taken back. reset starts a fresh stream.
    pub fn write(self: *Compressor, writer: *std.Io.Writer, bytes: []const u8) utils.StreamError!void {
        if (self.poisoned) return error.WriteFailed;
        return self.writeBody(writer, bytes) catch |err| {
            if (err == error.WriteFailed or err == error.DiskFull) self.poisoned = true;
            return err;
        };
    }

    fn writeBody(self: *Compressor, writer: *std.Io.Writer, bytes: []const u8) utils.StreamError!void {
        if (self.finished) return error.UnexpectedEndOfStream;
        try self.writeHeader(writer);

        const block = self.scratch.block;
        var n = self.nblock;
        for (bytes) |byte| {
            const committed = self.rle.push(byte, block, &n);
            if (committed.isAny()) utils.crcRepeat(&self.block_crc, committed.byte, committed.count);
            // The limit is tested after the append rather than before, which is
            // equivalent and keeps a run that straddles a block boundary
            // intact.
            if (n >= self.block_limit) {
                self.nblock = n;
                try self.emitBlock(writer);
                n = 0;
            }
        }
        self.nblock = n;
    }

    /// Flush the pending block, write the stream trailer and zero-pad the final
    /// byte. The compressor is unusable afterwards; call reset to reuse it.
    ///
    /// This is also where a destination that is too small is reported, because
    /// output is produced per block rather than per write.
    pub fn finish(self: *Compressor, writer: *std.Io.Writer) utils.StreamError!void {
        if (self.poisoned) return error.WriteFailed;
        return self.finishBody(writer) catch |err| {
            if (err == error.WriteFailed or err == error.DiskFull) self.poisoned = true;
            return err;
        };
    }

    fn finishBody(self: *Compressor, writer: *std.Io.Writer) utils.StreamError!void {
        if (self.finished) return error.UnexpectedEndOfStream;
        try self.writeHeader(writer);

        const block = self.scratch.block;
        var n = self.nblock;
        const committed = self.rle.flush(block, &n);
        if (committed.isAny()) utils.crcRepeat(&self.block_crc, committed.byte, committed.count);
        self.nblock = n;
        try self.emitBlock(writer);
        self.nblock = 0;

        var bw = utils.BitWriter.initState(writer, self.bit_state);
        for (utils.end_magic) |b| try bw.putByte(b);
        try bw.putU32(self.combined_crc);
        try bw.finish();
        self.bit_state = .{};
        self.finished = true;
    }

    fn writeHeader(self: *Compressor, writer: *std.Io.Writer) utils.StreamError!void {
        if (self.header_written) return;
        var bw = utils.BitWriter.init(writer);
        try bw.putByte(utils.magic_b);
        try bw.putByte(utils.magic_z);
        try bw.putByte(utils.magic_h);
        try bw.putByte(utils.magic_0 + self.options.level);
        try bw.flush();
        self.header_written = true;
    }

    /// Encode and emit scratch.block[0..nblock] as one bzip2 block.
    ///
    /// An empty block emits nothing at all, which is what makes an empty input
    /// produce a 14 byte stream: header, trailer, zero CRC.
    fn emitBlock(self: *Compressor, writer: *std.Io.Writer) utils.StreamError!void {
        const nblock = self.nblock;
        if (nblock == 0) return;

        const block = self.scratch.block[0..nblock];
        const block_crc = self.block_crc.final();
        self.block_crc = utils.Crc.init();
        self.combined_crc = utils.combineCrc(self.combined_crc, block_crc);
        self.block_count += 1;

        var orig_ptr: u32 = 0;
        bwt.forward(
            &self.bwt_scratch,
            block,
            self.scratch.last_column[0..nblock],
            &orig_ptr,
        );

        const n_values = try self.generateMtfValues(block);
        try self.fitTables(n_values);

        var bw = utils.BitWriter.initState(writer, self.bit_state);
        for (utils.block_magic) |b| try bw.putByte(b);
        try bw.putU32(block_crc);
        // No encoder since bzip2 0.9.5 produces randomised blocks; the flag
        // stays in the format for backwards compatibility and the decoder
        // still honours it.
        try bw.putBit(0);
        try bw.putBits(orig_ptr, 24);
        try self.emitPayload(&bw, n_values);
        try bw.flush();
        self.bit_state = bw.captureState();
    }

    /// Turn the BWT last column into MTF values plus RUNA/RUNB run symbols.
    /// Returns the number of symbols written.
    ///
    /// The symbol map has to be derived from the coded block rather than from
    /// the raw input: the RLE1 count byte is itself part of the block and its
    /// value may not occur in the original data at all.
    fn generateMtfValues(self: *Compressor, block: []const u8) utils.Error!usize {
        @memset(&self.scratch.in_use, false);
        for (block) |byte| self.scratch.in_use[byte] = true;

        var alphabet: [256]u8 = undefined;
        var n_in_use: usize = 0;
        for (self.scratch.in_use, 0..) |used, byte| {
            if (used) {
                alphabet[n_in_use] = @intCast(byte);
                n_in_use += 1;
            }
        }
        self.alpha_size = n_in_use + 2;
        const eob: u16 = @intCast(n_in_use + 1);

        var table = mtf.Table.init(alphabet[0..n_in_use]);
        const last_column = self.scratch.last_column[0..block.len];
        const values = self.scratch.values;

        var written: usize = 0;
        var pending: usize = 0;
        for (last_column) |byte| {
            if (byte == table.front()) {
                pending += 1;
                continue;
            }
            if (pending > 0) {
                written += mtf.encodeRunLength(values[written..], pending);
                pending = 0;
            }
            // A block that uses all 256 byte values reaches distance 255, and the
            // stored symbol is that distance plus one, so the arithmetic has to
            // be done in the MTF alphabet width rather than in u8.
            values[written] = @as(u16, try table.encode(byte)) + 1;
            written += 1;
        }
        if (pending > 0) written += mtf.encodeRunLength(values[written..], pending);
        values[written] = eob;
        written += 1;

        const freq = &self.scratch.freq;
        @memset(freq[0..self.alpha_size], 0);
        for (values[0..written]) |v| freq[v] += 1;
        return written;
    }

    /// Choose the number of tables, the selectors and the code lengths for the
    /// current block.
    fn fitTables(self: *Compressor, n_values: usize) utils.Error!void {
        const values = self.scratch.values[0..n_values];
        const freq = &self.scratch.freq;
        const alpha_size = self.alpha_size;

        // Number of coding tables: more symbols, more tables. The thresholds
        // trade table overhead against the gain from adapting each code to a
        // slice of the symbol stream.
        self.n_groups = if (n_values < 200)
            2
        else if (n_values < 600)
            3
        else if (n_values < 1200)
            4
        else if (n_values < 2400)
            5
        else
            6;
        const n_groups: usize = self.n_groups;

        const lengths = &self.scratch.lengths;
        const rfreq = &self.scratch.rfreq;
        for (0..utils.num_groups) |t| @memset(lengths[t][0..], huffman.greater_icost);
        for (0..utils.num_groups) |t| @memset(rfreq[t][0..], 0);

        // Seed each table with the symbols of its own contiguous frequency
        // band. Symbols outside a table's band get a prohibitive cost, so the
        // selector search avoids them.
        var n_part: usize = n_groups;
        var remaining: i64 = @intCast(n_values);
        var gs: i32 = 0;
        while (n_part > 0) {
            n_part -= 1;
            const target = @divTrunc(remaining, @as(i64, @intCast(n_part + 1)));
            var ge: i32 = gs - 1;
            var a_freq: i64 = 0;
            while (a_freq < target and ge < @as(i32, @intCast(alpha_size)) - 1) {
                ge += 1;
                a_freq += freq[@intCast(ge)];
            }
            // Odd-sized splits are nudged backwards so the number of remaining
            // tables stays even, which keeps later bands non-empty.
            if (ge > gs and n_part + 1 != n_groups and n_part != 0 and
                ((n_groups - (n_part + 1)) % 2 == 1))
            {
                a_freq -= freq[@intCast(ge)];
                ge -= 1;
            }
            for (0..alpha_size) |v| {
                const value: i32 = @intCast(v);
                lengths[n_part][v] = if (value >= gs and value <= ge) huffman.lesser_icost else huffman.greater_icost;
            }
            gs = ge + 1;
            remaining -= a_freq;
        }

        var n_selectors: usize = 0;
        var iterations: usize = 0;
        while (iterations < utils.num_iters) : (iterations += 1) {
            for (0..utils.num_groups) |t| @memset(rfreq[t][0..], 0);
            // Every refinement pass re-decides which table each group uses, so
            // only the last pass's choice survives.
            n_selectors = 0;

            var group_start: usize = 0;
            while (group_start < n_values) {
                const group_end = @min(group_start + utils.group_size, n_values);

                // Cost of coding this group with each candidate table.
                var best: usize = 0;
                var best_cost: u32 = std.math.maxInt(u32);
                for (0..n_groups) |t| {
                    var total: u32 = 0;
                    for (values[group_start..group_end]) |v| total += lengths[t][v];
                    if (total < best_cost) {
                        best_cost = total;
                        best = t;
                    }
                }
                // n_values is bounded by the block size, so this cannot overflow
                // the selector array in practice. Checked rather than asserted so
                // release builds fail cleanly instead of writing out of bounds.
                if (n_selectors >= self.scratch.selectors.len) return error.InvalidSelectors;
                self.scratch.selectors[n_selectors] = @intCast(best);
                n_selectors += 1;

                for (values[group_start..group_end]) |v| rfreq[best][v] += 1;
                group_start = group_end;
            }

            for (0..n_groups) |t| {
                huffman.makeCodeLengths(
                    lengths[t][0..alpha_size],
                    rfreq[t][0..alpha_size],
                    huffman.encoder_max_len,
                );
            }
        }
        std.debug.assert(n_selectors <= utils.max_selectors);
        self.n_selectors = n_selectors;

        // Move-to-front the selector identities before transmitting them.
        var pos: [utils.num_groups]u8 = undefined;
        for (0..n_groups) |i| pos[i] = @intCast(i);
        for (self.scratch.selectors[0..n_selectors], 0..) |selector, i| {
            // selector is a table index the cost search produced, so it is
            // always present. The bound is here anyway: scanning past the end
            // would read out of bounds rather than fail.
            var j: usize = 0;
            while (j < n_groups and pos[j] != selector) j += 1;
            if (j == n_groups) return error.InvalidSelectors;
            self.scratch.selector_mtf[i] = @intCast(j);
            const held = pos[j];
            std.mem.copyBackwards(u8, pos[1 .. j + 1], pos[0..j]);
            pos[0] = held;
        }

        for (0..n_groups) |t| {
            var min_len: u8 = 32;
            var max_len: u8 = 0;
            for (lengths[t][0..alpha_size]) |len| {
                min_len = @min(min_len, len);
                max_len = @max(max_len, len);
            }
            std.debug.assert(max_len <= huffman.encoder_max_len and min_len >= 1);
            huffman.assignCodes(
                self.scratch.codes[t][0..alpha_size],
                lengths[t][0..alpha_size],
                min_len,
                max_len,
            );
        }
    }

    /// Write the symbol map, the selectors, the code length tables and the
    /// coded MTF symbols.
    fn emitPayload(
        self: *Compressor,
        bw: *utils.BitWriter,
        n_values: usize,
    ) utils.StreamError!void {
        var in_use16: [16]bool = @splat(false);
        for (0..16) |i| {
            for (0..16) |j| {
                if (self.scratch.in_use[i * 16 + j]) in_use16[i] = true;
            }
        }
        for (in_use16) |set| try bw.putBit(@intFromBool(set));
        for (in_use16, 0..) |set, i| {
            if (!set) continue;
            for (0..16) |j| try bw.putBit(@intFromBool(self.scratch.in_use[i * 16 + j]));
        }

        try bw.putBits(@intCast(self.n_groups), 3);
        try bw.putBits(@intCast(self.n_selectors), 15);

        for (self.scratch.selector_mtf[0..self.n_selectors]) |v| {
            for (0..v) |_| try bw.putBit(1);
            try bw.putBit(0);
        }

        for (0..self.n_groups) |t| {
            const lengths = self.scratch.lengths[t][0..self.alpha_size];
            // The transmitted form is a chain of deltas: "one" means "one more
            // bit", then a single bit saying whether to add or subtract, and a
            // zero terminates each symbol's length. Symbol zero still emits its
            // terminator even though it never needs a delta.
            var curr: u8 = lengths[0];
            try bw.putBits(curr, 5);
            for (lengths) |target| {
                while (curr < target) : (curr += 1) try bw.putBits(2, 2);
                while (curr > target) : (curr -= 1) try bw.putBits(3, 2);
                try bw.putBit(0);
            }
        }

        const values = self.scratch.values[0..n_values];
        var group_start: usize = 0;
        var selector_index: usize = 0;
        while (group_start < n_values) {
            const group_end = @min(group_start + utils.group_size, n_values);
            // fitTables wrote one selector per group, so the counts agree.
            // The bound keeps a mismatch from indexing past the array.
            if (selector_index >= self.scratch.selectors.len) return error.InvalidSelectors;
            const table = self.scratch.selectors[selector_index];
            for (values[group_start..group_end]) |v| {
                try bw.putBits(
                    self.scratch.codes[table][v],
                    @intCast(self.scratch.lengths[table][v]),
                );
            }
            group_start = group_end;
            selector_index += 1;
        }
        std.debug.assert(selector_index == self.n_selectors);
    }
};

/// Compress input into a freshly allocated slice.
pub fn compress(gpa: Allocator, input: []const u8, level: u8) utils.StreamError![]u8 {
    var sink: std.Io.Writer.Allocating = .init(gpa);
    errdefer sink.deinit();

    var compressor = try Compressor.init(gpa, .{ .level = level });
    defer compressor.deinit();

    try compressor.write(&sink.writer, input);
    try compressor.finish(&sink.writer);
    return sink.toOwnedSlice();
}

const testing = std.testing;

/// Seed for the generated inputs in this section. Fixed so a failure
/// reproduces on any machine.
const test_seed: u64 = 0x627A_6970_325F_0001;

/// Fill out from a generator seeded by value. std.Random.DefaultPrng is
/// fully specified, so the same seed yields the same bytes everywhere.
fn testBytes(value: u64, out: []u8) void {
    var generator = std.Random.DefaultPrng.init(value);
    generator.random().bytes(out);
}

/// A short repeating pattern. Long enough to exercise the run-length stage,
/// long enough to be worth compressing.
fn repetitiveInput(gpa: Allocator) ![]u8 {
    const unit = "abcabcabcabcabcabcabcabcabcabcabcabc";
    const out = try gpa.alloc(u8, unit.len * 900);
    for (out, 0..) |*byte, i| byte.* = unit[i % unit.len];
    return out;
}

/// Text records separated by incompressible blobs, which makes the block
/// content vary in the way real input does.
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

/// Incompressible data large enough to need several blocks at every level.
/// Incompressible input defeats the run-length stage, so the coded block is the
/// same size as the input and the block limit really does bite.
fn manyBlocksInput(gpa: Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 400_000);
    testBytes(test_seed + 4, out);
    return out;
}

test "empty input produces a header, a trailer and nothing else" {
    const compressed = try compress(testing.allocator, "", 9);
    defer testing.allocator.free(compressed);

    try testing.expectEqualSlices(u8, "BZh9", compressed[0..4]);
    try testing.expectEqualSlices(u8, &utils.end_magic, compressed[4..10]);
    const zeros: [4]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &zeros, compressed[10..14]);
    try testing.expectEqual(@as(usize, 14), compressed.len);
}

test "the compressor refuses a level outside 1..9" {
    try testing.expectError(
        error.InvalidCompressionLevel,
        Compressor.init(testing.allocator, .{ .level = 0 }),
    );
    try testing.expectError(
        error.InvalidCompressionLevel,
        Compressor.init(testing.allocator, .{ .level = 10 }),
    );
}

test "every level writes its own block size into the header" {
    var input_buf: [4096]u8 = undefined;
    const sentence = "The quick brown fox jumps over the lazy dog. ";
    var input_len: usize = 0;
    while (input_len + sentence.len <= input_buf.len) {
        @memcpy(input_buf[input_len..][0..sentence.len], sentence);
        input_len += sentence.len;
    }
    const input = input_buf[0..input_len];

    for (1..10) |level| {
        const compressed = try compress(testing.allocator, input, @intCast(level));
        defer testing.allocator.free(compressed);

        try testing.expectEqualSlices(u8, "BZh", compressed[0..3]);
        try testing.expectEqual(@as(u8, utils.magic_0 + @as(u8, @intCast(level))), compressed[3]);

        // The trailer is bit packed, so its marker is not byte aligned. The
        // last four bytes are the combined CRC, and decoding it back is what
        // proves the stream is complete.
        var source = std.Io.Reader.fixed(compressed);
        var sink: std.Io.Writer.Allocating = .init(testing.allocator);
        defer sink.deinit();
        var decoder = try @import("decompress.zig").Decoder.init(testing.allocator, .{});
        defer decoder.deinit();
        try decoder.stream(&source, &sink.writer);
        const restored = try sink.toOwnedSlice();
        defer testing.allocator.free(restored);
        try testing.expectEqualSlices(u8, input, restored);
    }
}

test "reset restarts the stream byte for byte" {
    const gpa = testing.allocator;
    var compressor = try Compressor.init(gpa, .{ .level = 1 });
    defer compressor.deinit();

    var first: std.Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    try compressor.write(&first.writer, "hello hello hello");
    try compressor.finish(&first.writer);
    const first_bytes = try first.toOwnedSlice();
    defer gpa.free(first_bytes);

    compressor.reset();
    var second: std.Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    try compressor.write(&second.writer, "hello hello hello");
    try compressor.finish(&second.writer);
    const second_bytes = try second.toOwnedSlice();
    defer gpa.free(second_bytes);

    try testing.expectEqualSlices(u8, first_bytes, second_bytes);
}

test "a level 1 stream of more than one block emits more than one block" {
    const gpa = testing.allocator;
    // Incompressible input defeats the run-length stage, so the coded block is
    // the same size as the input and the 100 kB limit really does bite.
    var prng = std.Random.DefaultPrng.init(0xB10C_5EED);
    var input: [250_000]u8 = undefined;
    prng.random().bytes(&input);

    var compressor = try Compressor.init(gpa, .{ .level = 1 });
    defer compressor.deinit();
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try compressor.write(&sink.writer, &input);
    try compressor.finish(&sink.writer);

    try testing.expectEqual(@as(u64, 3), compressor.block_count);
}

test "compressible data shrinks to a small fraction of its size" {
    const gpa = testing.allocator;
    const input = try repetitiveInput(gpa);
    defer gpa.free(input);

    for (1..10) |level| {
        const compressed = try compress(gpa, input, @intCast(level));
        defer gpa.free(compressed);
        try testing.expect(compressed.len < input.len / 10);
        try testing.expectEqual(
            @as(usize, level) * utils.block_unit,
            @as(usize, compressed[3] - utils.magic_0) * utils.block_unit,
        );
    }
}

test "incompressible input stays bounded" {
    const gpa = testing.allocator;
    var input: [200_000]u8 = undefined;
    testBytes(test_seed, &input);

    const compressed = try compress(gpa, &input, 1);
    defer gpa.free(compressed);

    // The format has no stored-block mode, so random data grows slightly. What
    // matters is that it stays bounded rather than expanding without limit.
    try testing.expect(compressed.len < input.len + input.len / 2);
}

test "a reused compressor produces identical output" {
    const gpa = testing.allocator;
    var compressor = try Compressor.init(gpa, .{ .level = 6 });
    defer compressor.deinit();

    const input = try mixedInput(gpa);
    defer gpa.free(input);

    var runs: [2][]u8 = undefined;
    var count: usize = 0;
    defer for (0..count) |j| gpa.free(runs[j]);

    for (0..2) |i| {
        var sink: std.Io.Writer.Allocating = .init(gpa);
        defer sink.deinit();
        try compressor.write(&sink.writer, input);
        try compressor.finish(&sink.writer);
        runs[i] = try sink.toOwnedSlice();
        count = i + 1;
        compressor.reset();
    }
    try testing.expectEqual(runs[0].len, runs[1].len);
    try testing.expectEqualSlices(u8, runs[0], runs[1]);
}

test "chunked writes produce the same stream as one large write" {
    const gpa = testing.allocator;
    const input = try manyBlocksInput(gpa);
    defer gpa.free(input);

    var whole: std.Io.Writer.Allocating = .init(gpa);
    defer whole.deinit();
    var compressor = try Compressor.init(gpa, .{ .level = 2 });
    defer compressor.deinit();
    try compressor.write(&whole.writer, input);
    try compressor.finish(&whole.writer);
    const reference = try whole.toOwnedSlice();
    defer gpa.free(reference);

    // Boundaries that deliberately do not line up with block boundaries.
    var chunked: std.Io.Writer.Allocating = .init(gpa);
    defer chunked.deinit();
    var chunked_compressor = try Compressor.init(gpa, .{ .level = 2 });
    defer chunked_compressor.deinit();
    const sizes = [_]usize{ 1, 7, 3, 4096, 99991, 5, 250_000 };
    var offset: usize = 0;
    for (sizes) |size| {
        const end = @min(offset + size, input.len);
        try chunked_compressor.write(&chunked.writer, input[offset..end]);
        offset = end;
    }
    try chunked_compressor.write(&chunked.writer, input[offset..]);
    try chunked_compressor.finish(&chunked.writer);
    const produced = try chunked.toOwnedSlice();
    defer gpa.free(produced);

    try testing.expectEqualSlices(u8, reference, produced);
}

test "streaming a reader matches compressing it in one call" {
    const gpa = testing.allocator;
    const input = try manyBlocksInput(gpa);
    defer gpa.free(input);

    const one_shot = try compress(gpa, input, 9);
    defer gpa.free(one_shot);

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var source = std.Io.Reader.fixed(input);

    var compressor = try Compressor.init(gpa, .{ .level = 9 });
    defer compressor.deinit();
    while (true) {
        if (source.buffered().len == 0) {
            source.fillMore() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
        }
        const chunk = source.buffered();
        if (chunk.len == 0) break;
        try compressor.write(&sink.writer, chunk);
        source.toss(chunk.len);
    }
    try compressor.finish(&sink.writer);

    const streamed = try sink.toOwnedSlice();
    defer gpa.free(streamed);
    try testing.expectEqualSlices(u8, one_shot, streamed);
}

test "multi block input round trips at every level" {
    const gpa = testing.allocator;
    const decoder = @import("decompress.zig");
    const input = try manyBlocksInput(gpa);
    defer gpa.free(input);

    for ([_]u8{ 1, 3, 6, 9 }) |level| {
        const compressed = try compress(gpa, input, level);
        defer gpa.free(compressed);

        var source = std.Io.Reader.fixed(compressed);
        var sink: std.Io.Writer.Allocating = .init(gpa);
        defer sink.deinit();
        var owned = try decoder.Decoder.init(gpa, .{});
        defer owned.deinit();
        try owned.stream(&source, &sink.writer);
        const restored = try sink.toOwnedSlice();
        defer gpa.free(restored);
        try testing.expectEqualSlices(u8, input, restored);
    }
}

test "the declared bound is a true upper bound on the output" {
    // maxCompressedSize is what a caller uses to size a destination buffer, so
    // it has to hold for every input shape and every level. An input that
    // expands is the interesting case: RLE1 turns four literal bytes into five,
    // which is what the bound is built around.
    const gpa = testing.allocator;
    const inputs = [_][]const u8{
        try shortInput(gpa),
        try repetitiveInput(gpa),
        try mixedInput(gpa),
        try manyBlocksInput(gpa),
        try incompressibleInput(gpa),
        "",
    };
    defer for (inputs) |input| gpa.free(input);

    for (inputs) |input| {
        for (1..10) |level| {
            const compressed = try compress(gpa, input, @intCast(level));
            defer gpa.free(compressed);
            const bound = try @import("bzip2.zig").maxCompressedSize(input.len, @intCast(level));
            if (compressed.len > bound) {
                return error.BoundTooSmall;
            }
        }
    }
}

test "a destination that fills up stops the stream instead of truncating it" {
    const gpa = testing.allocator;
    const input = try mixedInput(gpa);
    defer gpa.free(input);

    var compressor = try Compressor.init(gpa, .{ .level = 1 });
    defer compressor.deinit();

    // Far too small for the stream. write is lazy and emits nothing until a
    // block fills, so the refusal surfaces at finish, which is the call that
    // has to flush the pending block and the trailer.
    var storage: [16]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&storage);

    try compressor.write(&fixed, input);
    try testing.expectError(error.WriteFailed, compressor.finish(&fixed));

    // Once the sink has refused output the compressor must not accept more.
    // Continuing would append to a stream the caller has already discarded.
    try testing.expectError(error.WriteFailed, compressor.write(&fixed, input));
    try testing.expectError(error.WriteFailed, compressor.finish(&fixed));

    // After reset it is usable again, and produces exactly what a fresh
    // compressor would.
    compressor.reset();
    var recovered: std.Io.Writer.Allocating = .init(gpa);
    defer recovered.deinit();
    try compressor.write(&recovered.writer, input);
    try compressor.finish(&recovered.writer);
    const after_recovery = try recovered.toOwnedSlice();
    defer gpa.free(after_recovery);

    const fresh = try compress(gpa, input, 1);
    defer gpa.free(fresh);
    try testing.expectEqualSlices(u8, fresh, after_recovery);
}

test "a destination sized from the declared bound always fits" {
    const gpa = testing.allocator;
    const input = try mixedInput(gpa);
    defer gpa.free(input);

    for ([_]u8{ 1, 5, 9 }) |level| {
        const bound = try @import("bzip2.zig").maxCompressedSize(input.len, level);
        const storage = try gpa.alloc(u8, bound);
        defer gpa.free(storage);

        var fixed = std.Io.Writer.fixed(storage);
        var compressor = try Compressor.init(gpa, .{ .level = level });
        defer compressor.deinit();

        try compressor.write(&fixed, input);
        try compressor.finish(&fixed);
        try testing.expectEqual(fixed.end, fixed.buffered().len);
        try testing.expect(fixed.end > 0);

        const decoder = @import("decompress.zig");
        var source = std.Io.Reader.fixed(storage[0..fixed.end]);
        var sink: std.Io.Writer.Allocating = .init(gpa);
        defer sink.deinit();
        var owned = try decoder.Decoder.init(gpa, .{});
        defer owned.deinit();
        try owned.stream(&source, &sink.writer);
        const restored = try sink.toOwnedSlice();
        defer gpa.free(restored);
        try testing.expectEqualSlices(u8, input, restored);
    }
}

/// Short, prose-like input. Distinct from mixedInput, which embeds binary.
fn shortInput(gpa: Allocator) ![]u8 {
    return gpa.dupe(u8, "bzip2 codes each block on its own, so blocks compress well together.");
}

/// Random bytes, which the run-length stage cannot shrink.
fn incompressibleInput(gpa: Allocator) ![]u8 {
    const out = try gpa.alloc(u8, 120_000);
    testBytes(test_seed + 6, out);
    return out;
}
