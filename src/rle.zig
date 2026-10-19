//! Initial run-length coding, the pre-pass that every bzip2 block goes through
//! before and after the block-sorting pipeline.
//!
//! A run of five or more identical bytes is stored as four bytes followed by a
//! single count byte holding run_length - 4, so the transform never grows a
//! block by more than a factor of five and, more importantly, never grows it
//! by more than four bytes per input byte. Runs of four or fewer are stored
//! literally. This keeps long runs of one byte from drowning the
//! Burrows-Wheeler stage in redundant comparisons.
//!
//! The two directions are deliberately not mirror images. The encoder has to
//! stay resumable across block boundaries, because a run may straddle two
//! blocks, so it keeps the pending run in its own state. The decoder only ever
//! expands bytes it is already holding.

const std = @import("std");

/// What a push or flush appended to the block, expressed in terms of the
/// original input bytes it stands for.
///
/// A run is committed to the block as a unit, so this is how the caller keeps a
/// checksum over the untransformed data even though the block holds the coded
/// form. bzip2's block CRC is exactly such a checksum.
pub const Committed = struct {
    byte: u8 = 0,
    count: u32 = 0,

    pub fn none() Committed {
        return .{};
    }

    pub fn isAny(self: Committed) bool {
        return self.count != 0;
    }
};

/// Streaming RLE1 encoder.
///
/// Feed bytes with push and close the stream with flush. Both append to a
/// caller owned block buffer and advance out_len. A single input byte can
/// produce at most five output bytes, so a block buffer with five bytes of
/// headroom over the block limit is always large enough.
pub const Encoder = struct {
    /// Byte value of the pending run, or no_run when nothing is pending.
    /// no_run sits outside the byte range on purpose: it is a sentinel, and
    /// keeping it out of range makes every u8 comparison safe to use as a
    /// "is a run pending" test.
    ch: u16 = no_run,
    /// Length of the pending run. Always zero while ch == no_run.
    len: u32 = 0,

    const no_run: u16 = 256;

    /// Largest number of bytes push and flush can append in one call.
    pub const max_written_per_call: usize = 5;

    /// Forget any pending run without emitting it.
    pub fn reset(self: *Encoder) void {
        self.ch = no_run;
        self.len = 0;
    }

    /// True while a run is buffered and not yet part of the block.
    pub fn hasPending(self: *const Encoder) bool {
        return self.ch != no_run;
    }

    /// Append one input byte to the block under construction, reporting the
    /// original bytes that became part of the block as a result.
    pub fn push(self: *Encoder, byte: u8, out: []u8, out_len: *usize) Committed {
        if (byte != self.ch and self.len == 1) {
            // Fast path: the pending run is a single byte, emit it as-is.
            out[out_len.*] = @truncate(self.ch);
            out_len.* += 1;
            const committed = Committed{ .byte = @truncate(self.ch), .count = 1 };
            self.ch = byte;
            return committed;
        }
        if (byte != self.ch or self.len == 255) {
            const committed = self.emitPending(out, out_len);
            self.ch = byte;
            self.len = 1;
            return committed;
        }
        self.len += 1;
        return Committed.none();
    }

    /// Emit the pending run, if any. Call once at the end of the stream so a
    /// run that ends there is not lost.
    pub fn flush(self: *Encoder, out: []u8, out_len: *usize) Committed {
        const committed = self.emitPending(out, out_len);
        self.reset();
        return committed;
    }

    fn emitPending(self: *Encoder, out: []u8, out_len: *usize) Committed {
        if (self.ch == no_run or self.len == 0) return Committed.none();
        const ch: u8 = @truncate(self.ch);
        switch (self.len) {
            1 => {
                out[out_len.*] = ch;
                out_len.* += 1;
            },
            2 => {
                out[out_len.*] = ch;
                out[out_len.* + 1] = ch;
                out_len.* += 2;
            },
            3 => {
                out[out_len.*] = ch;
                out[out_len.* + 1] = ch;
                out[out_len.* + 2] = ch;
                out_len.* += 3;
            },
            else => {
                out[out_len.*] = ch;
                out[out_len.* + 1] = ch;
                out[out_len.* + 2] = ch;
                out[out_len.* + 3] = ch;
                out[out_len.* + 4] = @truncate(self.len - 4);
                out_len.* += 5;
            },
        }
        return .{ .byte = ch, .count = self.len };
    }
};

