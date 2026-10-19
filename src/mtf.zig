//! Move-to-front coding and the MTF run-length symbols.
//!
//! bzip2 numbers the distinct bytes of a block 0 .. nInUse-1 in ascending
//! byte order and then encodes each occurrence by how far it has to move
//! towards the front of that list. Small distances are cheap, and because the
//! Burrows-Wheeler transform clusters equal bytes, most symbols come out as
//! distance zero, which the encoder folds into runs (see encodeRunLength).

const std = @import("std");
const utils = @import("utils.zig");

/// The move-to-front list over the in-use alphabet of one block.
///
/// The same table serves both directions: encode walks the list towards the
/// front, decode walks it back out. alphabet lists the in-use byte values
/// in ascending order, exactly as the symbol map in the stream defines them.
pub const Table = struct {
    list: [256]u8 = undefined,
    len: usize = 0,

    /// Build the initial identity list for alphabet, whose length is
    /// nInUse and which never exceeds 256.
    pub fn init(alphabet: []const u8) Table {
        std.debug.assert(alphabet.len >= 1 and alphabet.len <= 256);
        var self = Table{ .len = alphabet.len };
        @memcpy(self.list[0..alphabet.len], alphabet);
        return self;
    }

    /// Move symbol to the front and return how many places it moved. The
    /// result is the MTF distance minus one, i.e. the raw 1..nInUse value
    /// the stream stores.
    ///
    /// Returns error.InvalidSequence for a symbol that is not in the
    /// alphabet. The caller derives the alphabet from the block, so this
    /// cannot happen for data this encoder produced, and the bound keeps a
    /// mismatch from scanning past the end of the list.
    pub fn encode(self: *Table, symbol: u8) utils.Error!u8 {
        var i: usize = 0;
        while (i < self.len and self.list[i] != symbol) i += 1;
        if (i == self.len) return error.InvalidSequence;
        std.mem.copyBackwards(u8, self.list[1 .. i + 1], self.list[0..i]);
        self.list[0] = symbol;
        return @intCast(i);
    }

    /// Inverse of encode: move the front of the list back out to distance.
    ///
    /// Returns error.InvalidSequence for a distance beyond the alphabet,
    /// which is what a malformed symbol stream produces.
    pub fn decode(self: *Table, distance: u8) utils.Error!u8 {
        const i: usize = distance;
        if (i >= self.len) return error.InvalidSequence;
        const symbol = self.list[i];
        std.mem.copyBackwards(u8, self.list[1 .. i + 1], self.list[0..i]);
        self.list[0] = symbol;
        return symbol;
    }

    /// The symbol currently at the front of the list, i.e. the one that
    /// consecutive distance-zero symbols repeat.
    pub fn front(self: *const Table) u8 {
        return self.list[0];
    }
};

/// Encode a run of run_length zero-MTF symbols as RUNA/RUNB values.
///
/// A run of n equal bytes becomes the bijective base-2 digits of n - 1,
/// least significant digit first: RUNA contributes N and RUNB contributes
/// 2N for the current power of two. At most log2(n) + 1 symbols are
/// produced, which never exceeds run_length; returns how many were written.
pub fn encodeRunLength(out: []u16, run_length: usize) usize {
    std.debug.assert(run_length >= 1);
    var pending = run_length - 1;
    var count: usize = 0;
    while (true) {
        out[count] = if (pending & 1 == 1) utils.run_b else utils.run_a;
        count += 1;
        if (pending < 2) break;
        pending = (pending - 2) / 2;
    }
    return count;
}

/// Largest run length encodeRunLength can express with two 21 bit symbols,
/// which is also the bound the decoder enforces to stop a hostile stream from
/// asking for an unbounded allocation.
pub const max_run_length: usize = 2 * 1024 * 1024;

const testing = std.testing;

