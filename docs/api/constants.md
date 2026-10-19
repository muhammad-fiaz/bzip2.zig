# Constants

## Version

```zig
pub const version_string: []const u8 = "0.0.1";
pub const version_major: u32 = 0;

pub fn version() struct { major: u32, minor: u32, patch: u32 };
```

```zig
const version = bzip2.version();
// .{ .major = 0, .minor = 0, .patch = 1 }

try std.testing.expectEqualStrings("0.0.1", bzip2.version_string);
```

`version_major` lets a caller gate on a feature without depending on the patch
number:

```zig
if (bzip2.version_major >= 1) {
    // a feature added in 1.0
}
```

## Format limits

```zig
pub const max_block_size: usize = 900_000;
```

The largest block the format allows. Level 9 uses it. Input larger than one
block becomes a multi-block stream automatically; nothing needs to be
configured.

```zig
// A single block at level 9 is 900 kB of coded data.
const largest = bzip2.max_block_size;
```

## Reading a header

```zig
pub fn blockSizeOfStream(data: []const u8) Error!usize;
```

Returns the block size in bytes, which is the level multiplied by 100 kB:

| Level | Block size |
| --- | --- |
| 1 | 100,000 |
| 2 | 200,000 |
| 3 | 300,000 |
| 4 | 400,000 |
| 5 | 500,000 |
| 6 | 600,000 |
| 7 | 700,000 |
| 8 | 800,000 |
| 9 | 900,000 |

```zig
try std.testing.expectEqual(
    @as(usize, 900_000),
    try bzip2.blockSizeOfStream("BZh9"),
);
try std.testing.expectEqual(
    @as(usize, 100_000),
    try bzip2.blockSizeOfStream("BZh1"),
);
```

Four bytes are enough to answer, and nothing is decoded. Anything that is not a
well formed `BZh<1..9>` prefix returns `error.InvalidStreamHeader`, which makes
the function safe to call on data of unknown origin:

```zig
try std.testing.expectError(
    error.InvalidStreamHeader,
    bzip2.blockSizeOfStream("not a bzip2 stream"),
);
```

## Sizing a buffer

```zig
pub fn maxCompressedSize(input_size: usize, level: u8) Error!usize;
```

An upper bound on the compressed size of `input_size` bytes at `level`:

```zig
const capacity = try bzip2.maxCompressedSize(4 * 1024 * 1024, 9);
```

The bound accounts for the 5/4 expansion the run-length stage can cause, plus
per-block framing and the Huffman symbol and selector tables. It is generous by
design and exists so a caller can size one buffer before compressing into it. It
is not a prediction of the result.

Returns `error.InvalidCompressionLevel` for a level outside 1 through 9.

## Convenience aliases

```zig
pub const Level = u8;
```

The compression level, 1 through 9. Used as the `level` field of
`CompressionOptions`: it is the block size in units of 100 kB, not a speed
setting.

## Stats

```zig
pub const Stats = struct {
    blocks: u64,
    output_bytes: usize,
};
```

Populated on a `Decompressor` after a stream completes:

```zig
try decoder.stream(reader, writer);
const stats = decoder.decompressor.stats;
```

| Field | Meaning |
| --- | --- |
| `blocks` | Number of blocks decoded |
| `output_bytes` | Total bytes written to the sink |

## Module layout

| File | Contents |
| --- | --- |
| `src/bzip2.zig` | Public API |
| `src/compress.zig` | Encoder |
| `src/decompress.zig` | Decoder |
| `src/bwt.zig` | Burrows-Wheeler transform |
| `src/huffman.zig` | Huffman code construction and decoding |
| `src/mtf.zig` | Move-to-front and run lengths |
| `src/rle.zig` | Run-length stage |
| `src/randomise.zig` | Legacy randomised block support |
| `src/utils.zig` | Constants, errors, CRC, bit level I/O |

| Directory | Contents |
| --- | --- |
| `examples/` | Ten runnable programs |

Format constants, the CRC implementation and the bit-level readers and writers
live in `src/utils.zig`. They are internal rather than re-exported, because they
describe the wire format rather than the library's surface.