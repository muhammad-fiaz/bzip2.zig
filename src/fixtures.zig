//! Embedded regression fixtures: complete streams this library must keep
//! reading, and re-encoding, exactly as they are stored here.
//!
//! Every stream below was produced once and recorded together with the
//! properties the suite checks forever after. There is no tolerance: the tests
//! are exact. See README.md for how these fixtures fit the verification story.

const std = @import("std");
const testing = std.testing;

const bzip2 = @import("bzip2.zig");
const utils = @import("utils.zig");

/// Block size a stream was written with, 1..9.
pub const Level = u8;

/// One recorded stream with everything the suite checks about it.
pub const Fixture = struct {
    /// File name inside the fixtures directory.
    name: []const u8,
    /// Block size the stream was written with, from its BZhN header.
    level: Level,
    /// Bytes of plaintext the stream held when it was produced.
    input_size: usize,
    /// Compressed byte count recorded at generation time.
    stream_size: usize,
    /// SHA-256 of that plaintext, lowercase hex.
    plaintext_sha256: *const [64]u8,
    /// Whether this project's encoder reproduces this stream byte for byte.
    /// false marks a stream whose encoding differs only in the origPtr field,
    /// a block-sort rotation that ties; both forms are valid streams of the
    /// same block. The flag tells the re-encoding test what to expect.
    byte_identical: bool,
};

/// The streams that complete the round-trip shape coverage, together with the
/// recorded properties they must keep satisfying.
pub const generated = [_]Fixture{
    .{
        .name = "empty_l1.bz2",
        .level = 1,
        .input_size = 0,
        .stream_size = 14,
        .plaintext_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        .byte_identical = true,
    },
    .{
        .name = "one_byte_l9.bz2",
        .level = 9,
        .input_size = 1,
        .stream_size = 37,
        .plaintext_sha256 = "df7e70e5021544f4834bbee64a9e3789febc4be81470df629cad6ddb03320a5c",
        .byte_identical = true,
    },
    .{
        .name = "short_text_l9.bz2",
        .level = 9,
        .input_size = 44,
        .stream_size = 81,
        .plaintext_sha256 = "ef537f25c895bfa782526529a9b63d97aa631564d5d789c2b765448c8635fb6c",
        .byte_identical = true,
    },
    .{
        .name = "all_byte_values_l9.bz2",
        .level = 9,
        .input_size = 256,
        .stream_size = 425,
        .plaintext_sha256 = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880",
        .byte_identical = true,
    },
    .{
        .name = "long_runs_l1.bz2",
        .level = 1,
        .input_size = 6000,
        .stream_size = 51,
        .plaintext_sha256 = "6ff13041be655d2dfcab0405d403f613479fe4f4dc063e05e92b59c5e46c9473",
        .byte_identical = true,
    },
    .{
        .name = "repetitive_l9.bz2",
        .level = 9,
        .input_size = 64800,
        .stream_size = 47,
        .plaintext_sha256 = "b93a0c847cb559bf5d1b932742799a413817002446803bf3fc1c8c284c113f68",
        .byte_identical = false,
    },
    .{
        .name = "plain_text_l9.bz2",
        .level = 9,
        .input_size = 6080,
        .stream_size = 508,
        .plaintext_sha256 = "724ef9d408da24f6e2b9447db6f3f1ee737db36c464e6008e42628e7e509f5e2",
        .byte_identical = true,
    },
    .{
        .name = "low_entropy_struct_l1.bz2",
        .level = 1,
        .input_size = 6750,
        .stream_size = 116,
        .plaintext_sha256 = "1e5425469f67e896213feac08e8be24c7817d0ffccac0f03efdcd37dcc4fe5d3",
        .byte_identical = false,
    },
    .{
        .name = "high_entropy_l1.bz2",
        .level = 1,
        .input_size = 20480,
        .stream_size = 20945,
        .plaintext_sha256 = "107be1430fe9da4347c0b5492aa3cdb6a814eb9d33bede17c92e144917c1c04b",
        .byte_identical = true,
    },
    .{
        .name = "block_boundary_l1.bz2",
        .level = 1,
        .input_size = 100001,
        .stream_size = 261,
        .plaintext_sha256 = "bcdf4b01805341db4522f21ff7adf8a3be54e1b618512b9e284d675d700448d2",
        .byte_identical = true,
    },
    .{
        .name = "multi_block_l1.bz2",
        .level = 1,
        .input_size = 250001,
        .stream_size = 584,
        .plaintext_sha256 = "f694acf457e9170bfcadbeeff2d48db9e7e3f8e72185710aaf908738f7c82c42",
        .byte_identical = true,
    },
};

