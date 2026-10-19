//! Shared primitives for the bzip2 codec.
//!
//! This module holds everything that both the encoder and the decoder need:
//! the on-the-wire constants of the format, the canonical error set, the CRC
//! convention, and MSB-first bit level I/O layered on Zig 0.17's
//! std.Io.Reader / std.Io.Writer.
//!
//! None of it is specific to compression or to decompression.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Every failure that the bzip2 codec can report.
///
/// OutOfMemory is the only error that does not describe the input. The
/// remaining members are all produced while parsing untrusted data and are
/// deliberately distinguishable so callers can report why a stream was
/// rejected instead of merely that it was rejected.
pub const Error = error{
    /// A compression level outside 1..9 was requested.
    InvalidCompressionLevel,
    /// The four byte stream header (BZh<level>) is not well formed.
    InvalidStreamHeader,
    /// A 48 bit block marker was expected but not found.
    InvalidBlockMarker,
    /// The end-of-stream marker was expected but not found.
    InvalidEndOfStreamMarker,
    /// nSelectors was zero or the selector MTF values were out of range.
    InvalidSelectors,
    /// A Huffman code length was outside 1..20 or the code was over-subscribed.
    InvalidHuffmanTable,
    /// A Huffman code word could not be resolved against the current table.
    InvalidHuffmanCode,
    /// The symbol map (16 + up to 256 bits) was empty or inconsistent.
    InvalidSymbolMap,
    /// A block decoded to a symbol stream the format cannot represent.
    InvalidSequence,
    /// origPtr does not address a row of the reconstructed block.
    InvalidOrigPtr,
    /// A RUNA/RUNB run exceeded the largest block the format can express.
    RunLengthOverflow,
    /// The stream ended in the middle of a structural element.
    UnexpectedEndOfStream,
    /// The CRC stored with a block does not match the decoded bytes.
    BlockCrcMismatch,
    /// The CRC stored in the stream trailer does not match the stream.
    StreamCrcMismatch,
    /// The caller supplied max_output_size and the stream exceeded it.
    OutputTooLarge,
    /// The trailing bytes after the end-of-stream marker were rejected.
    TrailingData,
    OutOfMemory,
};

/// Errors raised while talking to a std.Io.Reader or std.Io.Writer.
pub const IoError = std.Io.Writer.Error || std.Io.Reader.Error;

/// The union of the codec error set and the I/O error sets, used by the
/// streaming entry points that move bytes between the codec and a sink.
pub const StreamError = Error || IoError;

/// Errors the whole-file entry points can raise. Opening a file can fail
/// independently of anything the codec does, so this sits alongside
/// StreamError rather than being folded into it. File.close returns no
/// error, and flush errors are already std.Io.Writer.Error.
pub const FileError = std.Io.File.OpenError || std.Io.Dir.RenameError || error{
    /// A whole-file call was asked to read and write the same path, which would
    /// destroy the input. Refused before anything is opened.
    SamePathAsSourceAndDestination,
};

/// Return type of compressFile and decompressFile.
pub const FileStreamError = StreamError || FileError;

/// One bzip2 block holds at most 900 kB; larger inputs become multi-block
/// streams. This is a hard limit of the format, not of this implementation.
pub const max_block_size: usize = 900_000;

/// bzip2 blocks are sized in units of 100 kB. Levels 1..9 select 1..9 units,
/// so the level stored in the stream header is the block size divided by this.
pub const block_unit: usize = 100_000;
pub const min_level: usize = 1;
pub const max_level: usize = 9;

/// 'B', 'Z', 'h' and the base-48 digit of the block size.
pub const magic_b: u8 = 0x42;
pub const magic_z: u8 = 0x5A;
pub const magic_h: u8 = 0x68;
pub const magic_0: u8 = 0x30;

/// Start of a compressed block: 0x314159265359.
pub const block_magic = [6]u8{ 0x31, 0x41, 0x59, 0x26, 0x53, 0x59 };
/// End of stream: 0x177245385090.
pub const end_magic = [6]u8{ 0x17, 0x72, 0x45, 0x38, 0x50, 0x90 };

