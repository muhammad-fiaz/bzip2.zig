# File Compression

Compresses a file, decompresses it back, and shows what the failure path does
to the destination.

```bash
zig build run-file_compression
```

Source: [`examples/file_compression.zig`](https://github.com/muhammad-fiaz/bzip2.zig/blob/main/examples/file_compression.zig)

## The call

```zig
try bzip2.compressFile(gpa, io, source, archive, .{ .level = 9 });
try bzip2.decompressFile(gpa, io, archive, restored, .{ .max_output_size = 1 << 30 });
```

`io` is the Zig 0.17 I/O interface that `std.Io.Dir` and `std.Io.File` expect.
The example puts every file it touches in a temporary directory it creates and
removes again.

## Output

```text
735668 -> 56491 bytes (13.02x), staged and published atomically
decompress verified by hash
truncated stream rejected as expected: UnexpectedEndOfStream
failure path verified: destination preserved, staging cleaned
```

## What to notice

The file helpers use 64 kB read and write buffers and one block of codec
scratch. Neither loads the file into memory, which is what makes a
multi-gigabyte input cost the same as a small one.

Reaching the end of `decompressFile` already means the data was intact,
because verification is on by default. The example verifies by hashing both
files rather than by holding them in memory, which is the same conclusion
without the second copy.

## Staged publication

Output goes to a staging file beside the destination and is moved into place
only after compression or decompression completes. A failure therefore leaves
any existing destination untouched and leaves no partial archive behind, so a
reader can never mistake half a file for a whole one.

The example proves the failure path: it writes a stale placeholder under the
destination name, asks for a truncated stream, and prints
`destination preserved, staging cleaned`.

## The truncated stream

```zig
const bytes = try dir.readFileAlloc(io, archive, gpa, .limited(1 << 20));
try dir.writeFile(io, .{ .sub_path = short_path, .data = bytes[0 .. bytes.len / 2] });

const failed = bzip2.decompressFile(gpa, io, short_path, damaged, .{});
```

The stream CRC is the last 32 bits of the stream. Cut the archive in half and
the call fails rather than quietly echoing partial data, and the file the
example wrote under `damaged` — a sentinel string — is still intact afterwards:

```text
truncated stream rejected as expected: UnexpectedEndOfStream
failure path verified: destination preserved, staging cleaned
```

## Both sides of the filesystem

In Zig 0.17 a `std.Io.File` has no `readAll` or `writeAll` of its own. Wrap
it with a streaming accessor:

```zig
var buffer: [4096]u8 = undefined;
var writer = file.writerStreaming(io, &buffer);
try writer.interface.print("line {d}: ...\n", .{line});
try writer.interface.flush();
var reader = file.readerStreaming(io, &buffer);
// reader.interface.fillMore(), reader.interface.buffered(), toss(len)
```

`readerStreaming` and `writerStreaming` own a fixed buffer that is handed in,
and so long as the wraps scope out the code works the same for a hashing
sink. Keep the scratch buffer separate from whatever you are writing,
because `writeAll` copies into the writer's buffer and the two aliasing
produces a panic.

## Related

- [Streaming](/guide/streaming)
- [Errors](/api/errors)
- `large_file.zig` processes 16 MiB and verifies the result by hashing
