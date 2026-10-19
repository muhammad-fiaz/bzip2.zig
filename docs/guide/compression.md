---
title: Compression
description: Choose a compression level, understand block sizes and scratch memory, and bound worst-case output with maxCompressedSize.
keywords: zig bzip2 compression level, block size, maxCompressedSize, scratch memory, level 9
---

# Compression

## Choosing a level

The level is the block size in units of 100 kB. Level 1 uses 100 kB blocks and
level 9 uses 900 kB ones, and the value is written into the stream header so any
decoder reads it back.

```zig
const compressed = try bzip2.compress(gpa, data, .{ .level = 6 });
```

BZip2 is not a fast format. The block-sorting stage dominates the cost, and it
runs over each block separately, so smaller blocks mean more of that work but a
better fit for local structure.

In practice the difference between level 1 and level 9 is often only a few
percent of output size, while the time difference is much larger. Middle levels
frequently give most of the benefit at a fraction of the cost. Measure with
your own data rather than trusting a rule of thumb; the
`compression_levels` example prints the whole table for a sample input.

## What the level is not

The level is not a speed setting in the usual sense. It does not change how
hard the transform tries, only how much data each block holds. Making blocks
smaller does not make the format faster overall; it makes it better, at the cost
of running the expensive stage more often.

## Output size

For compressible input the result is much smaller than the input:

```zig
const compressed = try bzip2.compress(gpa, text, .{ .level = 9 });
// 900 bytes of repeated prose became 124 bytes
```

For input that does not compress, the result is slightly larger. The format has
no stored mode, so every byte has to go through the transform. The overhead is
bounded, not unbounded, and for non-trivial inputs it stays well under half:

```zig
const compressed = try bzip2.compress(gpa, random_bytes, .{ .level = 1 });
// well under input.len * 1.5 for incompressible input, at any size where
// framing matters
```

If you need a format that never grows, that is a property to choose elsewhere.
BZip2 is for the case where a modest size increase is an acceptable price for
much better ratio on the data that does compress.

## Blocks and multi-block streams

Input larger than one block becomes a multi-block stream automatically. Nothing
needs to be configured, and the decoder reassembles it:

```zig
// 5 MB at level 1 is about 50 blocks; this is not a special case to handle.
const compressed = try bzip2.compress(gpa, large_input, .{ .level = 1 });
```

## Sizing a destination buffer

When the destination has to be allocated up front, ask for the bound rather than
guessing:

```zig
const capacity = try bzip2.maxCompressedSize(input.len, 9);
```

The bound is generous by design. It accounts for the 5/4 expansion that the
run-length stage can cause, plus per-block framing and table overhead. It is
meant for sizing an allocation, not for predicting the result; the real figure
is usually far below it.

## Feeding the encoder in chunks

`Compressor` accepts any number of writes. Chunk boundaries do not have to line
up with block boundaries:

```zig
var compressor = try bzip2.Compressor.init(gpa, .{ .level = 9 });
defer compressor.deinit();

try compressor.write(writer, first);
try compressor.write(writer, second);
try compressor.finish(writer);
```

`finish` writes the stream trailer and the combined CRC. It has to be called;
without it the output is not a valid stream.

The slice passed to `write` is borrowed for the duration of the call and is not
retained afterwards.

## Reusing the encoder

`reset` returns the encoder to its initial state while keeping the buffers it
already has, so the next stream does not reallocate:

```zig
for (inputs) |data| {
    compressor.reset();
    try compressor.write(writer, data);
    try compressor.finish(writer);
}
```

Without the `reset`, a second `write` continues the current stream rather than
starting a new one.

## Empty input

Empty input produces a valid fourteen byte stream: a four byte header, the
six byte end marker, and the four byte combined CRC.

```zig
const compressed = try bzip2.compress(gpa, "", .{});
try std.testing.expectEqual(@as(usize, 14), compressed.len);
```

## Binary data

BZip2 stores lengths rather than delimiters, so NUL bytes and every other byte
value are ordinary data. Nothing special is required of the caller, and no
transcoding is needed:

```zig
const compressed = try bzip2.compress(gpa, binary_blob, .{ .level = 9 });
const restored = try bzip2.decompress(gpa, compressed, .{});
try std.testing.expectEqualSlices(u8, binary_blob, restored);
```