/// MTF alphabet symbols. Symbols 2..alpha_size-1 are MTF distances and the
/// final symbol is end-of-block.
pub const run_a: u16 = 0;
pub const run_b: u16 = 1;
/// nInUse + 2 never exceeds 256 + 2.
pub const max_alpha_size: usize = 258;
/// The decoder's lookup tables are indexed by code length, which the format
/// permits up to 20 bits even though encoders today stop at 17.
pub const max_code_len: usize = 23;
pub const max_code_len_bits: u6 = 20;
/// Number of Huffman tables a block may switch between.
pub const num_groups: usize = 6;
/// MTF symbols per selector.
pub const group_size: usize = 50;
/// Refinement passes used when fitting the Huffman tables to the data.
pub const num_iters: usize = 4;
/// 2 + max_block_size / group_size, the largest legal selector count.
pub const max_selectors: usize = 2 + (max_block_size / group_size);
/// The largest RLE-expansion of a single input byte run, used to size the
/// decoder's output window.
pub const max_run_expansion: usize = 255;

/// The CRC-32 variant bzip2 uses.
///
/// bzip2 pre-dates most modern CRC conventions and is not compatible with
/// the CRC-32 used by gzip, PNG, Ethernet or std.hash.Crc32:
/// polynomial 0x04C11DB7 processed most significant bit first, initial value
/// 0xFFFFFFFF, no input reflection, and the final value XORed with 0xFFFFFFFF.
/// std.hash.crc.@"CRC-32/BZIP2" is registered with exactly those parameters,
/// so the Zig implementation is reused instead of duplicating a table. The
/// known-answer vectors in the tests of this module pin the polynomial, the
/// initial value, the bit order and the finalisation together.
pub const Crc = std.hash.crc.@"CRC-32/BZIP2";

/// CRC of bytes using the bzip2 convention.
pub fn crc(bytes: []const u8) u32 {
    return Crc.hash(bytes);
}

/// Largest run a single call to crcRepeat can fold in, matching the format's
/// maximum run length.
const max_run: usize = 255;

/// Fold count copies of byte into a running bzip2 CRC.
///
/// bzip2 checksums the data before the run-length stage, so a caller that only
/// ever sees the coded block cannot reproduce it. Runs are at most 255 bytes,
/// which keeps this allocation free.
pub fn crcRepeat(state: *Crc, byte: u8, count: u32) void {
    if (count == 0) return;
    if (count == 1) {
        const single = [_]u8{byte};
        state.update(&single);
        return;
    }
    var repeated: [max_run]u8 = undefined;
    const n: usize = @intCast(count);
    @memset(repeated[0..n], byte);
    state.update(repeated[0..n]);
}

/// Combine a finished block CRC into the running stream CRC.
///
/// The accumulator is rotated left by one bit and the block CRC is XORed in.
/// That single-bit rotation is what makes the combined CRC order-dependent,
/// so the blocks have to be folded in the order they appear.
pub fn combineCrc(combined: u32, block: u32) u32 {
    return std.math.rotl(u32, combined, 1) ^ block;
}

/// Mask of the low n bits, for 0 <= n < 32.
inline fn lowMask(n: u8) u32 {
    return if (n == 0) 0 else (@as(u32, 1) << @as(u5, @intCast(n))) - 1;
}

