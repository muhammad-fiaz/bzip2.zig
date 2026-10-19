---
title: Decompression
description: Decode .bz2 data with one-shot calls, caller-owned buffers, CRC verification, and output caps for untrusted input.
keywords: zig bzip2 decompression, decompress, max_output_size, crc verification, untrusted input
---

# Decompression

## The basic call

```zig
const restored = try bzip2.decompress(gpa, compressed, .{});
defer gpa.free(restored);
```

The returned slice is allocated with `gpa` and belongs to the caller.

## Verification is on by default

Each block carries a CRC of the bytes it encoded, and the stream trailer carries
a CRC combined across all of them. The decoder checks both before handing back
a result, so a stream that survives the call has been verified end to end.

There is no path that returns wrong bytes quietly. A stream that has been
truncated, altered or corrupted returns an error.

Turning verification off saves the CRC work and nothing else:

```zig
const restored = try bzip2.decompress(gpa, compressed, .{ .verify_crc = false });
```

The bytes that come back are the same for undamaged input. What is lost is the
detection of damage, so this is only appropriate for data that is already known
to be intact, such as a stream this process just produced and still holds in
memory.

## Errors that describe the input

Every failure that concerns the stream has its own error, so a caller can tell
the cases apart:

```zig
const restored = bzip2.decompress(gpa, untrusted, .{}) catch |err| switch (err) {
    error.InvalidStreamHeader => return error.NotAnArchive,
    error.UnexpectedEndOfStream => return error.TruncatedArchive,
    error.StreamCrcMismatch, error.BlockCrcMismatch => return error.CorruptArchive,
    error.OutputTooLarge => return error.DecompressionBomb,
    else => return err,
};
```

The distinction matters. A file that is not an archive at all and a file that
was truncated in transit need different messages, and a caller that cannot tell
them apart ends up reporting "corrupt" for everything.

See [Errors](/api/errors) for the full set.

## Capping the output

A small stream can expand into a much larger one, because the run-length stage
encodes a count and a count is cheap. A few hundred bytes of stream can produce
megabytes of output, which means an attacker who controls the input controls
the allocation size.

`max_output_size` bounds the total:

```zig
const restored = try bzip2.decompress(gpa, downloaded, .{
    .max_output_size = 64 * 1024 * 1024,
});
```

Exceeding it produces `error.OutputTooLarge`. Set it to the largest value you
are willing to hold, which is usually just above what a legitimate archive of
the expected kind would expand to.

The limit is a total, not a per-block limit, so a stream that stays under it
across many blocks still succeeds.

## Reading a header without decoding

To learn what a stream declares without decoding it, read the header directly:

```zig
const block_size = try bzip2.blockSizeOfStream(header_bytes);
```

This returns the block size in bytes, which is the level multiplied by 100 kB.
It returns `error.InvalidStreamHeader` for anything that is not a well formed
`BZh<1..9>` prefix, so it is safe to call on data of unknown origin.

## Streaming output

When the result should not be resident all at once, write it out as it arrives:

```zig
try bzip2.decompressStream(gpa, reader, writer, .{});
```

The decoder emits one block at a time through `writer`, so memory use is one
block plus the writer's own buffer regardless of how much the stream expands
to. See [Streaming](/guide/streaming).

## Reusing the decoder

`Decoder` owns its scratch. For a long-lived decoder, use `Decompressor` with a
`Scratch` you keep yourself, and the scratch survives between streams:

```zig
var scratch = try bzip2.Scratch.init(gpa);
defer scratch.deinit();

var decoder: bzip2.Decompressor = .init(.{});
while (next_archive()) |stream| {
    try decoder.stream(stream.reader, stream.writer, &scratch);
}
```

The scratch grows to the largest block size it has seen and stays there, so a
series of streams of similar size does no further allocation.

See [Memory and Allocators](/guide/memory).

## What is rejected

The decoder validates every structural field against the block size the header
declares before using it: the selector count and values, the Huffman code
lengths, the MTF run lengths, `orig_ptr` and the reconstructed block length.
A stream that claims more than it can deliver is refused rather than trusted.

Legacy randomised blocks are supported on both sides. The flag is in the block
header, and the decoder undoes the derandomisation before the inverse transform.
`Randomise` in `src/randomise.zig` holds the table and the masking rule.

## Trailing bytes

Bytes after the end-of-stream marker are ignored, which matches what other
implementations do and lets a stream be concatenated or appended to without
reframing. The `TrailingData` error exists in the set for callers who want to
reject it themselves; the default path does not raise it.