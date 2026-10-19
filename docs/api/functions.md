---
title: Compress and Decompress
description: One-shot compress and decompress functions, whole-file helpers, worst-case size bounds, and stream introspection in bzip2.zig.
keywords: zig compress function, zig decompress, maxCompressedSize, blockSizeOfStream, file helpers
---

# Compress and Decompress

## compress

```zig
pub fn compress(
    gpa: std.mem.Allocator,
    input: []const u8,
    options: CompressionOptions,
) StreamError![]u8
```

Compresses `input` into a newly allocated stream.

`options.level` must be between 1 and 9; anything else returns
`error.InvalidCompressionLevel`. The returned slice is allocated with `gpa` and
must be freed with the same allocator.

```zig
const compressed = try bzip2.compress(gpa, data, .{ .level = 6 });
defer gpa.free(compressed);
```

Omitting `options` uses the defaults, which is level 9:

```zig
const compressed = try bzip2.compress(gpa, data, .{});
```

The input slice is borrowed for the duration of the call.

## decompress

```zig
pub fn decompress(
    gpa: std.mem.Allocator,
    input: []const u8,
    options: DecompressionOptions,
) StreamError![]u8
```

Decompresses a complete stream into a newly allocated slice.

Every structural field is validated before use, and the block and stream CRCs
are verified before the result is returned. Either the result matches the
original data exactly, or the call returns an error.

```zig
const restored = try bzip2.decompress(gpa, compressed, .{});
defer gpa.free(restored);
```

For input of unknown origin, bound the output:

```zig
const restored = try bzip2.decompress(gpa, downloaded, .{
    .max_output_size = 64 * 1024 * 1024,
});
```

## compressStream

```zig
pub fn compressStream(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: CompressionOptions,
) StreamError!void
```

Reads `reader` to exhaustion and writes a complete stream to `writer`.

Input is consumed incrementally and memory use is bounded by one block, so the
footprint does not grow with the size of the stream:

```zig
var read_buffer: [64 * 1024]u8 = undefined;
var write_buffer: [64 * 1024]u8 = undefined;

var source = try dir.openFile(io, "input.txt", .{});
defer source.close(io);
var archive = try dir.createFile(io, "input.txt.bz2", .{});
defer archive.close(io);

var reader = source.readerStreaming(io, &read_buffer);
var writer = archive.writerStreaming(io, &write_buffer);
try bzip2.compressStream(gpa, &reader.interface, &writer.interface, .{
    .level = 9,
});
try writer.interface.flush();
```

The function creates and destroys a `Compressor` for the duration of the call.
Use `Compressor` directly when several streams should share its buffers.

## decompressStream

```zig
pub fn decompressStream(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: DecompressionOptions,
) StreamError!void
```

Reads a stream from `reader` and writes the decompressed bytes to `writer` one
block at a time.

Output is produced incrementally, so the whole result never has to be resident:

```zig
var source = try dir.openFile(io, "input.txt.bz2", .{});
defer source.close(io);
var restored = try dir.createFile(io, "restored.txt", .{});
defer restored.close(io);

var reader = source.readerStreaming(io, &read_buffer);
var writer = restored.writerStreaming(io, &write_buffer);
try bzip2.decompressStream(gpa, &reader.interface, &writer.interface, .{});
try writer.interface.flush();
```

The allocator is needed for the decoder's scratch, not for the output.

## compressFile

```zig
pub fn compressFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    src_path: []const u8,
    dst_path: []const u8,
    options: CompressionOptions,
) FileStreamError!void
```

Compresses `src_path` into `dst_path`, replacing any existing file.

```zig
try bzip2.compressFile(gpa, io, "input.txt", "input.txt.bz2", .{ .level = 9 });
```

`io` is the Zig 0.17 I/O interface that `std.Io.Dir` and `std.Io.File` expect.
The file is read through 64 kB buffers and one block of codec scratch, so a
multi-gigabyte input costs the same as a small one.

Output goes to a staging file beside the destination and is moved into place
only after compression completes. A failure therefore leaves any existing
destination untouched and leaves no partial archive behind, so a reader can never
mistake half a file for a whole one. The source is never modified.

`src_path` and `dst_path` must differ. Compressing a file onto itself would
destroy the input, so it is refused with `error.SamePathAsSourceAndDestination`
before anything is opened.

## decompressFile

```zig
pub fn decompressFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    src_path: []const u8,
    dst_path: []const u8,
    options: DecompressionOptions,
) FileStreamError!void
```

Decompresses `src_path` into `dst_path`, replacing any existing file.

```zig
try bzip2.decompressFile(gpa, io, "input.txt.bz2", "restored.txt", .{});
```

Verification is on by default, so reaching the end means the data was intact.

Like `compressFile`, the output is staged and published on success, so a stream
that fails part way through leaves no partial plaintext where the caller expects
either the old contents or nothing at all. Identical paths are refused.

## blockSizeOfStream

```zig
pub fn blockSizeOfStream(data: []const u8) Error!usize
```

Reads the block size in bytes from a stream header without decoding anything.
This is the level multiplied by 100 kB.

```zig
const block_size = try bzip2.blockSizeOfStream(compressed);
// level 9 -> 900_000
```

Returns `error.InvalidStreamHeader` for anything that is not a well formed
`BZh<1..9>` prefix, so it is safe to call on data of unknown origin. It needs
four bytes and nothing else.

## maxCompressedSize

```zig
pub fn maxCompressedSize(input_size: usize, level: u8) Error!usize
```

An upper bound on the compressed size of `input_size` bytes at `level`.

```zig
const capacity = try bzip2.maxCompressedSize(data.len, 9);
```

The bound accounts for the 5/4 expansion the run-length stage can cause, plus
per-block framing and table overhead. It is meant for sizing an allocation
before compressing into it, not for predicting the result; real output is
usually well below it.

Returns `error.InvalidCompressionLevel` for a level outside 1 through 9.

## Errors

All six functions return `StreamError` or `FileStreamError`, which are unions
of the codec error set with the relevant I/O error sets. See
[Errors](/api/errors).