/// MSB-first bit sink.
///
/// bzip2 is a bit-packed format: every field starts at the current bit
/// position and is filled from the most significant bit down. Bytes leave this
/// writer in the same order they enter the stream.
pub const BitWriter = struct {
    sink: *std.Io.Writer,
    /// Staging buffer; std.Io.Writer is only touched once it fills up.
    buf: [4096]u8 = undefined,
    len: usize = 0,
    /// Pending bits, right aligned in acc and always fewer than 8.
    live: u6 = 0,
    acc: u32 = 0,

    /// The bits still pending after flush.
    ///
    /// bzip2 blocks do not end on a byte boundary, so a writer that finishes a
    /// block and is then thrown away has to hand its partial byte to the next
    /// writer. Capturing this state and passing it to initState does that.
    pub const State = struct {
        live: u6 = 0,
        acc: u32 = 0,
    };

    pub fn init(sink: *std.Io.Writer) BitWriter {
        return .{ .sink = sink };
    }

    pub fn initState(sink: *std.Io.Writer, state: State) BitWriter {
        return .{ .sink = sink, .live = state.live, .acc = state.acc };
    }

    /// The pending bits, for initState.
    pub fn captureState(self: *const BitWriter) State {
        return .{ .live = self.live, .acc = self.acc };
    }

    /// Append the low n bits of value, most significant first.
    ///
    /// n may not exceed 24, which is the widest field bzip2 writes
    /// (origPtr). Together with the < 8 pending bits this guarantees the
    /// accumulator never needs more than 31 bits.
    pub fn putBits(self: *BitWriter, value: u32, n: u6) IoError!void {
        std.debug.assert(n <= 24);
        std.debug.assert(self.live < 8);
        self.acc = (self.acc << @as(u5, @intCast(n))) | (value & lowMask(n));
        self.live += n;
        while (self.live >= 8) {
            self.live -= 8;
            try self.pushByte(@truncate(self.acc >> @as(u5, @intCast(self.live))));
        }
    }

    pub fn putBit(self: *BitWriter, bit: u1) IoError!void {
        try self.putBits(bit, 1);
    }

    pub fn putByte(self: *BitWriter, byte: u8) IoError!void {
        try self.putBits(byte, 8);
    }

    /// Write a 32 bit value big-endian, one byte at a time, so the bit order
    /// matches the byte order used elsewhere in the format.
    pub fn putU32(self: *BitWriter, value: u32) IoError!void {
        try self.putBits(value >> 24, 8);
        try self.putBits(value >> 16, 8);
        try self.putBits(value >> 8, 8);
        try self.putBits(value, 8);
    }

    /// Push every whole buffered byte. Only valid at a byte boundary, which
    /// bzip2 reaches after the header, a block CRC and the end-of-stream CRC.
    pub fn flush(self: *BitWriter) IoError!void {
        if (self.len != 0) {
            try self.sink.writeAll(self.buf[0..self.len]);
            self.len = 0;
        }
    }

    /// Zero-pad to the next byte boundary and push everything. bzip2 pads its
    /// final partial byte with zeroes, exactly like bsFinishWrite.
    pub fn finish(self: *BitWriter) IoError!void {
        if (self.live > 0) {
            try self.putBits(0, @intCast(8 - self.live));
        }
        try self.flush();
    }

    fn pushByte(self: *BitWriter, byte: u8) IoError!void {
        if (self.len == self.buf.len) {
            try self.flush();
        }
        self.buf[self.len] = byte;
        self.len += 1;
    }
};

/// MSB-first bit source over a std.Io.Reader.
///
/// Bytes are pulled in through a staging buffer so that single-bit reads do
/// not turn into one reader call per bit. Running out of bytes is reported as
/// error.UnexpectedEndOfStream rather than being silently zero-filled,
/// which is what keeps truncated streams detectable.
pub const BitReader = struct {
    source: *std.Io.Reader,
    buf: [4096]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,
    live: u6 = 0,
    acc: u32 = 0,

    pub fn init(source: *std.Io.Reader) BitReader {
        return .{ .source = source };
    }

    /// Read n bits, most significant first. n may not exceed 24.
    pub fn readBits(self: *BitReader, n: u6) Error!u32 {
        std.debug.assert(n <= 24);
        if (n == 0) return 0;
        while (self.live < n) {
            if (self.pos == self.end) self.refill() catch |err| switch (err) {
                error.EndOfStream => return error.UnexpectedEndOfStream,
                error.ReadFailed => return error.UnexpectedEndOfStream,
                error.WriteFailed => return error.UnexpectedEndOfStream,
            };
            if (self.pos == self.end) return error.UnexpectedEndOfStream;
            self.acc = (self.acc << 8) | self.buf[self.pos];
            self.pos += 1;
            self.live += 8;
        }
        self.live -= n;
        const value: u32 = @truncate(self.acc >> @as(u5, @intCast(self.live)));
        self.acc &= lowMask(self.live);

        return value;
    }

    pub fn readBit(self: *BitReader) Error!u1 {
        return @truncate(try self.readBits(1));
    }

    pub fn readByte(self: *BitReader) Error!u8 {
        return @truncate(try self.readBits(8));
    }

    /// Discard any bits still held in the accumulator. Used when the stream
    /// moves from one structural element to the next at a known bit offset.
    pub fn alignToByte(self: *BitReader) void {
        self.live = 0;
        self.acc = 0;
    }

    /// Bytes that have been read into the staging buffer but not consumed.
    /// Only useful for tests and for reporting the exact stream position.
    pub fn buffered(self: *const BitReader) usize {
        return self.end - self.pos;
    }

    fn refill(self: *BitReader) IoError!void {
        if (self.pos == self.end) {
            self.pos = 0;
            self.end = 0;
        } else if (self.pos > 0) {
            std.mem.copyForwards(u8, self.buf[0 .. self.end - self.pos], self.buf[self.pos..self.end]);
            self.end -= self.pos;
            self.pos = 0;
        }
        // A short read means the underlying stream ended; the next
        // refill returns 0 and the caller turns that into
        // error.UnexpectedEndOfStream.
        self.end += try self.source.readSliceShort(self.buf[self.end..]);
    }
};

