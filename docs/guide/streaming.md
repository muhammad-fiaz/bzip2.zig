# Streaming

Every entry point that moves bytes between the codec and a caller works through
`std.Io.Reader` and `std.Io.Writer`. Nothing in the library opens a file, reads
a socket or writes to a global handle, which is what makes the streaming API
usable with any source.

## The shape

The encoder buffers one block, emits it when it fills, and repeats. The decoder
reads one block, decodes it, writes it out, and repeats. Neither keeps more than
one block, so the memory cost of a stream is independent of its length.

```text
reader -> [ one block ] -> writer
```

The buffers on either side are the caller's, and their sizes are the caller's
choice.

## Compressor

```zig
var compressor = try bzip2.Compressor.init(gpa, .{ .level = 9 });
defer compressor.deinit();

try compressor.write(writer, first_chunk);
try compressor.write(writer, second_chunk);
try compressor.finish(writer);
```

`write` accepts any slice length, including an empty one. Chunk boundaries do
not have to line up with block boundaries; the encoder decides where blocks
split. Writing the same input in different chunk sizes produces identical
output.

The slice is borrowed for the duration of the call and not retained, so it is
safe to reuse or free the source immediately afterwards.

`finish` writes the end marker and the combined CRC. It has to be called. A
stream that is written to but never finished is not a valid stream.

`reset` returns the encoder to its initial state while keeping its buffers, so
the next stream allocates nothing.

## Compressor or CompressStream

For a whole reader, `compressStream` is the same thing without the loop:

```zig
try bzip2.compressStream(gpa, reader, writer, .{ .level = 9 });
```

Internally it pulls from the reader and pushes into the compressor in whatever
sizes the source delivers. It creates and destroys a compressor for the
duration of the call. If you need several streams through the same encoder,
use `Compressor` directly so the buffers are reused.

## Decompressor

```zig
var scratch = try bzip2.Scratch.init(gpa);
defer scratch.deinit();

var decoder: bzip2.Decompressor = .init(.{});
try decoder.stream(reader, writer, &scratch);
```

`Decoder` is the same thing with the scratch owned for you:

```zig
var decoder = try bzip2.Decoder.init(gpa, .{});
defer decoder.deinit();
try decoder.stream(reader, writer);
```

The two exist because the ownership fits different situations. A single
decompression needs one object and the shorter form is better. A process that
decodes many archives wants the scratch to persist, and `Scratch` makes that
explicit rather than implicit.

Scratch grows to the largest block size it has seen and stays there, so a
series of similar-sized streams does no further allocation.

After a stream completes, `decoder.decompressor.stats` reports how many blocks
were decoded and how many bytes were produced:

```zig
try decoder.stream(reader, writer);
const stats = decoder.decompressor.stats;
// stats.blocks, stats.output_bytes
```

## Whole files

The file helpers apply the same property to paths:

```zig
try bzip2.compressFile(gpa, io, "input.txt", "input.txt.bz2", .{ .level = 9 });
try bzip2.decompressFile(gpa, io, "input.txt.bz2", "restored.txt", .{});
```

They take a `std.Io` interface, which is what `std.Io.Dir` and `std.Io.File`
expect in Zig 0.17. They use 64 kB read and write buffers and one block of
codec scratch. Neither loads the file into memory.

If compression fails, the destination is left in whatever state it had reached.
The source is untouched in every case.

## Sending output somewhere other than memory

Because the output goes to a `std.Io.Writer`, it does not have to be stored.
Hashing it, piping it, or discarding it are all the same call:

```zig
var discarding: std.Io.Writer.Discarding = .init(&buffer);
var hashed = std.Io.Writer.hashed(&discarding.writer, std.hash.XxHash3.init(0), &buffer);
try bzip2.decompressStream(gpa, reader, &hashed.writer, .{});
try hashed.writer.flush();
try discarding.writer.flush();
```

Flush each layer in turn. Flushing the outer writer only pushes data into the
inner one, and whatever the inner one buffered stays there.

## Budgets on a stream

`DecompressionOptions` applies to streaming decompression the same way it does
to the one-shot call:

```zig
try bzip2.decompressStream(gpa, reader, writer, .{
    .max_output_size = 512 * 1024 * 1024,
    .verify_crc = true,
});
```

This matters most in streaming use, where the destination might be a file or a
network connection that should not grow without bound.

## Examples

- `examples/streaming_pipelines.zig` binds a source reader to a sink writer
  through `compressStream` and `decompressStream`
- `examples/decoder_semantics.zig` hashes the output and reuses a decoder
  across streams
- `examples/file_compression.zig` covers the whole-file helpers end to end
- `examples/large_file.zig` processes 16 MiB in fixed memory and verifies the
  result by hashing both files