---
title: Compressor
description: "The reusable Compressor type: incremental BZip2 encoding into any std.Io.Writer with an allocator you choose."
keywords: zig compressor, incremental compression, std.Io.Writer, streaming encoder, reusable context
---

# Compressor

```zig
pub const Compressor = struct {
    pub fn init(gpa: std.mem.Allocator, options: CompressionOptions) Allocator.Error!Compressor;
    pub fn deinit(self: *Compressor) void;
    pub fn write(self: *Compressor, writer: *std.Io.Writer, bytes: []const u8) StreamError!void;
    pub fn finish(self: *Compressor, writer: *std.Io.Writer) StreamError!void;
    pub fn reset(self: *Compressor) void;

    pub block_count: u64;
};
```

The incremental encoder. Use it when the input arrives in pieces, or when
several streams should share the same buffers.

## Creating one

```zig
var compressor = try bzip2.Compressor.init(gpa, .{ .level = 9 });
defer compressor.deinit();
```

`init` allocates the block buffers, which is the only allocation it performs.
Omitting the level uses 9:

```zig
var compressor = try bzip2.Compressor.init(gpa, .{});
```

An out-of-range level is refused before any allocation happens:

```zig
try std.testing.expectError(
    error.InvalidCompressionLevel,
    bzip2.Compressor.init(gpa, .{ .level = 10 }),
);
```

## Writing

```zig
try compressor.write(writer, first);
try compressor.write(writer, second);
```

`write` accepts any slice length, including an empty one. The slice is borrowed
for the duration of the call and is not retained afterwards, so it is safe to
reuse or free the source as soon as the call returns.

Chunk boundaries do not have to line up with block boundaries. The encoder
buffers input until a block fills and emits it then, so writing one large slice
and writing the same bytes in awkward pieces produce identical output.

Output goes to any `std.Io.Writer`. Nothing is written until a block is ready,
and each block is written before the next one is started, which keeps memory
flat.

## Finishing

```zig
try compressor.finish(writer);
```

`finish` flushes any partial block, writes the end-of-stream marker, and writes
the combined CRC.

It has to be called. A compressor that has been written to but not finished has
produced an incomplete stream, and the CRC that would detect truncation is part
of what `finish` writes.

`finish` leaves anything the writer had buffered untouched. Flush the writer
yourself if that matters:

```zig
try compressor.finish(&writing.interface);
try writing.interface.flush();
```

## Resetting

```zig
compressor.reset();
try compressor.write(writer, new_input);
try compressor.finish(writer);
```

`reset` returns the encoder to its initial state while keeping the buffers it
has already allocated, so the next stream does no further allocation.

Without a `reset`, a second `write` continues the stream in progress rather than
starting a new one. That is what makes a sequence of streams through one
compressor possible.

## Reading the block count

```zig
if (compressor.block_count > 1) {
    // A multi-block stream.
}
```

Useful for confirming that a level choice produced the block structure
expected. Level 1 caps blocks at 100 kB of coded data, so incompressible input
at that level produces many blocks.

## Writing into caller-owned memory

`write` takes a writer, so a caller-supplied buffer works:

```zig
var storage: [64 * 1024]u8 = undefined;
var writer = std.Io.Writer.fixed(&storage);
try compressor.write(&writer, data);
try compressor.finish(&writer);
```

`fixed` fails rather than growing, so handle `error.WriteFailed` when the
output might not fit.

## Failure

A `write` that fails leaves the compressor mid-stream. It can be reset and
reused. A `finish` that fails may have left a partial block and its trailer on
the writer, so the destination has to be discarded; reset the compressor before
using it again.

## See also

- [Streaming](/guide/streaming)
- [Options](/api/compress-options)
- `examples/streaming_pipelines.zig`