test "crc matches the bzip2 convention" {
    // Known-answer vectors. These pin the polynomial, the initial value, the
    // bit order and the finalisation together, which a round trip through this
    // function alone would not prove.
    try std.testing.expectEqual(@as(u32, 0x0000_0000), crc(""));
    try std.testing.expectEqual(@as(u32, 0x1993_9B6B), crc("a"));
    try std.testing.expectEqual(@as(u32, 0x9E62_5BFE), crc("hello hello hello"));
    const two_ff: [2]u8 = @splat(0xFF);
    try std.testing.expectEqual(@as(u32, 0x0000_FFFF), crc(&two_ff));
    try std.testing.expectEqual(crc("bzip2"), Crc.hash("bzip2"));
}

test "crc is not the reflected crc-32 used by other formats" {
    const bytes = [_]u8{ 0x31, 0x41, 0x59, 0x26 };
    try std.testing.expect(crc(&bytes) != std.hash.Crc32.hash(&bytes));
}

test "bit writer and reader round trip every field width" {
    const values = [_]u32{ 0, 1, 0x5555_5555, 0xABCD, 0x00FF_00FF, 0x7FFF_FFFF };
    const widths = [_]u6{ 0, 1, 3, 8, 15, 24 };

    var storage: [128]u8 = undefined;
    var sink = std.Io.Writer.fixed(&storage);
    var bw = BitWriter.init(&sink);
    for (values, widths) |value, width| try bw.putBits(value, width);
    try bw.finish();
    try sink.flush();

    var source = std.Io.Reader.fixed(sink.buffered());
    var br = BitReader.init(&source);
    for (values, widths) |value, width| {
        const mask: u32 = if (width == 0) 0 else (@as(u32, 1) << @as(u5, @intCast(width))) - 1;
        try std.testing.expectEqual(value & mask, try br.readBits(width));
    }
}

test "bit writer emits most significant bit first" {
    var storage: [2]u8 = undefined;
    var sink = std.Io.Writer.fixed(&storage);
    var bw = BitWriter.init(&sink);
    try bw.putBits(1, 1);
    try bw.putBits(0, 1);
    try bw.putBits(1, 1);
    try bw.putBits(0xFF, 8);
    try bw.finish();
    try sink.flush();

    // 101 then eight ones, then zero padding to the byte boundary.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0b1011_1111, 0b1110_0000 }, sink.buffered());
}

test "bit reader reports truncated streams" {
    var storage: [2]u8 = undefined;
    var sink = std.Io.Writer.fixed(&storage);
    var bw = BitWriter.init(&sink);
    try bw.putBits(0xFFFF, 16);
    try bw.finish();
    try sink.flush();

    var source = std.Io.Reader.fixed(sink.buffered()[0..1]);
    var br = BitReader.init(&source);
    try std.testing.expectError(error.UnexpectedEndOfStream, br.readBits(16));
}

test "combineCrc rotates the accumulator" {
    // The accumulator is rotated left by one before the block CRC is folded in,
    // which is what makes the stream CRC order dependent.
    try std.testing.expectEqual(@as(u32, 0x8000_0000), combineCrc(0, 0x8000_0000));
    try std.testing.expectEqual(@as(u32, 0x0000_0002), combineCrc(1, 0));
    try std.testing.expectEqual(@as(u32, 0x0000_0005), combineCrc(2, 1));
}