/// Three recorded samples of real-world text, one of which (sample3) was
/// written with the legacy randomised block flag. Levels are read off each
/// BZh header.
pub const samples = [_]Fixture{
    .{
        .name = "sample1.bz2",
        .level = 1,
        .input_size = 98696,
        .stream_size = 32348,
        .plaintext_sha256 = "af423164ec87f495f7d450fee9bdd418c12114cd305de2384fd20b91ba7994c2",
        .byte_identical = true,
    },
    .{
        .name = "sample2.bz2",
        .level = 2,
        .input_size = 212340,
        .stream_size = 73732,
        .plaintext_sha256 = "316ad6713f2c05413e0b9eac132840d092674e7de4138251d3552f98671fcf9a",
        .byte_identical = true,
    },
    .{
        .name = "sample3.bz2",
        .level = 3,
        .input_size = 120244,
        .stream_size = 235,
        .plaintext_sha256 = "6be9c2bd214924b18db0d57b9a14d6f4eeb0b276cd3a980aed91521cca3199dd",
        .byte_identical = true,
    },
};

/// Every fixture, in one list.
pub const all: []const Fixture = &all_array;
const all_array: [generated.len + samples.len]Fixture = generated ++ samples;

/// The bytes of a fixture, embedded at compile time.
pub fn fixtureBytes(fixture: Fixture) []const u8 {
    if (std.mem.eql(u8, fixture.name, "empty_l1.bz2"))
        return @embedFile("fixtures/empty_l1.bz2");
    if (std.mem.eql(u8, fixture.name, "one_byte_l9.bz2"))
        return @embedFile("fixtures/one_byte_l9.bz2");
    if (std.mem.eql(u8, fixture.name, "short_text_l9.bz2"))
        return @embedFile("fixtures/short_text_l9.bz2");
    if (std.mem.eql(u8, fixture.name, "all_byte_values_l9.bz2"))
        return @embedFile("fixtures/all_byte_values_l9.bz2");
    if (std.mem.eql(u8, fixture.name, "long_runs_l1.bz2"))
        return @embedFile("fixtures/long_runs_l1.bz2");
    if (std.mem.eql(u8, fixture.name, "repetitive_l9.bz2"))
        return @embedFile("fixtures/repetitive_l9.bz2");
    if (std.mem.eql(u8, fixture.name, "plain_text_l9.bz2"))
        return @embedFile("fixtures/plain_text_l9.bz2");
    if (std.mem.eql(u8, fixture.name, "low_entropy_struct_l1.bz2"))
        return @embedFile("fixtures/low_entropy_struct_l1.bz2");
    if (std.mem.eql(u8, fixture.name, "high_entropy_l1.bz2"))
        return @embedFile("fixtures/high_entropy_l1.bz2");
    if (std.mem.eql(u8, fixture.name, "block_boundary_l1.bz2"))
        return @embedFile("fixtures/block_boundary_l1.bz2");
    if (std.mem.eql(u8, fixture.name, "multi_block_l1.bz2"))
        return @embedFile("fixtures/multi_block_l1.bz2");
    if (std.mem.eql(u8, fixture.name, "sample1.bz2"))
        return @embedFile("fixtures/sample1.bz2");
    if (std.mem.eql(u8, fixture.name, "sample2.bz2"))
        return @embedFile("fixtures/sample2.bz2");
    if (std.mem.eql(u8, fixture.name, "sample3.bz2"))
        return @embedFile("fixtures/sample3.bz2");
    unreachable;
}

