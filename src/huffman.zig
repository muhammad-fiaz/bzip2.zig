//! Huffman table construction, canonical code assignment, and decoding.
//!
//! bzip2 codes each block with up to six tables of at most 258 symbols, and
//! transmits the code lengths as a chain of "same / plus one / minus one"
//! deltas so the table description costs a handful of bits per symbol. Code
//! lengths are capped at 17 bits by this encoder, which is what bzip2 has done
//! since 1.0.3; the decoder still accepts the 20 bit lengths that older
//! encoders could emit.

const std = @import("std");
const utils = @import("utils.zig");

/// Cost assigned to a symbol that a candidate table does not cover. Small
/// enough that an uncovered symbol always loses to a covered one.
pub const lesser_icost: u8 = 0;
/// Cost assigned to a symbol that only the tables initially built for their own
/// frequency share cover.
pub const greater_icost: u8 = 15;
/// Longest code length this encoder produces.
pub const encoder_max_len: u8 = 17;

/// Heap entries plus leaves; a bzip2 Huffman tree has 2n - 1 nodes.
const node_cap = 2 * utils.max_alpha_size;

/// Derive canonical Huffman code lengths from symbol frequencies.
///
/// This is the leaf-merge construction bzip2 uses: leaves enter a min-heap
/// weighted by frequency << 8, the two lightest nodes are repeatedly merged,
/// and the depth of each leaf becomes its code length. If any length exceeds
/// max_len the frequencies are halved and the tree is rebuilt, which
/// converges because halving preserves the weight order.
pub fn makeCodeLengths(lengths: []u8, freq: []const u32, max_len: u8) void {
    const alpha_size = lengths.len;
    std.debug.assert(alpha_size >= 2 and alpha_size <= utils.max_alpha_size);

    var weight: [node_cap]u32 = undefined;
    var parent: [node_cap]i32 = undefined;
    var heap: [utils.max_alpha_size + 2]u32 = undefined;

    for (0..alpha_size) |i| {
        const f = freq[i];
        weight[i + 1] = (if (f == 0) 1 else f) << 8;
    }

    // Each iteration halves the frequencies; convergence is quick in practice
    // and the bound makes the loop total.
    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        buildTree(alpha_size, &heap, &weight, &parent);

        var too_long = false;
        for (0..alpha_size) |i| {
            var depth: u8 = 0;
            var node: usize = i + 1;
            while (true) {
                const up = parent[node];
                if (up < 0) break;
                node = @intCast(up);
                depth += 1;
            }
            lengths[i] = depth;
            if (depth > max_len) too_long = true;
        }
        if (!too_long) return;

        for (0..alpha_size) |i| {
            weight[i + 1] = ((weight[i + 1] >> 8) / 2 + 1) << 8;
        }
    }
}

/// Build the Huffman tree over alpha_size leaves.
///
/// weight packs the node weight into the high 24 bits and the node depth into
/// the low 8, so a merge can compute the new depth without a second array. Node
/// id 0 is the heap sentinel; leaves are 1 .. alpha_size.
fn buildTree(
    alpha_size: usize,
    heap: *[utils.max_alpha_size + 2]u32,
    weight: *[node_cap]u32,
    parent: *[node_cap]i32,
) void {
    var n_nodes: usize = alpha_size;

    weight[0] = 0;
    parent[0] = -2;

    var n_heap: usize = 0;
    for (1..alpha_size + 1) |i| {
        parent[i] = -1;
        n_heap += 1;
        heap[n_heap] = @intCast(i);
        siftUp(heap[0..], n_heap, weight);
    }

    while (n_heap > 1) {
        const n1 = heap[1];
        heap[1] = heap[n_heap];
        n_heap -= 1;
        siftDown(heap[0..], n_heap, weight);

        const n2 = heap[1];
        heap[1] = heap[n_heap];
        n_heap -= 1;
        siftDown(heap[0..], n_heap, weight);

        n_nodes += 1;
        parent[n1] = @intCast(n_nodes);
        parent[n2] = @intCast(n_nodes);
        weight[n_nodes] = (weight[n1] & 0xFFFF_FF00) + (weight[n2] & 0xFFFF_FF00) |
            (1 + @max(weight[n1] & 0xFF, weight[n2] & 0xFF));
        parent[n_nodes] = -1;
        n_heap += 1;
        heap[n_heap] = @intCast(n_nodes);
        siftUp(heap[0..], n_heap, weight);
    }
}

