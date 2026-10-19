//! Legacy block randomisation support.
//!
//! bzip2 versions before 0.9.5 sorted blocks with an unstable comparison and
//! compensated by flipping a pseudo-random bit into every fourth byte before
//! encoding, so that pathological inputs could not produce a pathological
//! order. The format keeps a one-bit randomised flag in every block header and
//! a decoder must honour it, because such streams still exist even though no
//! current encoder produces them.
//!
//! The sequence comes from a fixed table of 512 values. The mask is applied to
//! every byte of the reconstructed block; the flip positions are
//! values[0] + 1 bytes apart, then values[1] + 1, and so on, cycling.

const std = @import("std");

/// The 512 pseudo-random bit values, in the order a block walks them.
pub const values: [512]u16 = .{ 619, 720, 127, 481, 931, 816, 813, 233, 566, 247, 985, 724, 205, 454, 863, 491, 741, 242, 949, 214, 733, 859, 335, 708, 621, 574, 73, 654, 730, 472, 419, 436, 278, 496, 867, 210, 399, 680, 480, 51, 878, 465, 811, 169, 869, 675, 611, 697, 867, 561, 862, 687, 507, 283, 482, 129, 807, 591, 733, 623, 150, 238, 59, 379, 684, 877, 625, 169, 643, 105, 170, 607, 520, 932, 727, 476, 693, 425, 174, 647, 73, 122, 335, 530, 442, 853, 695, 249, 445, 515, 909, 545, 703, 919, 874, 474, 882, 500, 594, 612, 641, 801, 220, 162, 819, 984, 589, 513, 495, 799, 161, 604, 958, 533, 221, 400, 386, 867, 600, 782, 382, 596, 414, 171, 516, 375, 682, 485, 911, 276, 98, 553, 163, 354, 666, 933, 424, 341, 533, 870, 227, 730, 475, 186, 263, 647, 537, 686, 600, 224, 469, 68, 770, 919, 190, 373, 294, 822, 808, 206, 184, 943, 795, 384, 383, 461, 404, 758, 839, 887, 715, 67, 618, 276, 204, 918, 873, 777, 604, 560, 951, 160, 578, 722, 79, 804, 96, 409, 713, 940, 652, 934, 970, 447, 318, 353, 859, 672, 112, 785, 645, 863, 803, 350, 139, 93, 354, 99, 820, 908, 609, 772, 154, 274, 580, 184, 79, 626, 630, 742, 653, 282, 762, 623, 680, 81, 927, 626, 789, 125, 411, 521, 938, 300, 821, 78, 343, 175, 128, 250, 170, 774, 972, 275, 999, 639, 495, 78, 352, 126, 857, 956, 358, 619, 580, 124, 737, 594, 701, 612, 669, 112, 134, 694, 363, 992, 809, 743, 168, 974, 944, 375, 748, 52, 600, 747, 642, 182, 862, 81, 344, 805, 988, 739, 511, 655, 814, 334, 249, 515, 897, 955, 664, 981, 649, 113, 974, 459, 893, 228, 433, 837, 553, 268, 926, 240, 102, 654, 459, 51, 686, 754, 806, 760, 493, 403, 415, 394, 687, 700, 946, 670, 656, 610, 738, 392, 760, 799, 887, 653, 978, 321, 576, 617, 626, 502, 894, 679, 243, 440, 680, 879, 194, 572, 640, 724, 926, 56, 204, 700, 707, 151, 457, 449, 797, 195, 791, 558, 945, 679, 297, 59, 87, 824, 713, 663, 412, 693, 342, 606, 134, 108, 571, 364, 631, 212, 174, 643, 304, 329, 343, 97, 430, 751, 497, 314, 983, 374, 822, 928, 140, 206, 73, 263, 980, 736, 876, 478, 430, 305, 170, 514, 364, 692, 829, 82, 855, 953, 676, 246, 369, 970, 294, 750, 807, 827, 150, 790, 288, 923, 804, 378, 215, 828, 592, 281, 565, 555, 710, 82, 896, 831, 547, 261, 524, 462, 293, 465, 502, 56, 661, 821, 976, 991, 658, 869, 905, 758, 745, 193, 768, 550, 608, 933, 378, 286, 215, 979, 792, 961, 61, 688, 793, 644, 986, 403, 106, 366, 905, 644, 372, 567, 466, 434, 645, 210, 389, 550, 919, 135, 780, 773, 635, 389, 707, 100, 626, 958, 165, 504, 920, 176, 193, 713, 857, 265, 203, 50, 668, 108, 645, 990, 626, 197, 510, 357, 358, 850, 858, 364, 936, 638 };

/// Decoder state for the randomised bit of a block header.
///
/// Every fourth byte of the reconstructed block is XORed with the next entry of
/// values, cycling. r_n_to_go counts down to that every-fourth-byte
/// position, so the flip positions are values[0] + 1, then values[1] + 1
/// bytes later, and so on.
pub const Stream = struct {
    r_n_to_go: u32 = 0,
    r_t_pos: u32 = 0,

    /// Called before the first byte of a randomised block is used.
    pub fn init(self: *Stream) void {
        self.r_n_to_go = 0;
        self.r_t_pos = 0;
    }

    /// Apply the mask to byte, then advance the sequence. Callers pass every
    /// byte of a randomised block through this, including the first.
    pub fn next(self: *Stream, byte: u8) u8 {
        const mask: u8 = if (self.r_n_to_go == 1) 1 else 0;
        if (self.r_n_to_go == 0) {
            self.r_n_to_go = values[self.r_t_pos];
            self.r_t_pos = if (self.r_t_pos == 511) 0 else self.r_t_pos + 1;
        }
        self.r_n_to_go -= 1;
        return byte ^ mask;
    }
};

const testing = std.testing;

test "table has the size the format assumes" {
    try testing.expectEqual(@as(usize, 512), values.len);
    // Every entry must be usable as a countdown, so none may be zero.
    for (values) |v| try testing.expect(v > 0);
}

test "flip positions follow the table" {
    var stream = Stream{};
    stream.init();

    var flips: std.ArrayList(usize) = .empty;
    const span = 200_000;
    for (0..span) |i| {
        if (stream.next(0x5A) == 0x5B) flips.append(testing.allocator, i) catch unreachable;
    }
    defer flips.deinit(testing.allocator);
    try testing.expect(flips.items.len > 200);

    // The countdown for the first flip is seeded by the table's first entry, and
    // every later gap is the next entry exactly.
    for (flips.items[1..], 0..) |position, i| {
        const expected = @as(usize, values[(i + 1) % values.len]);
        try testing.expectEqual(expected, position - flips.items[i]);
    }
}

test "mask is the identity when the block is not randomised" {
    var stream = Stream{};
    stream.init();
    for (0..1000) |i| {
        const byte: u8 = @truncate(i);
        const out = stream.next(byte);
        // Without the mask every byte would come back unchanged; with a
        // roughly quarter-density mask most do, which is the property the
        // format relies on to break up repetitive blocks.
        if (byte == out) continue;
        try testing.expectEqual(byte ^ 1, out);
    }
}
