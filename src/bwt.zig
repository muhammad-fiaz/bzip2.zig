//! Burrows-Wheeler transform, forward and inverse.
//!
//! bzip2 block sorting sorts every cyclic rotation of the block and keeps the
//! last column. Because the matrix is cyclic, the sorted rotations of block
//! are the sorted rotations of block doubled, which lets the forward
//! transform use plain prefix doubling in O(n log n) with counting sorts.
//!
//! The inverse walks the first-column/last-column mapping once, also in linear
//! time. Both directions only need the last column plus orig_ptr, the index
//! of the row that reproduces the original block. That row is unambiguous even
//! when the block is periodic, because rotations are compared as a whole: rows
//! that tie produce identical last-column bytes, so the transform output is
//! independent of how ties are broken.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Reusable scratch space for forward.
///
/// Sized once for the largest block the chosen compression level allows and
/// then reused for every block of the stream, so a multi-block stream pays the
/// allocation cost exactly once.
pub const Scratch = struct {
    /// Rotation indices, sorted by prefix doubling.
    sa: []u32,
    /// Equivalence class (rank) of the rotation at each index.
    rank: []u32,
    /// Second index buffer, the input of the stable counting sort.
    shifted: []u32,
    /// Second rank buffer. Ranks cannot be refreshed in place: renaming one
    /// entry can invalidate a comparison that has not been made yet.
    next_rank: []u32,
    /// Counting sort histogram, indexed by rank.
    counts: []u32,

    /// Allocate the rotation-index buffers. Each one is guarded so that a failure
    /// part way through releases the earlier buffers rather than orphaning them.
    pub fn init(gpa: Allocator, max_len: usize) Allocator.Error!Scratch {
        const sa = try gpa.alloc(u32, max_len);
        errdefer gpa.free(sa);
        const rank = try gpa.alloc(u32, max_len);
        errdefer gpa.free(rank);
        const shifted = try gpa.alloc(u32, max_len);
        errdefer gpa.free(shifted);
        const next_rank = try gpa.alloc(u32, max_len);
        errdefer gpa.free(next_rank);
        const counts = try gpa.alloc(u32, max_len);
        return .{
            .sa = sa,
            .rank = rank,
            .shifted = shifted,
            .next_rank = next_rank,
            .counts = counts,
        };
    }

    pub fn deinit(self: *Scratch, gpa: Allocator) void {
        gpa.free(self.sa);
        gpa.free(self.rank);
        gpa.free(self.shifted);
        gpa.free(self.next_rank);
        gpa.free(self.counts);
        self.* = undefined;
    }
};

/// Compute the last column of the sorted-rotation matrix of block and the
/// index of the rotation that starts at byte zero.
///
/// last_column must be exactly block.len bytes long. orig_ptr receives
/// the origPtr field of the encoded block.
pub fn forward(scratch: *Scratch, block: []const u8, last_column: []u8, orig_ptr: *u32) void {
    const n = block.len;
    std.debug.assert(last_column.len == n);

    if (n <= 1) {
        if (n == 1) last_column[0] = block[0];
        orig_ptr.* = 0;
        return;
    }

    const sa = scratch.sa[0..n];
    const rank = scratch.rank[0..n];
    const shifted = scratch.shifted[0..n];
    const next_rank = scratch.next_rank[0..n];
    const counts = scratch.counts[0..n];

    sortRotations(block, sa, rank, shifted, next_rank, counts);

    orig_ptr.* = 0;
    for (sa, 0..) |start, i| {
        last_column[i] = block[if (start == 0) n - 1 else start - 1];
        if (start == 0) orig_ptr.* = @intCast(i);
    }
}

/// Sort the cyclic rotations of block into sa, leaving their equivalence
/// classes in rank.
///
/// Prefix doubling: seed with a counting sort on the single first byte, then
/// repeatedly sort by the pair (rank[i], rank[i + k]) until every rotation has
/// a distinct rank. Each round is one stable counting sort, so the total cost
/// is O(n log n) no matter how repetitive the block is.
fn sortRotations(
    block: []const u8,
    sa: []u32,
    rank: []u32,
    shifted: []u32,
    next_rank: []u32,
    counts: []u32,
) void {
    const n = block.len;
    const n32: u32 = @intCast(n);

    // Seed: bucket by the first byte and number the buckets.
    var bucket: [257]u32 = @splat(0);
    for (block) |b| bucket[b] += 1;
    var running: u32 = 0;
    for (0..256) |i| {
        const count = bucket[i];
        bucket[i] = running;
        running += count;
    }
    for (block, 0..) |b, i| {
        sa[bucket[b]] = @intCast(i);
        bucket[b] += 1;
    }

    var classes: u32 = 1;
    rank[sa[0]] = 0;
    for (1..n) |i| {
        if (block[sa[i]] != block[sa[i - 1]]) classes += 1;
        rank[sa[i]] = classes - 1;
    }

    // Each round doubles the prefix length that rank distinguishes. The loop
    // stops once the ranks are a total order, or once the prefix covers the
    // whole block, whichever happens first; the k < n bound is what keeps
    // fully periodic blocks such as "aaaaa" from looping forever.
    var k: u32 = 1;
    while (k < n32 and classes < n32) {
        // Predecessors in sort order: rotate every entry back by k.
        for (sa, 0..) |start, i| {
            shifted[i] = if (start >= k) start - k else start + n32 - k;
        }

        // Stable counting sort of shifted by rank.
        @memset(counts[0..classes], 0);
        for (shifted) |s| counts[rank[s]] += 1;
        running = 0;
        for (counts[0..classes]) |*c| {
            const value = c.*;
            c.* = running;
            running += value;
        }
        for (shifted) |s| {
            sa[counts[rank[s]]] = s;
            counts[rank[s]] += 1;
        }

        // Renumber by the pair of halves. The new ranks go into a separate
        // buffer because renaming an entry can destroy a pair that has not
        // been compared yet.
        classes = 1;
        next_rank[sa[0]] = 0;
        for (1..n) |i| {
            const a = sa[i];
            const b = sa[i - 1];
            const a2 = if (a + k >= n32) a + k - n32 else a + k;
            const b2 = if (b + k >= n32) b + k - n32 else b + k;
            if (rank[a] != rank[b] or rank[a2] != rank[b2]) classes += 1;
            next_rank[a] = classes - 1;
        }
        @memcpy(rank, next_rank);

        k *= 2;
    }
}

