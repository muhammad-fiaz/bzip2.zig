---
title: Decompressor
description: Decoder, DecoderOwnedScratch and Scratch — incremental BZip2 decoding through any std.Io.Reader, with CRC verification built in.
keywords: zig decoder, incremental decompression, std.Io.Reader, scratch buffers, crc verification
---

# Decompressor

Three types cover decoding. They do the same work and differ only in who owns
the scratch buffers.

| Type | Scratch ownership |
| --- | --- |
| `Decoder` | Owned by the decoder |
| `Decompressor` | Owned by the caller, passed to `stream` |
| `Scratch` | A buffer set that can be reused across decoders |

## Decoder

```zig
pub const Decoder = struct {
    pub fn init(gpa: std.mem.Allocator, options: DecompressionOptions) Allocator.Error!Decoder;
    pub fn deinit(self: *Decoder) void;
    pub fn stream(self: *Decoder, reader: *std.Io.Reader, writer: *std.Io.Writer) StreamError!void;
    pub fn reset(self: *Decoder) void;

    pub decompressor: Decompressor;
};
```

The shortest form, and the right one for a single decompression:

```zig
var decoder = try bzip2.Decoder.init(gpa, .{});
defer decoder.deinit();

try decoder.stream(&source, &writer);
```

The buffers are allocated on construction and kept until `deinit`, so a decoder
reused across streams does no further allocation.

## Decompressor

```zig
pub const Decompressor = struct {
    pub fn init(options: DecompressionOptions) Decompressor;
    pub fn stream(
        self: *Decompressor,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        scratch: *Scratch,
    ) StreamError!void;
};
```

The same behaviour with the ownership lifted out. `init` takes no allocator
because it allocates nothing.

```zig
var scratch = try bzip2.Scratch.init(gpa);
defer scratch.deinit();

var decoder: bzip2.Decompressor = .init(.{});
try decoder.stream(&source, &writer, &scratch);
```

This is the form to use when one scratch should serve many decoders, or when the
scratch has to outlive the decoder.

## Scratch

```zig
pub const Scratch = struct {
    pub fn init(gpa: std.mem.Allocator) Allocator.Error!Scratch;
    pub fn ensure(self: *Scratch, block_size: usize) Allocator.Error!void;
    pub fn deinit(self: *Scratch) void;
};
```

Reusable decoder buffers, sized from the block size the stream header declares
and grown on demand.

`init` allocates only the fixed output window. `ensure` is called by `stream` and
grows the block-sized buffers when a stream declares a larger block than any
seen before. After that they stay at the high-water mark, so a series of
similarly sized streams does no further allocation.

One `Scratch` may not be shared between decoders running at the same time. It
holds no synchronisation. Concurrent decoding needs one scratch per thread.

## Decoding

`stream` reads from `reader` and writes to `writer`, one block at a time:

```zig
var buffered = file.readerStreaming(io, &read_buffer);
var writing = out_file.writerStreaming(io, &write_buffer);
try decoder.stream(&buffered.interface, &writing.interface);
try writing.interface.flush();
```

Output is produced incrementally, so the whole result never has to be resident.
The writer is left holding whatever it had buffered; flush it when that matters.

## Reusing a decoder

```zig
var decoder = try bzip2.Decoder.init(gpa, .{});
defer decoder.deinit();

while (next_archive()) |stream| {
    try decoder.stream(stream.reader, stream.writer);
}
```

Buffers persist across calls, so this allocates once. Reset is only needed if a
call failed; a decoder that completed a stream is ready for the next one.

## Statistics

```zig
try decoder.stream(&source, &writer);
const stats = decoder.decompressor.stats;
// stats.blocks      number of blocks decoded
// stats.output_bytes total bytes written
```

Useful for reporting on an archive or for sanity-checking an expansion.

## Verification and limits

Both options apply to streaming exactly as they do to the one-shot call:

```zig
var decoder = try bzip2.Decoder.init(gpa, .{
    .max_output_size = 512 * 1024 * 1024,
    .verify_crc = true,
});
```

The output limit is checked as decoding proceeds and produces
`error.OutputTooLarge`. It bounds the whole stream, not one block.

## Failure

A decoder that fails mid-stream cannot be resumed. The reader has consumed part
of the input and the stream cannot be parsed from where it stopped, so a failed
decoder should be discarded. The scratch it used is still valid and can go
straight into the next decoder.

## See also

- [Streaming](/guide/streaming)
- [Memory and Allocators](/guide/memory)
- [Errors](/api/errors)
- `examples/decoder_semantics.zig`