fn siftUp(heap: []u32, len: usize, weight: *const [node_cap]u32) void {
    var i = len;
    const item = heap[i];
    while (i > 1 and weight[heap[i >> 1]] > weight[item]) {
        heap[i] = heap[i >> 1];
        i >>= 1;
    }
    heap[i] = item;
}

fn siftDown(heap: []u32, len: usize, weight: *const [node_cap]u32) void {
    if (len == 0) return;
    var i: usize = 1;
    const item = heap[i];
    while (true) {
        var child = i << 1;
        if (child > len) break;
        if (child < len and weight[heap[child + 1]] < weight[heap[child]]) child += 1;
        // Only a strictly lighter parent stops the sift. Equal weights are swapped
        // instead, which keeps the resulting tree shape stable.
        if (weight[item] < weight[heap[child]]) break;
        heap[i] = heap[child];
        i = child;
    }
    heap[i] = item;
}

/// Assign canonical codes to symbols: shortest code first, ties broken by
/// ascending symbol index. The transmitted length table relies on exactly this
/// ordering, so encoder and decoder agree without sending the codes.
pub fn assignCodes(codes: []u32, lengths: []const u8, min_len: u8, max_len: u8) void {
    var vec: u32 = 0;
    var n = min_len;
    while (true) {
        for (lengths, 0..) |len, i| {
            if (len == n) {
                codes[i] = vec;
                vec += 1;
            }
        }
        if (n == max_len) break;
        vec <<= 1;
        n += 1;
    }
}

/// Canonical decoding tables for one Huffman table of a block.
pub const DecodeTable = struct {
    /// Highest code value a symbol of this length can take.
    limit: [utils.max_code_len]i64 = @splat(0),
    /// Code value of the first symbol of this length; index = code - base.
    base: [utils.max_code_len]i64 = @splat(0),
    /// Symbols ordered by (length, symbol index).
    perm: [utils.max_alpha_size]u32 = @splat(0),
    min_len: u8 = 0,
    max_len: u8 = 0,
    alpha_size: usize = 0,

    /// Build the decoding tables for lengths.
    ///
    /// Rejects lengths outside 1..20 and over-subscribed code sets. An
    /// under-subscribed code is tolerated: the bounds check inside
    /// decodeSymbol turns any attempt to reach the missing part of the code
    /// space into an error.
    pub fn init(lengths: []const u8) utils.Error!DecodeTable {
        const alpha_size = lengths.len;
        std.debug.assert(alpha_size >= 2 and alpha_size <= utils.max_alpha_size);

        var self = DecodeTable{ .alpha_size = alpha_size };
        var min_len: u8 = 32;
        var max_len: u8 = 0;
        var kraft: u64 = 0;
        for (lengths) |len| {
            if (len < 1 or len > utils.max_code_len_bits) return error.InvalidHuffmanTable;
            if (len < min_len) min_len = len;
            if (len > max_len) max_len = len;
            kraft += @as(u64, 1) << @intCast(utils.max_code_len_bits - len);
        }
        // A complete code sums to exactly one; more than one is impossible.
        if (kraft > (@as(u64, 1) << utils.max_code_len_bits)) return error.InvalidHuffmanTable;

        self.min_len = min_len;
        self.max_len = max_len;

        var pp: usize = 0;
        var n = min_len;
        while (true) {
            for (lengths, 0..) |len, i| {
                if (len == n) {
                    self.perm[pp] = @intCast(i);
                    pp += 1;
                }
            }
            if (n == max_len) break;
            n += 1;
        }

        for (lengths) |len| self.base[len + 1] += 1;
        for (1..utils.max_code_len) |i| self.base[i] += self.base[i - 1];

        var vec: i64 = 0;
        n = min_len;
        while (true) {
            vec += self.base[n + 1] - self.base[n];
            self.limit[n] = vec - 1;
            vec <<= 1;
            if (n == max_len) break;
            n += 1;
        }
        n = min_len + 1;
        while (n <= max_len) : (n += 1) {
            self.base[n] = ((self.limit[n - 1] + 1) << 1) - self.base[n];
        }

        return self;
    }

    /// Read one code word and return the symbol it encodes.
    pub fn decodeSymbol(self: *const DecodeTable, reader: *utils.BitReader) utils.Error!u32 {
        var zn = self.min_len;
        var zvec: i64 = @intCast(try reader.readBits(@intCast(zn)));
        while (zvec > self.limit[zn]) {
            if (zn >= utils.max_code_len_bits) return error.InvalidHuffmanCode;
            zn += 1;
            zvec = (zvec << 1) | @as(i64, try reader.readBit());
        }
        const index = zvec - self.base[zn];
        if (index < 0 or index >= self.alpha_size) return error.InvalidHuffmanCode;
        return self.perm[@intCast(index)];
    }
};

