---
title: Basic Compression
description: A minimal bzip2.zig program — compress a string, read the header back, decompress and verify.
keywords: zig bzip2 example, compress string, hello world, one-shot
---

# Basic Compression

Compresses a string and reads the header back.

```bash
zig build run-basic_compression
```

Source: [`examples/basic_compression.zig`](https://github.com/muhammad-fiaz/bzip2.zig/blob/main/examples/basic_compression.zig)

## The program

```zig
const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const sentence = "The quick brown fox jumps over the lazy dog. ";
    var input: [sentence.len * 20]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = sentence[i % sentence.len];

    const compressed = try bzip2.compress(gpa, &input, .{});
    defer gpa.free(compressed);

    std.debug.print("input:      {d} bytes\n", .{input.len});
    std.debug.print("compressed: {d} bytes\n", .{compressed.len});
    std.debug.print("ratio:      {d:.2}x\n", .{
        @as(f64, @floatFromInt(input.len)) / @as(f64, @floatFromInt(compressed.len)),
    });
    std.debug.print("block size: {d} bytes\n", .{try bzip2.blockSizeOfStream(compressed)});
}
```

## Output

```text
input:      900 bytes
compressed: 124 bytes
ratio:      7.26x
block size: 900000 bytes
```

## What to notice

The block size is 900,000 because omitting `options` uses level 9. The same
call with `.{ .level = 1 }` reports 100,000.

Both buffers belong to the caller. `defer gpa.free` releases the compressed
slice; the input array is on the stack and needs nothing.

`blockSizeOfStream` reads the header without decoding, so it costs nothing
beyond the first four bytes.

## Related

- [Compression](/guide/compression)
- [Decoder Semantics](/examples/decoder_semantics) shows the round trip with
  statistics
- `compression_levels.zig` prints the whole level table