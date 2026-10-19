---
title: Examples
description: Ten runnable programs covering one-shot calls, streaming pipelines, file handling, and decoder behaviour — each compiled and run by the build.
keywords: bzip2 examples, zig example programs, demo, runnable
---

# Examples

Ten runnable programs live in the `examples` directory of the repository.
Each is a complete Zig program with a `main` function, and each is compiled by
`zig build check`.

```bash
zig build run-basic_compression
```

Run every one:

```bash
zig build run-all-examples
```

## The programs

Each example covers one thing. None repeats another's demonstration.

| Example | What it covers |
| --- | --- |
| [basic_compression](/examples/basic_compression) | One-shot round trip with verification and header introspection |
| [compression_levels](https://github.com/muhammad-fiaz/bzip2.zig/blob/main/examples/compression_levels.zig) | All nine levels side by side with ratios and timings |
| [reusable_contexts](https://github.com/muhammad-fiaz/bzip2.zig/blob/main/examples/reusable_contexts.zig) | One `Compressor` and one `Decoder`, many streams |
| [caller_buffers](https://github.com/muhammad-fiaz/bzip2.zig/blob/main/examples/caller_buffers.zig) | Caller-provided output buffers, sizing and retry on overflow |
| [chunked_input](https://github.com/muhammad-fiaz/bzip2.zig/blob/main/examples/chunked_input.zig) | Irregular write sizes producing a byte-identical stream |
| [streaming_pipelines](/examples/streaming_pipelines) | `compressStream` and `decompressStream` as bounded pipelines |
| [file_compression](/examples/file_compression) | File to file with staging, plus the damaged-stream failure path |
| [large_file](https://github.com/muhammad-fiaz/bzip2.zig/blob/main/examples/large_file.zig) | A 16 MiB round trip in constant memory, hash-verified |
| [decoder_semantics](/examples/decoder_semantics) | Statistics, CRC verification, corruption taxonomy, concatenation |
| [custom_allocator](https://github.com/muhammad-fiaz/bzip2.zig/blob/main/examples/custom_allocator.zig) | A counting custom allocator proving the byte balance |

Run one by prefixing its name with `run-`:

```bash
zig build run-compression_levels
zig build run-large_file
```

The examples that write files put them in a directory under the system
temporary area they create themselves and remove again at the end, so a run
leaves the working directory as it found it.

## Output

The examples write to standard error through `std.debug.print`, which keeps them
usable in a pipeline where standard output might be redirected.

## Source layout

Tests live at the bottom of the module they cover, so a behaviour described in
the documentation can be read next to the code that implements it and the tests
that pin it down. The examples are the executable half of the same idea: each
one is short enough to read in full and produces output you can check against
the claim in its name.