/// Streaming RLE1 decoder.
///
/// push expands one coded byte. A single coded byte can expand to 255 bytes
/// (count == 255 after four literals), so callers must leave at least
/// max_written_per_call bytes of free space in out before each call.
pub const Decoder = struct {
    /// Byte of the run currently being assembled.
    ch: u8 = 0,
    /// Consecutive occurrences of ch seen so far. 4 means "the next coded
    /// byte is a count, not a literal".
    seen: u8 = 0,

    /// Largest number of bytes one push can append.
    pub const max_written_per_call: usize = 255;

    pub fn reset(self: *Decoder) void {
        self.ch = 0;
        self.seen = 0;
    }

    /// True when the coded block ended in the middle of a run, meaning the
    /// count byte was never supplied. The four literals already produced stand
    /// on their own, and the missing count is never requested, because no
    /// further push arrives.
    pub fn isArmed(self: *const Decoder) bool {
        return self.seen == 4;
    }

    /// Expand one coded byte into out, advancing out_len.
    pub fn push(self: *Decoder, byte: u8, out: []u8, out_len: *usize) void {
        if (self.seen == 4) {
            const count: u32 = byte;
            @memset(out[out_len.*..][0..count], self.ch);
            out_len.* += count;
            self.seen = 0;
            return;
        }
        if (byte == self.ch) {
            self.seen += 1;
        } else {
            self.ch = byte;
            self.seen = 1;
        }
        out[out_len.*] = byte;
        out_len.* += 1;
    }
};

/// Exact number of bytes coded decodes to, or error.RunLengthOverflow.
///
/// The decoder computes this before allocating so that the output buffer is
/// sized from the data instead of grown by trial and error.
pub fn decodedLen(coded: []const u8) error{RunLengthOverflow}!usize {
    var total: usize = 0;
    var seen: u8 = 0;
    var ch: u8 = 0;
    for (coded) |byte| {
        if (seen == 4) {
            total = std.math.add(usize, total, byte) catch return error.RunLengthOverflow;
            seen = 0;
            continue;
        }
        if (byte == ch) {
            seen += 1;
        } else {
            ch = byte;
            seen = 1;
        }
        total = std.math.add(usize, total, 1) catch return error.RunLengthOverflow;
    }
    return total;
}

const testing = std.testing;

test "encoder expands runs of four or fewer literally" {
    var out: [32]u8 = undefined;
    var n: usize = 0;
    var enc = Encoder{};
    for ("aaab") |b| _ = enc.push(b, &out, &n);
    _ = enc.flush(&out, &n);
    try testing.expectEqualSlices(u8, "aaab", out[0..n]);
}

test "encoder expands a run of five into four literals plus a count" {
    var out: [32]u8 = undefined;
    var n: usize = 0;
    var enc = Encoder{};
    for (0..5) |_| _ = enc.push('a', &out, &n);
    _ = enc.flush(&out, &n);
    try testing.expectEqualSlices(u8, "aaaa\x01", out[0..n]);
}

test "encoder splits a run of 255 and starts a new one" {
    var out: [512]u8 = undefined;
    var n: usize = 0;
    var enc = Encoder{};
    // The 255th byte is still held back; the next one forces the split, and the
    // byte that forced it starts the new run.
    for (0..255) |_| _ = enc.push('z', &out, &n);
    try testing.expectEqual(@as(usize, 0), n);

    _ = enc.push('z', &out, &n);
    try testing.expectEqualSlices(u8, "zzzz\xfb", out[0..n]);

    _ = enc.flush(&out, &n);
    try testing.expectEqualSlices(u8, "zzzz\xfbz", out[0..n]);
}

test "encoder keeps a pending run across flush boundaries" {
    var out: [32]u8 = undefined;
    var n: usize = 0;
    var enc = Encoder{};
    // "aab" then, as if the block boundary fell here, nothing is emitted yet.
    _ = enc.push('a', &out, &n);
    _ = enc.push('a', &out, &n);
    try testing.expectEqual(@as(usize, 0), n);
    _ = enc.flush(&out, &n);
    try testing.expectEqualSlices(u8, "aa", out[0..n]);
}

test "decoder expands what the encoder produced" {
    const zeroes: [300]u8 = @splat(0);
    const inputs = [_][]const u8{
        "",
        "a",
        "aa",
        "aaaa",
        "aaaaa",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "hello world, hello world, hello world",
        &zeroes,
    };
    for (inputs) |input| {
        var coded: [1024]u8 = undefined;
        var coded_len: usize = 0;
        var enc = Encoder{};
        for (input) |b| _ = enc.push(b, &coded, &coded_len);
        _ = enc.flush(&coded, &coded_len);

        var plain: [4096]u8 = undefined;
        var plain_len: usize = 0;
        var dec = Decoder{};
        for (coded[0..coded_len]) |b| dec.push(b, &plain, &plain_len);

        try testing.expectEqualStrings(input, plain[0..plain_len]);
        try testing.expectEqual(plain_len, try decodedLen(coded[0..coded_len]));
    }
}

test "decoder emits four literals when a count byte is missing" {
    var out: [16]u8 = undefined;
    var n: usize = 0;
    var dec = Decoder{};
    for ("aaaa") |b| dec.push(b, &out, &n);
    try testing.expect(dec.isArmed());
    try testing.expectEqualSlices(u8, "aaaa", out[0..n]);
}

test "decodedLen matches a worst case expansion" {
    // "aaaa" + 0xFF expands a four byte group into 259 bytes.
    const coded = "aaaa\xff";
    try testing.expectEqual(@as(usize, 259), try decodedLen(coded));
}
