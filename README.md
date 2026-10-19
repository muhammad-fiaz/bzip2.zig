<div align="center">
<h1 align="center">bzip2.zig</h1>


<a href="https://muhammad-fiaz.github.io/bzip2.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.17.0-orange.svg?logo=zig" alt="Zig Version"></a>
<a href="https://github.com/muhammad-fiaz/bzip2.zig"><img src="https://img.shields.io/github/stars/muhammad-fiaz/bzip2.zig" alt="GitHub stars"></a>
<a href="https://github.com/muhammad-fiaz/bzip2.zig/issues"><img src="https://img.shields.io/github/issues/muhammad-fiaz/bzip2.zig" alt="GitHub issues"></a>
<a href="https://github.com/muhammad-fiaz/bzip2.zig/pulls"><img src="https://img.shields.io/github/issues-pr/muhammad-fiaz/bzip2.zig" alt="GitHub pull requests"></a>
<a href="https://github.com/muhammad-fiaz/bzip2.zig"><img src="https://img.shields.io/github/last-commit/muhammad-fiaz/bzip2.zig" alt="GitHub last commit"></a>
<a href="https://github.com/muhammad-fiaz/bzip2.zig"><img src="https://img.shields.io/github/license/muhammad-fiaz/bzip2.zig" alt="License"></a>
<a href="https://github.com/muhammad-fiaz/bzip2.zig/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/muhammad-fiaz/bzip2.zig/ci.yml?label=CI" alt="CI"></a>
<img src="https://img.shields.io/badge/platforms-linux%20%7C%20windows%20%7C%20macos-blue" alt="Supported Platforms">
<a href="https://github.com/muhammad-fiaz/bzip2.zig/releases/latest"><img src="https://img.shields.io/github/v/release/muhammad-fiaz/bzip2.zig?label=Latest%20Release&style=flat-square" alt="Latest Release"></a>
<a href="https://pay.muhammadfiaz.com"><img src="https://img.shields.io/badge/Sponsor-pay.muhammadfiaz.com-ff69b4?style=flat&logo=heart" alt="Sponsor"></a>
<a href="https://github.com/sponsors/muhammad-fiaz"><img src="https://img.shields.io/badge/Sponsor-GitHub-pink?style=social&logo=github" alt="GitHub Sponsors"></a>
<a href="https://hits.sh/github.com/muhammad-fiaz/bzip2.zig/"><img alt="Hits" src="https://hits.sh/github.com/muhammad-fiaz/bzip2.zig.svg"></a>

<p><em>A native BZip2 compression and decompression library for Zig.</em></p>

<b><a href="https://muhammad-fiaz.github.io/bzip2.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/bzip2.zig/api/">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/bzip2.zig/guide/getting-started">Quick Start</a> |
<a href="CONTRIBUTING.md">Contributing</a></b>

</div>

`bzip2.zig` is a complete implementation of the BZip2 format for Zig. It reads and
writes ordinary `.bz2` files, has no dependencies, links no C library, and never
reaches for a global allocator or a global file handle. Every entry point takes
the allocator and the I/O it needs from the caller.

> [!TIP]
> If you build with bzip2.zig, make sure to give it a star.

> [!NOTE]
> **Native implementation:** BZip2 is implemented from the format specification in
> Zig. There is no `@cImport`, no `link_libc`, no subprocess, and no vendored C.
> The encoder reproduces the sizes other implementations produce at the same
> level, and the decoder accepts their streams.
>
> **Built on the Zig 0.17 I/O interfaces:** Compression and decompression move
> bytes through `std.Io.Reader` and `std.Io.Writer`, and the whole-file helpers
> take a `std.Io`. That is what lets the same code drive a file, a socket, an
> in-memory buffer, or a hashing sink.

---

**Related Zig projects:**

