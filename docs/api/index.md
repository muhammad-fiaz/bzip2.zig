# API Reference

The module exposes one-shot functions, streaming types, whole-file helpers, and
two introspection helpers. Everything that allocates takes the allocator as its
first argument; everything that performs I/O takes a `std.Io.Reader`,
a `std.Io.Writer` or a `std.Io` interface.

## One-shot functions

| Function | Signature |
| --- | --- |
| `compress` | `(gpa, input, CompressionOptions) StreamError![]u8` |
| `decompress` | `(gpa, input, DecompressionOptions) StreamError![]u8` |
| `compressStream` | `(gpa, reader, writer, CompressionOptions) StreamError!void` |
| `decompressStream` | `(gpa, reader, writer, DecompressionOptions) StreamError!void` |
| `compressFile` | `(gpa, io, src_path, dst_path, CompressionOptions) FileStreamError!void` |
| `decompressFile` | `(gpa, io, src_path, dst_path, DecompressionOptions) FileStreamError!void` |

`compress` and `decompress` return memory the caller owns. The others write to a
writer or a path and allocate only their internal scratch.

See [Compress and Decompress](/api/functions).

## Streaming types

| Type | Purpose |
| --- | --- |
| `Compressor` | Incremental encoder. `init`, `write`, `finish`, `reset`, `deinit`. |
| `Decompressor` | Incremental decoder with caller-owned scratch. `init`, `stream`, `deinit`. |
| `Decoder` | Incremental decoder that owns its scratch. `init`, `stream`, `reset`, `deinit`. |
| `Scratch` | Reusable decoder buffers. `init`, `ensure`, `deinit`. |
| `Stats` | Blocks decoded and bytes produced. |

See [Compressor](/api/compressor) and [Decompressor](/api/decompressor).

## Options

| Type | Field | Default |
| --- | --- | --- |
| `CompressionOptions` | `level: u8` (1..9) | `9` |
| `DecompressionOptions` | `max_output_size: ?usize` | `null` |
| `DecompressionOptions` | `verify_crc: bool` | `true` |

See [Options](/api/compress-options).

## Introspection

| Function | Purpose |
| --- | --- |
| `blockSizeOfStream` | Read the declared block size from a header |
| `maxCompressedSize` | Upper bound on the compressed size of an input |
| `version` | Major, minor and patch numbers |
| `version_string` | `"0.0.1"` |
| `version_major` | `0` |

See [Constants](/api/constants).

## Errors

| Alias | Covers |
| --- | --- |
| `Error` | Everything describing the codec and its input |
| `IoError` | `std.Io.Writer.Error` and `std.Io.Reader.Error` |
| `StreamError` | `Error` plus `IoError` |
| `FileError` | `std.Io.File.OpenError`, `std.Io.Dir.RenameError`, and the same-path guard |
| `FileStreamError` | `StreamError` plus `FileError` |

See [Errors](/api/errors).

## Version and limits

```zig
const bzip2 = @import("bzip2");

const version = bzip2.version();          // .{ .major = 0, .minor = 0, .patch = 1 }
const largest_block = bzip2.max_block_size;  // 900_000
```

`version_major` lets a caller gate on a feature without depending on the patch
number.

## Conventions

- Option fields are named in lower case, following Zig practice.
- Errors that describe bad input are distinguishable from each other and from
  `error.OutOfMemory`.
- Slices passed in are borrowed for the duration of the call and are not
  retained.
- Slices returned are owned by the caller.
- Nothing is cached between calls unless a streaming type is reused
  explicitly.