const testing = std.testing;

test "code lengths form a complete code" {
    const freq = [_]u32{ 5, 10, 20, 40, 80, 160 };
    var lengths: [6]u8 = undefined;
    makeCodeLengths(&lengths, &freq, encoder_max_len);

    var kraft: u32 = 0;
    for (lengths) |len| kraft += @as(u32, 1) << @intCast(17 - len);
    try testing.expectEqual(@as(u32, 1 << 17), kraft);

    // More frequent symbols get shorter codes.
    try testing.expect(lengths[5] < lengths[4]);
    try testing.expect(lengths[4] < lengths[0]);
}

test "code lengths are capped" {
    // A near-degenerate distribution over a full block's worth of symbols
    // forces the halving loop to run. The total stays at a realistic block
    // size because the packed node weight is 24 bits wide.
    var freq: [258]u32 = @splat(0);
    var i: usize = 0;
    while (i < 258) : (i += 1) freq[i] = @as(u32, 1) << @intCast(i % 20);
    const total: u32 = blk: {
        var sum: u32 = 0;
        for (freq) |f| sum += f;
        break :blk sum;
    };
    try testing.expect(total < (1 << 24));

    var lengths: [258]u8 = undefined;
    makeCodeLengths(&lengths, &freq, encoder_max_len);
    for (lengths) |len| try testing.expect(len >= 1 and len <= encoder_max_len);

    var kraft: u64 = 0;
    for (lengths) |len| kraft += @as(u64, 1) << @intCast(utils.max_code_len_bits - len);
    try testing.expect(kraft <= (@as(u64, 1) << utils.max_code_len_bits));
}

test "assigned codes are prefix free and decode back to their symbols" {
    const freq = [_]u32{ 3, 1, 4, 1, 5, 9, 2, 6 };
    var lengths: [8]u8 = undefined;
    makeCodeLengths(&lengths, &freq, encoder_max_len);

    var codes: [8]u32 = undefined;
    var min_len: u8 = 32;
    var max_len: u8 = 0;
    for (lengths) |len| {
        min_len = @min(min_len, len);
        max_len = @max(max_len, len);
    }
    assignCodes(&codes, &lengths, min_len, max_len);

    for (lengths, 0..) |len, i| {
        for (lengths, 0..) |other_len, j| {
            if (i == j or other_len <= len) continue;
            const prefix = codes[i] >> @intCast(other_len - len);
            try testing.expect(prefix != codes[j]);
        }
    }

    var storage: [64]u8 = undefined;
    var sink = std.Io.Writer.fixed(&storage);
    var bw = utils.BitWriter.init(&sink);
    const order = [_]usize{ 5, 6, 3, 4, 0, 1, 2, 7 };
    for (order) |i| try bw.putBits(codes[i], @intCast(lengths[i]));
    try bw.finish();
    try sink.flush();

    var source = std.Io.Reader.fixed(sink.buffered());
    var br = utils.BitReader.init(&source);
    const table = try DecodeTable.init(&lengths);
    for (order) |expected| {
        try testing.expectEqual(@as(u32, @intCast(expected)), try table.decodeSymbol(&br));
    }
}

test "decode table rejects impossible lengths" {
    const ones: [4]u8 = @splat(1);
    const zero_length = [_]u8{0} ++ ones;
    try testing.expectError(error.InvalidHuffmanTable, DecodeTable.init(&zero_length));

    const too_long = [_]u8{21} ++ ones;
    try testing.expectError(error.InvalidHuffmanTable, DecodeTable.init(&too_long));

    const over: [6]u8 = @splat(1);
    try testing.expectError(error.InvalidHuffmanTable, DecodeTable.init(&over));
}

test "decode table handles the maximum alphabet" {
    // 254 symbols of length 8 and 4 of length 9 form a complete code: the
    // Kraft sum is exactly one, at the largest alphabet the format allows.
    var lengths: [258]u8 = @splat(8);
    for (lengths[254..]) |*l| l.* = 9;
    const table = try DecodeTable.init(&lengths);
    try testing.expectEqual(@as(usize, 258), table.alpha_size);
    try testing.expectEqual(@as(u8, 8), table.min_len);
    try testing.expectEqual(@as(u8, 9), table.max_len);
}

test "decode table rejects an over-subscribed 258 symbol code" {
    var lengths: [258]u8 = @splat(1);
    try testing.expectError(error.InvalidHuffmanTable, DecodeTable.init(&lengths));
}