/// Lowercase hex digest of a SHA-256 value, produced over the recorded
/// plaintext constants above during a test run so a transcribing slip
/// fails loudly rather than matching a false constant.
fn hexDigest(digest: [32]u8) [64]u8 {
    var out: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0x0f];
    }
    return out;
}

test "every embedded fixture matches its declared size and level" {
    inline for (all) |fixture| {
        const stream = fixtureBytes(fixture);
        try testing.expectEqual(fixture.stream_size, stream.len);
        try testing.expectEqual(
            @as([3]u8, .{ utils.magic_b, utils.magic_z, utils.magic_h }),
            stream[0..3].*,
        );
        try testing.expectEqual(fixture.level, stream[3] - utils.magic_0);
    }
}

test "every embedded fixture decompresses to its recorded plaintext" {
    const gpa = testing.allocator;
    inline for (all) |fixture| {
        const stream = fixtureBytes(fixture);
        const restored = try bzip2.decompress(gpa, stream, .{});
        defer gpa.free(restored);
        try testing.expectEqual(fixture.input_size, restored.len);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(restored, &digest, .{});
        const got = hexDigest(digest);
        if (!std.mem.eql(u8, fixture.plaintext_sha256, &got)) {
            std.debug.print("fixture {s}: hash {s}\n", .{ fixture.name, &got });
        }
        try testing.expectEqualStrings(fixture.plaintext_sha256, &got);
    }
}

test "re-encoding the recorded streams reproduces them" {
    const gpa = testing.allocator;
    inline for (all) |fixture| {
        const stream = fixtureBytes(fixture);
        const plain = try bzip2.decompress(gpa, stream, .{});
        defer gpa.free(plain);
        const composed = try bzip2.compress(gpa, plain, .{ .level = fixture.level });
        defer gpa.free(composed);

        try testing.expectEqual(fixture.stream_size, composed.len);

        if (fixture.byte_identical) {
            try testing.expectEqualSlices(u8, stream, composed);
        } else {
            // Equally valid encodings of the same block: identical bytes up
            // to and past the 24-bit origPtr field, except inside it.
            try testing.expectEqualSlices(u8, stream[0..15], composed[0..15]);
            try testing.expectEqualSlices(u8, stream[18..], composed[18..]);
        }
    }
}

test "a truncated fixture is refused rather than reported as decoded" {
    const gpa = testing.allocator;
    inline for (all) |fixture| {
        const stream = fixtureBytes(fixture);
        // Cut somewhere inside or after the data, never just the header.
        const short = stream[0 .. stream.len - 1];
        const result = bzip2.decompress(gpa, short, .{});
        try testing.expectError(error.UnexpectedEndOfStream, result);
    }
}

test "fixture decoding agrees between the one-shot and streaming APIs" {
    const gpa = testing.allocator;
    inline for (all) |fixture| {
        const stream = fixtureBytes(fixture);

        var sink: std.Io.Writer.Allocating = .init(gpa);
        defer sink.deinit();
        var decoder = try decompress.Decoder.init(gpa, .{});
        defer decoder.deinit();
        var source = std.Io.Reader.fixed(stream);
        try decoder.stream(&source, &sink.writer);

        const restored = try sink.toOwnedSlice();
        defer gpa.free(restored);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(restored, &digest, .{});
        const got = hexDigest(digest);
        try testing.expectEqualStrings(fixture.plaintext_sha256, &got);
    }
}

// Imported here so the fixture tests always compile alongside the code they
// exercise; the codec wiring stays in one place.
const compress = @import("compress.zig");
const decompress = @import("decompress.zig");
