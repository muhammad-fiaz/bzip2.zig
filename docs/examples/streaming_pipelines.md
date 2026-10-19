---
title: Streaming Pipelines
description: Bind a source reader to a sink writer through the bzip2.zig streaming entry points, in both directions, in constant memory.
keywords: streaming example, reader writer pipeline, constant memory, incremental
---

# Streaming Pipelines

Binds a source reader to a sink writer through the streaming entry points, in
both directions, in constant memory.

```bash
zig build run-streaming_pipelines
```

Source: [`examples/streaming_pipelines.zig`](https://github.com/muhammad-fiaz/bzip2.zig/blob/main/examples/streaming_pipelines.zig)

## Output

```text
input:       2500000 bytes
compressed:  600768 bytes at level 1 (4.16x)
block size:  100000 bytes (so 26 blocks were framed)
round trip verified: 2500000 bytes identical
```

## The program

2.5 MB of repeating text wrapped in a fixed reader; the library pulls what it
needs when it needs it:

```zig
var compressed: std.Io.Writer.Allocating = .init(gpa);
defer compressed.deinit();

var source = std.Io.Reader.fixed(input.items);
try bzip2.compressStream(gpa, &source, &compressed.writer, .{ .level = 1 });
const stream = try compressed.toOwnedSlice();
```

Decompression through the streaming entry point, into an allocating sink:

```zig
var restored: std.Io.Writer.Allocating = .init(gpa);
defer restored.deinit();

var archive = std.Io.Reader.fixed(stream);
try bzip2.decompressStream(gpa, &archive, &restored.writer, .{});
const output = try restored.toOwnedSlice();
```

## What to notice

Memory stays at one level times 100 kB of block scratch, whatever the size of
the input. `compressStream` creates a `Compressor` for the duration of the
call; use `Compressor` directly when several streams should share the same
buffers.

The block count comes from `blockSizeOfStream`, which reads the level out of
the header without decoding anything.

The round trip is checked by value after the stream decoder has verified every
block CRC and the stream CRC.

## Where a reader is a file or a socket

`std.Io.Reader.fixed` and `std.Io.Writer.Allocating` are just two
implementations of the same interface. A file reader built from
`file.readerStreaming(io, &buffer)` and a file writer built from
`file.writerStreaming(io, &buffer)` drop into the same calls unchanged.

## Related

- [Streaming](/guide/streaming)
- [Compressor](/api/compressor)
- [Decompressor](/api/decompressor)
- `large_file.zig` processes 16 MiB the same way
