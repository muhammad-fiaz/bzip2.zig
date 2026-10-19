---
layout: home
title: A native BZip2 compression and decompression implementation written in Zig
titleTemplate: false
description: "The pure-Zig BZip2 codec: standard .bz2 files in and out, zero dependencies, no C library, caller-owned memory and I/O, and CRC verification on every stream."
keywords: bzip2.zig, zig bzip2, pure-zig compression, .bz2, native codec

hero:
  name: bzip2.zig
  text: The Pure-Zig BZip2 Codec
  tagline: Standard .bz2 files, bounded memory, and caller-owned allocators and I/O — nothing hidden, nothing linked.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: API Reference
      link: /api/
    - theme: alt
      text: GitHub
      link: https://github.com/muhammad-fiaz/bzip2.zig

features:
  - title: Standard .bz2, both directions
    details: Levels 1 through 9, multi-block streams, the full symbol map, multiple Huffman tables per block, and the legacy randomised block flag. Output is accepted by every BZip2 implementation, and their output is accepted here.
  - title: Bounded memory
    details: The encoder and decoder each hold one block at a time. Streaming and whole-file entry points use the same fixed footprint whether the input is a kilobyte or a terabyte.
  - title: Explicit everything
    details: Every entry point takes the allocator and the I/O it needs. No global allocator, no global file handles, no hidden state.
  - title: Honest errors
    details: Truncated, corrupted and malformed streams are refused with an error that names what was wrong, rather than decoding into plausible-looking wrong bytes.
---

## At a glance

```zig
const compressed = try bzip2.compress(gpa, data, .{ .level = 9 });
const restored = try bzip2.decompress(gpa, compressed, .{});
```

Both slices belong to the caller. Verification is on by default, so `restored`
is either exactly `data` or the call fails.

## When to reach for it

BZip2 trades speed for ratio. Text, source code, logs, database dumps and
uncompressed containers all compress considerably better with it than with a
faster format, at the cost of taking longer. If throughput matters more than
output size, a different format is the better tool.

Use the level to trade between the two. The level is the block size in units of
100 kB, so level 1 codes 100 kB blocks and level 9 codes 900 kB ones.

| | Level 1 | Level 9 |
| --- | --- | --- |
| Block size | 100 kB | 900 kB |
| Compression | faster | slower |
| Ratio | slightly worse | slightly better |

Intermediate levels are often the right answer, because the block-sorting stage
dominates the cost and the difference between the extremes is usually small.

## Reading input you did not create

Streams are validated structurally before use, and both the block and stream
CRCs are verified before a result is returned. For anything fetched from outside
the process, also cap the output:

```zig
const restored = try bzip2.decompress(gpa, downloaded, .{
    .max_output_size = 64 * 1024 * 1024,
});
```

A short stream can expand into a much larger one, and the cap turns that into
`error.OutputTooLarge` instead of an allocation whose size came from the
sender.

## Acknowledgements

This is a from-scratch, native Zig implementation of the BZip2 format. The
format specification and the reference implementation used for this project is
[libarchive/bzip2](https://github.com/libarchive/bzip2).