- For **HTTP client and server** support, check out **[httpx.zig](https://github.com/muhammad-fiaz/httpx.zig)**.
- For **archive formats** support, check out **[archive.zig](https://github.com/muhammad-fiaz/archive.zig)**.
- For **Brotli compression** support, check out **[brotli.zig](https://github.com/muhammad-fiaz/brotli.zig)**.
- For **Zstd compression** support, check out **[zstd.zig](https://github.com/muhammad-fiaz/zstd.zig)**.
- For **Env vars (.env parsing)** support, check out **[env.zig](https://github.com/muhammad-fiaz/env.zig)**.
- For **UUID** support, check out **[uuid.zig](https://github.com/muhammad-fiaz/uuid.zig)**.
- For **Logging** support, check out **[logly.zig](https://github.com/muhammad-fiaz/logly.zig)**.
- For **SQLite** support, check out **[sqlite.zig](https://github.com/muhammad-fiaz/sqlite.zig)**.
- For **Simplified build.zig config** support, check out **[buildx.zig](https://github.com/muhammad-fiaz/buildx.zig)**.
- For **TUI** support, check out **[tui.zig](https://github.com/muhammad-fiaz/tui.zig)**.
- For **MCP** support, check out **[mcp.zig](https://github.com/muhammad-fiaz/mcp.zig)**.

---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description |
|---------|-------------|
| **Complete format coverage** | Levels 1 through 9, multi-block streams, the full 256-symbol map, multiple Huffman tables per block with selector optimisation, RUNA/RUNB zero runs, and the legacy randomised block flag. |
| **Compatible output** | Compressed sizes match other implementations at the same level, and streams decode in both directions. The format does not fix the exact bit sequence, only the decoded result. |
| **Streaming** | `Compressor` and `Decompressor` work with any `std.Io.Reader` / `std.Io.Writer`. Chunk boundaries need not align with block boundaries; the encoder decides where blocks split. |
| **Bounded memory** | One block at a time. Streaming and whole-file entry points have the same footprint for a kilobyte and for a terabyte. |
| **Whole-file helpers** | `compressFile` and `decompressFile` take paths and a `std.Io`, and never load the file into memory. |
| **Explicit allocators and I/O** | No global allocator, no global file handle, no hidden state. Arenas, fixed buffers and caller-supplied scratch all work because nothing is cached implicitly. |
| **Reusable context** | `Compressor.reset` and a caller-owned `Scratch` let many streams run through the same buffers with no reallocation. |
| **Integrity checking** | Every block carries a CRC and the stream carries a combined one. Both are verified before a result is returned. |
| **Specific errors** | Each way a stream can be malformed has its own error, so a caller can tell a corrupt archive from a truncated one from something that was never a BZip2 stream. |
| **Decompression limits** | `max_output_size` turns a small stream with a large claimed expansion into `error.OutputTooLarge` before anything is allocated. |
| **Legacy randomised blocks** | The derandomisation table is implemented on both sides, so streams produced by older encoders decode correctly. |
| **Zero dependencies** | No packages, no build-time code generation, no libc. Builds for 64- and 32-bit targets alike. |

</details>

---

<details>
<summary><strong>Prerequisites and Supported Platforms</strong> (click to expand)</summary>

<br>

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Zig** | **0.17.0** (required) | Download from [ziglang.org](https://ziglang.org/download/) |
| **Operating System** | Windows 10+, Linux, macOS | Cross-platform |
| **libc** | not required | `link_libc` is false |

> [!IMPORTANT]
> **Zig 0.17.0 is required.** The library uses the `std.Io` interfaces introduced
> in that release. Older toolchains will not compile it, and `build.zig.zon`
> declares `0.17.0` as its minimum.

---

## Supported Platforms

| Platform | x86_64 (64-bit) | aarch64 (ARM64) | x86 (32-bit) |
|----------|-----------------|-----------------|--------------|
| **Linux** | Yes | Yes | Yes |
| **Windows** | Yes | Yes | Yes |
| **macOS** | Yes | Yes (Apple Silicon) | No |

### Cross-Compilation

```bash
# Build for Linux ARM64 from Windows
zig build -Dtarget=aarch64-linux

# Build for Windows from Linux
zig build -Dtarget=x86_64-linux-gnu

# Build for macOS Apple Silicon from Linux
zig build -Dtarget=aarch64-macos

# Build for 32-bit Windows
zig build -Dtarget=x86-windows
```

</details>

---

## Installation

### Method 1: Zig Fetch (Stable Release, Recommended)

```bash
zig fetch --save https://github.com/muhammad-fiaz/bzip2.zig/archive/refs/tags/0.0.1.tar.gz
```

### Method 2: Zig Fetch (Nightly, Latest Development Build)

Use this to follow the main branch:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/bzip2.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

```zig
.dependencies = .{
    .bzip2 = .{
        .url = "https://github.com/muhammad-fiaz/bzip2.zig/archive/refs/tags/0.0.1.tar.gz",
        .hash = "...", // Run `zig fetch --save <url>` to generate the hash.
    },
},
```

### Method 4: Local Source Checkout

```bash
git clone https://github.com/muhammad-fiaz/bzip2.zig.git
cd bzip2.zig
zig build
```

To use a local checkout from another project:

```zig
.dependencies = .{
    .bzip2 = .{
        .path = "../bzip2.zig",
    },
},
```

### Wire into `build.zig`

```zig
const bzip2_dep = b.dependency("bzip2", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("bzip2", bzip2_dep.module("bzip2"));
```

> [!NOTE]
> If you encounter `file exists in modules 'X' and 'X0'`, try removing
> `.target = target` and `.optimize = optimize` from your dependency options in
> the root `build.zig` and use `.{}` instead. This can help prevent duplicate
> module instances when multiple dependencies resolve the same module. See
> [Zig issue #36694](https://codeberg.org/ziglang/zig/issues/36694).

## Quick Start

### Compress and decompress

```zig
const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const input = "The quick brown fox jumps over the lazy dog. ";
    var text: [input.len * 20]u8 = undefined;
    for (&text, 0..) |*byte, i| byte.* = input[i % input.len];

    const compressed = try bzip2.compress(gpa, &text, .{ .level = 9 });
    defer gpa.free(compressed);

    const restored = try bzip2.decompress(gpa, compressed, .{});
    defer gpa.free(restored);

    std.debug.print("{d} bytes became {d} bytes\n", .{ text.len, compressed.len });
}
```

Both slices belong to the caller and are allocated with the allocator that was
passed in. `decompress` verifies the block and stream CRCs as it goes, so the
result is either exactly `text` or the call returns an error.

### Levels

The level is the block size in units of 100 kB, so level 1 uses 100 kB blocks
and level 9 uses 900 kB. The value is written into the stream header where the
format expects it, and any decoder reads it back.

```zig
const compressed = try bzip2.compress(gpa, data, .{ .level = 6 });
const block_size = try bzip2.blockSizeOfStream(compressed);
```

### Streaming

`Compressor` writes into any `std.Io.Writer` and `Decompressor` reads from any
`std.Io.Reader`. Neither holds more than one block, so a stream of any size runs
in a fixed amount of memory.

```zig
var compressor = try bzip2.Compressor.init(gpa, .{ .level = 9 });
defer compressor.deinit();

try compressor.write(writer, first_chunk);
try compressor.write(writer, second_chunk);
try compressor.finish(writer);
```

The slice passed to `write` is borrowed for the duration of the call only. Chunk
boundaries do not have to line up with block boundaries.

Two wrappers cover the case where a whole reader is the source:

```zig
try bzip2.compressStream(gpa, reader, writer, .{ .level = 9 });
try bzip2.decompressStream(gpa, reader, writer, .{});
```

### Whole files

```zig
try bzip2.compressFile(gpa, io, "input.txt", "input.txt.bz2", .{ .level = 9 });
try bzip2.decompressFile(gpa, io, "input.txt.bz2", "restored.txt", .{});
```

Both take a `std.Io` interface, which is what `std.Io.Dir` and `std.Io.File`
expect. Neither buffers the file: memory use is one block plus two 64 kB buffers,
regardless of file size.

### Handling damaged input

Every structural field is bounds checked before it is used, and the block and
stream CRCs are verified before the result is returned. A stream that has been
truncated or altered is refused with an error that says what was wrong.

```zig
const restored = bzip2.decompress(gpa, untrusted, .{}) catch |err| switch (err) {
    error.StreamCrcMismatch => return error.CorruptArchive,
    error.InvalidStreamHeader => return error.NotAnArchive,
    error.UnexpectedEndOfStream => return error.TruncatedArchive,
    else => return err,
};
defer gpa.free(restored);
```

For input from outside the process, set `max_output_size`. A few hundred bytes of
stream can expand into megabytes, and the limit turns that into a clean
`error.OutputTooLarge` rather than an allocation the sender chose the size of.

```zig
const restored = try bzip2.decompress(gpa, downloaded, .{
    .max_output_size = 64 * 1024 * 1024,
});
```

### Reusing a decoder

`Decoder` owns its scratch buffers. `Decompressor` plus `Scratch` is the same
thing with the ownership lifted out, which is what a long-lived decoder wants:
the scratch survives between streams, so decoding many archives in a row
reallocates nothing.

```zig
var scratch = try bzip2.Scratch.init(gpa);
defer scratch.deinit();

var decoder: bzip2.Decompressor = .init(.{ .verify_crc = true });
while (next_stream()) |stream| {
    try decoder.stream(stream.reader, stream.writer, &scratch);
}
```

### Allocators

The library never allocates from a global. Pass the allocator that suits the
program:

```zig
var arena_state = std.heap.ArenaAllocator.init(gpa);
const arena = arena_state.allocator();

const compressed = try bzip2.compress(arena, data, .{});
```

`std.heap.FixedBufferAllocator` also works, which is useful when the memory
budget has to be known in advance. Running out produces `error.OutOfMemory`
rather than growing without limit.

## API

| Function | Purpose |
| -------- | ------- |
| `compress` | Compress a slice into a new slice |
| `decompress` | Decompress a complete stream into a new slice |
| `compressStream` | Compress a reader into a writer |
| `decompressStream` | Decompress a reader into a writer |
| `compressFile` | Compress one file into another |
| `decompressFile` | Decompress one file into another |
| `blockSizeOfStream` | Read the declared block size from a header |
| `maxCompressedSize` | Upper bound on the compressed size of an input |

| Type | Purpose |
| ---- | ------- |
| `Compressor` | Incremental encoder. `init`, `write`, `finish`, `reset`, `deinit` |
| `Decompressor` | Incremental decoder with caller-owned scratch |
| `Decoder` | Incremental decoder that owns its scratch |
| `Scratch` | Reusable decoder buffers |
| `Stats` | Blocks decoded and bytes produced |

| Option | Field | Default | Meaning |
| ------ | ----- | ------- | ------- |
| `CompressionOptions` | `level` | `9` | Block size in units of 100 kB, 1 through 9 |
| `DecompressionOptions` | `max_output_size` | `null` | Refuse to produce more than this many bytes |
| `DecompressionOptions` | `verify_crc` | `true` | Check the per-block and stream CRCs |

Errors that describe the input are each distinguishable: `InvalidCompressionLevel`,
`InvalidStreamHeader`, `InvalidBlockMarker`, `InvalidEndOfStreamMarker`,
`InvalidSelectors`, `InvalidHuffmanTable`, `InvalidHuffmanCode`,
`InvalidSymbolMap`, `InvalidSequence`, `InvalidOrigPtr`, `RunLengthOverflow`,
`UnexpectedEndOfStream`, `BlockCrcMismatch`, `StreamCrcMismatch`,
`OutputTooLarge`, `TrailingData`. `OutOfMemory` is the only one that does not
describe the input. The whole-file helpers add the file open errors, exposed as
`bzip2.FileStreamError`.

## Examples

The `examples/` directory contains ten runnable programs:

- [`basic_compression`](examples/basic_compression.zig) - Round trip a string with verification and header introspection
- [`compression_levels`](examples/compression_levels.zig) - All nine levels side by side with ratios and timings
- [`reusable_contexts`](examples/reusable_contexts.zig) - One `Compressor` and one `Decoder` across many streams
- [`caller_buffers`](examples/caller_buffers.zig) - Caller-provided output buffers, sizing and retry on overflow
- [`chunked_input`](examples/chunked_input.zig) - Irregular write sizes producing a byte-identical stream
- [`streaming_pipelines`](examples/streaming_pipelines.zig) - `compressStream` and `decompressStream` as bounded pipelines
- [`file_compression`](examples/file_compression.zig) - File to file with staged publication, plus the damaged-stream failure path
- [`large_file`](examples/large_file.zig) - A 16 MiB round trip in constant memory, hash-verified
- [`decoder_semantics`](examples/decoder_semantics.zig) - Statistics, CRC verification, corruption taxonomy, concatenation
- [`custom_allocator`](examples/custom_allocator.zig) - A counting custom allocator proving every borrowed byte comes back

To run any example:

```bash
zig build run-basic_compression
zig build run-large_file

# Run all of them
zig build run-all-examples
```

## Validation

```bash
# Test suite
zig build test

# Test suite in optimised mode
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast

# Compile the library, the tests and every example
zig build check

# Run every example
zig build run-all-examples

# Generate API documentation
zig build docs
```

Tests live at the bottom of the module they cover. The suite covers round trips
across nineteen input shapes at all nine levels, streaming and chunking
equivalence, decoder reuse, caller-provided buffers, output budgets, whole-file
publishing, truncated and corrupted streams, and the structural validation that
rejects malformed input. It passes in Debug, ReleaseSafe and ReleaseFast.

### Built-in regression fixtures

The suite embeds fourteen complete streams in `src/fixtures/` and decodes every
one on each run: each stream must produce plaintext matching a recorded SHA-256
hash, and each plaintext must re-encode to the recorded stream.

- Three text samples (`sample1..3.bz2`, levels 1, 2 and 3, the third a legacy
  randomised block) re-produce **byte for byte**, including the 24-bit
  little-endian `origPtr` field.
- Eleven more streams cover the empty input, single bytes, all 256 byte
  values, long runs, block boundaries and multi-block framing.
- Two of the flagged streams reproduce at the same size on the same plaintext
  but differ in the low bits of `origPtr`: both are valid encodings of the
  same block sort, because the transform there has a genuine tie and the
  format lets either rotation win. Those tests assert equality outside the
  three bytes that can differ, and their plaintext byte-verified round trips.

These fixtures are the reason a change to this library cannot quietly drift
away from the real format: if a change makes this encoder produce a different
stream, or makes the decoder refuse one of them, a test fails and names the
fixture.

### Levels and compressed size

The level is the block size, and compressed size is not guaranteed to fall as the
level rises. A bigger block holds more symbols, which means more Huffman tables
and more selectors to transmit, and that overhead can outweigh what the extra
context saves. The `compression_levels` example prints the block count alongside
the size so the trade-off is visible.

Size matching is stronger than the format requires, and this encoder does
match: the embedded fixture streams re-encode byte for byte against their
recorded streams at the same levels, and their decoding returns the original
plaintext unchanged.

To compile for another target:

```bash
zig build test -Dtarget=x86_64-linux-gnu
zig build check -Dtarget=aarch64-macos
```

A foreign-target `zig build test` only compiles; it does not execute. Run the
cross-compiled artifacts on the target, or under QEMU, to validate runtime
behaviour.

## Contributing

Contributions are welcome. Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality, at the bottom of the module it affects
4. Ensure `zig build test` and `zig build check` pass
5. Submit a pull request

## Project Structure

```
bzip2.zig/
├── src/
│   ├── bzip2.zig         # Public API: one-shot, streaming and whole-file entry points
│   ├── compress.zig      # Encoder: RLE, block sort, MTF, Huffman, CRCs
│   ├── decompress.zig    # Decoder with full structural validation
│   ├── bwt.zig           # Burrows-Wheeler transform, forward and inverse
│   ├── huffman.zig       # Huffman code construction and decoding tables
│   ├── mtf.zig           # Move-to-front and RUNA/RUNB run lengths
│   ├── rle.zig           # RLE1 stage, both directions
│   ├── randomise.zig     # Legacy randomised block support
│   ├── utils.zig         # Format constants, errors, CRC, bit-level I/O
│   ├── fixtures.zig      # Embedded regression streams and their metadata
│   └── fixtures/         # Embedded compressed streams decoded by the test suite
├── examples/             # 10 runnable programs
├── docs/                 # VitePress documentation site
├── build.zig             # Build system
├── build.zig.zon         # Package metadata
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE
```

## Acknowledgements

This is a from-scratch, native Zig implementation of the BZip2 format. The
format specification and the reference implementation used for this project is
[libarchive/bzip2](https://github.com/libarchive/bzip2).

## License

MIT License - see [LICENSE](LICENSE) for details.