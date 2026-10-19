---
title: Options
description: CompressionOptions — the level field, its default, and what the level controls in the encoded stream.
keywords: compression options, compression level, block size, defaults
---

# Options

## CompressionOptions

```zig
pub const CompressionOptions = struct {
    level: u8 = 9,
};
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `level` | `u8` | `9` | Block size in units of 100 kB, 1 through 9 |

The level is written into the stream header, so any decoder reads it back and
adapts. `blockSizeOfStream` recovers it:

```zig
const compressed = try bzip2.compress(gpa, data, .{ .level = 3 });
const block_size = try bzip2.blockSizeOfStream(compressed);
// 300_000
```

Anything outside 1 through 9 is refused with `error.InvalidCompressionLevel`,
before any work is done:

```zig
try std.testing.expectError(
    error.InvalidCompressionLevel,
    bzip2.Compressor.init(gpa, .{ .level = 0 }),
);
```

Omitting the whole struct uses the defaults:

```zig
const compressed = try bzip2.compress(gpa, data, .{});
```

## DecompressionOptions

```zig
pub const DecompressionOptions = struct {
    max_output_size: ?usize = null,
    verify_crc: bool = true,
};
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `max_output_size` | `?usize` | `null` | Refuse to produce more than this many bytes in total |
| `verify_crc` | `bool` | `true` | Check the per-block and stream CRCs |

### max_output_size

Bounds the total output. A few hundred bytes of stream can expand into megabytes
because the run-length stage encodes a count in a single byte, so a caller that
accepts input from elsewhere should always set this:

```zig
const restored = try bzip2.decompress(gpa, downloaded, .{
    .max_output_size = 64 * 1024 * 1024,
});
```

Exceeding the limit produces `error.OutputTooLarge`. The check happens as the
stream is decoded, so the limit holds even when the stream would have expanded
far beyond it.

`null` means unbounded, which is only appropriate for trusted input.

The limit is a total, not a per-block limit, so a large stream made of many
small blocks still succeeds if the sum stays under it.

### verify_crc

On by default. Each block carries a CRC of the bytes it encoded and the stream
trailer carries a CRC combined across all of them. Both are checked before a
result is returned.

Turning this off saves the CRC computation and only that. The bytes returned for
undamaged input are identical either way, so the trade is the integrity check
and nothing else:

```zig
const restored = try bzip2.decompress(gpa, trusted, .{ .verify_crc = false });
```

Use it only where the data is already known to be intact, such as a stream this
process produced and still holds in memory.

## Passing options

Every entry point that takes options accepts `.{}` for the defaults:

```zig
bzip2.compress(gpa, data, .{});
bzip2.compress(gpa, data, .{ .level = 6 });
bzip2.decompress(gpa, stream, .{});
bzip2.decompress(gpa, stream, .{ .max_output_size = 1 << 20 });
```

Field names are lower case, following Zig practice. Options are passed by
value; there is nothing to free.

## Both together

```zig
var decoder = try bzip2.Decoder.init(gpa, .{
    .max_output_size = 512 * 1024 * 1024,
    .verify_crc = true,
});
defer decoder.deinit();
```

The same struct is accepted by `decompress`, `decompressStream`,
`decompressFile` and `Decoder.init`.