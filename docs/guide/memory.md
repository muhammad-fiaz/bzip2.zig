---
title: Memory and Allocators
description: "How bzip2.zig allocates: caller-supplied allocators, bounded per-call scratch memory, and no global state anywhere."
keywords: zig allocator, memory usage, scratch buffer, arena allocator, no global state
---

# Memory and Allocators

The library never allocates from a global. Every entry point that needs memory
takes a `std.mem.Allocator`, and every entry point that needs I/O takes a
`std.Io.Reader`, a `std.Io.Writer` or a `std.Io` interface. Nothing is cached
between calls, and nothing reaches for a global file handle.

That makes memory behaviour a property the program chooses rather than one it
discovers.

## Ownership

```zig
const compressed = try bzip2.compress(gpa, data, .{});
defer gpa.free(compressed);

const restored = try bzip2.decompress(gpa, compressed, .{});
defer gpa.free(restored);
```

Both slices are allocated with `gpa` and freed with `gpa`. Free them with the
same allocator they came from.

## Choosing an allocator

### General purpose

```zig
const gpa = init.gpa;
```

Fine for most programs. Each call allocates and frees its own buffers.

### Arena, for one-shot work

```zig
var arena_state = std.heap.ArenaAllocator.init(gpa);
const arena = arena_state.allocator();

const compressed = try bzip2.compress(arena, data);
const restored = try bzip2.decompress(arena, compressed);
// one free at the end releases the compressed buffer, the restored buffer and
// every scratch block along the way
_ = arena_state.deinit();
```

Convenient when the buffers have similar lifetimes, since individual frees
become unnecessary. An arena is a poor fit for a long-running process, because
nothing is ever returned until the arena is dropped.

### Fixed buffer, for a known budget

```zig
var storage: [4 << 20]u8 = undefined;
var fixed = std.heap.FixedBufferAllocator.init(&storage);

const compressed = try bzip2.compress(fixed.allocator(), data);
```

Every allocation the library makes comes out of `storage`, so the total is
bounded and a program with no general purpose heap still works. Running out
produces `error.OutOfMemory` rather than growing without limit.

The buffer has to cover the codec scratch for one block plus the result. The
encoder needs the most: level 1 with 4 MiB is comfortable, and higher levels
need proportionally more. `fixed.end_index` reports how much was used.

### Caller-owned buffers

When a caller already has a destination buffer, `Compressor` writes into any
`std.Io.Writer`, including one backed by memory the caller owns:

```zig
var storage: [8192]u8 = undefined;
var writer = std.Io.Writer.fixed(&storage);
try compressor.write(&writer, data);
```

`fixed` fails rather than growing, so check `writer.writeAll` results for
`error.WriteFailed` when the output might not fit.

## What the codec allocates

The encoder holds, for one block of `block_size` bytes:

| Buffer | Size |
| --- | --- |
| RLE1 output | `block_size` plus a small overrun margin |
| MTF symbol stream | `block_size + 1` entries of two bytes |
| Last column | `block_size` |
| Rotation indices | `block_size` entries of four bytes, plus a second index buffer |
| Huffman and table working state | bounded, independent of block size |

The decoder holds the last column, a first-column mapping and the reconstructed
block, all sized from the block size the header declares, plus a fixed 64 kB
output window.

At level 9 a 900 kB block needs a few megabytes of scratch regardless of how
much data passes through. At level 1 it needs proportionally less.

## Reuse across calls

### Scratch on the decode side

`Decoder` allocates its scratch on construction and keeps it. Reusing one
decoder across many streams is the whole reason it is a struct rather than a
function:

```zig
var decoder = try bzip2.Decoder.init(gpa, .{});
defer decoder.deinit();

while (next_archive()) |stream| {
    try decoder.stream(stream.reader, stream.writer);
}
```

For finer control, use `Decompressor` with a `Scratch` you own. The scratch
grows to the largest block size it has seen and stays there, so the first stream
may allocate and the rest do not:

```zig
var scratch = try bzip2.Scratch.init(gpa);
defer scratch.deinit();

var decoder: bzip2.Decompressor = .init(.{});
try decoder.stream(reader, writer, &scratch);
```

`Scratch` is safe to share only between decoders used one at a time. It is not
synchronised; concurrent decoding needs one scratch per thread.

### Reset on the encode side

```zig
for (inputs) |data| {
    compressor.reset();
    try compressor.write(writer, data);
    try compressor.finish(writer);
}
```

`reset` clears the stream state and keeps the buffers.

## Memory use is bounded by the block, not the input

Nothing in the streaming or whole-file paths scales with the length of the data.
A 4 GB file and a 4 kB file cost the same encoder scratch. The
`large_file` example processes 16 MiB and reports its working set.

The one thing that does scale is the result of `compress` and `decompress`,
because those return the whole thing in one slice. Use the streaming entry
points when that matters.

## Output budgets

Independent of the allocator, `max_output_size` bounds how much a stream may
produce:

```zig
const restored = try bzip2.decompress(gpa, untrusted, .{
    .max_output_size = 64 * 1024 * 1024,
});
```

This is the limit that matters for untrusted input. It caps the result before a
single byte is written, so a small stream that claims a large expansion fails
with `error.OutputTooLarge` rather than succeeding and filling memory.

## Allocation failures

Every allocation path returns `error.OutOfMemory`. The library holds no state
between calls that a failure could leave inconsistent: a `Compressor` or
`Decoder` whose `deinit` runs after a failed operation releases everything it
acquired, and the objects are not usable afterwards, since the operation that
failed leaves them mid-stream.

A `Compressor` that fails partway through writing a block can be reset and
reused. A `Decoder` that fails mid-stream cannot, because the input position has
moved on and the stream is no longer parseable from where it stopped.