/// Reconstruct block from its last column.
///
/// next is scratch of at least last_column.len entries and is clobbered.
/// For every row i of the sorted matrix, the index of the left rotation
/// of row i is stored at next[start[L[i]] + rank(L[i], i)]. Following
/// that chain from orig_ptr yields the original bytes in order.
///
/// orig_ptr must already have been validated against last_column.len; the
/// caller does that as soon as the decoded block length is known, because a
/// large orig_ptr is exactly what a hostile stream would supply.
pub fn inverse(last_column: []const u8, orig_ptr: u32, out: []u8, next: []u32) void {
    const n = last_column.len;
    std.debug.assert(out.len == n);
    std.debug.assert(next.len >= n);
    if (n == 0) return;
    std.debug.assert(orig_ptr < n);

    // start[c] is the index of the first row beginning with c, i.e. the
    // position of c in the sorted first column.
    var start: [257]u32 = @splat(0);
    for (last_column) |b| start[@as(usize, b) + 1] += 1;
    for (1..257) |i| start[i] += start[i - 1];

    for (last_column, 0..) |b, i| {
        next[start[b]] = @intCast(i);
        start[b] += 1;
    }

    var row = orig_ptr;
    for (out) |*byte| {
        row = next[row];
        byte.* = last_column[row];
    }
}

const testing = std.testing;

fn roundTrip(gpa: Allocator, input: []const u8) !void {
    var scratch = try Scratch.init(gpa, @max(input.len, 1));
    defer scratch.deinit(gpa);

    const last_column = try gpa.alloc(u8, input.len);
    defer gpa.free(last_column);
    const next = try gpa.alloc(u32, input.len);
    defer gpa.free(next);
    const restored = try gpa.alloc(u8, input.len);
    defer gpa.free(restored);

    var orig_ptr: u32 = 0;
    forward(&scratch, input, last_column, &orig_ptr);
    inverse(last_column, orig_ptr, restored, next);
    try testing.expectEqualSlices(u8, input, restored);
}

test "forward and inverse agree on small inputs" {
    const gpa = testing.allocator;
    try roundTrip(gpa, "");
    try roundTrip(gpa, "a");
    try roundTrip(gpa, "ab");
    try roundTrip(gpa, "banana");
    try roundTrip(gpa, "mississippi");
    try roundTrip(gpa, "aaaaaaaaaa");
}

test "forward and inverse agree on periodic blocks" {
    // Every rotation is identical here. Sorting never separates the classes, so
    // this exercises the loop's k < n termination bound.
    const gpa = testing.allocator;
    try roundTrip(gpa, "aaaaa");
    const thousand_a: [1000]u8 = @splat('a');
    try roundTrip(gpa, &thousand_a);
    try roundTrip(gpa, "abababababababab");
    try roundTrip(gpa, "abcabcabcabcabcabc");
}

test "forward and inverse agree on all byte values" {
    const gpa = testing.allocator;
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    try roundTrip(gpa, &all);
}

test "forward and inverse agree on deterministic pseudo-random data" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED_1234);
    const random = prng.random();
    var data: [4096]u8 = undefined;
    random.bytes(&data);
    try roundTrip(gpa, &data);
}

test "forward produces the known Burrows-Wheeler transform of banana" {
    const gpa = testing.allocator;
    var scratch = try Scratch.init(gpa, 6);
    defer scratch.deinit(gpa);

    var last_column: [6]u8 = undefined;
    var orig_ptr: u32 = 0;
    forward(&scratch, "banana", &last_column, &orig_ptr);

    // Rotations sorted: anaban, ananab, banana, nanaba, nabana, nbanan.
    try testing.expectEqualSlices(u8, "nnbaaa", &last_column);
    try testing.expectEqual(@as(u32, 3), orig_ptr);
}

test "forward and inverse agree across a block size boundary" {
    const gpa = testing.allocator;
    var data: [5000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 251);
    try roundTrip(gpa, &data);
}