test "table starts as the identity list" {
    var table = Table.init("ace");
    try testing.expectEqual(@as(u8, 'a'), table.front());
    // 'e' sits at the back, so encoding it costs the maximum distance and moves
    // it to the front.
    try testing.expectEqual(@as(u8, 2), try table.encode('e'));
    try testing.expectEqual(@as(u8, 'e'), table.front());
    // The list is now eac, so 'a' is one step behind the front.
    try testing.expectEqual(@as(u8, 1), try table.encode('a'));
    try testing.expectEqual(@as(u8, 'a'), table.front());
    // The list is aec; 'c' is now the furthest away.
    try testing.expectEqual(@as(u8, 2), try table.encode('c'));
    try testing.expectEqual(@as(u8, 'c'), table.front());
}

test "encode and decode are inverses" {
    const alphabet = [_]u8{ 1, 4, 9, 16, 25, 36 };
    const sequence = [_]u8{ 1, 4, 9, 16, 25, 36, 4, 4, 9, 1, 25, 36, 16, 9, 4, 1 };
    var table = Table.init(&alphabet);
    var encoded: [sequence.len]u8 = undefined;
    for (sequence, 0..) |sym, i| encoded[i] = try table.encode(sym);

    var restored = Table.init(&alphabet);
    for (encoded, sequence) |distance, expected| {
        try testing.expectEqual(expected, try restored.decode(distance));
    }
}

test "a full 256 symbol alphabet works" {
    var alphabet: [256]u8 = undefined;
    for (&alphabet, 0..) |*b, i| b.* = @intCast(i);
    var table = Table.init(&alphabet);
    try testing.expectEqual(@as(u8, 255), try table.encode(255));
    try testing.expectEqual(@as(u8, 255), table.front());
    try testing.expectEqual(@as(u8, 255), try table.encode(254));
}

test "run length encoding matches the reference bijective base two" {
    var out: [8]u16 = undefined;
    // A run of n becomes the bijective base-2 digits of n-1, least significant
    // first: RUNA contributes the current power of two, RUNB twice that.
    try testing.expectEqual(@as(usize, 1), encodeRunLength(&out, 1));
    try testing.expectEqualSlices(u16, &[_]u16{utils.run_a}, out[0..1]);

    try testing.expectEqual(@as(usize, 1), encodeRunLength(&out, 2));
    try testing.expectEqualSlices(u16, &[_]u16{utils.run_b}, out[0..1]);

    try testing.expectEqual(@as(usize, 2), encodeRunLength(&out, 3));
    try testing.expectEqualSlices(u16, &[_]u16{ utils.run_a, utils.run_a }, out[0..2]);

    try testing.expectEqual(@as(usize, 2), encodeRunLength(&out, 4));
    try testing.expectEqualSlices(u16, &[_]u16{ utils.run_b, utils.run_a }, out[0..2]);

    try testing.expectEqual(@as(usize, 2), encodeRunLength(&out, 5));
    try testing.expectEqualSlices(u16, &[_]u16{ utils.run_a, utils.run_b }, out[0..2]);

    try testing.expectEqual(@as(usize, 2), encodeRunLength(&out, 6));
    try testing.expectEqualSlices(u16, &[_]u16{ utils.run_b, utils.run_b }, out[0..2]);

    try testing.expectEqual(@as(usize, 3), encodeRunLength(&out, 7));
    try testing.expectEqualSlices(u16, &[_]u16{ utils.run_a, utils.run_a, utils.run_a }, out[0..3]);
}

test "run length encoding round trips through the decoder formula" {
    for (1..600) |run| {
        var symbols: [12]u16 = undefined;
        const n = encodeRunLength(&symbols, run);
        var es: usize = 0;
        var weight: usize = 1;
        for (symbols[0..n]) |symbol| {
            const digit: usize = if (symbol == utils.run_a) 1 else 2;
            es = std.math.add(usize, es, weight * digit) catch unreachable;
            weight *= 2;
        }
        try testing.expectEqual(run, es);
    }
}
