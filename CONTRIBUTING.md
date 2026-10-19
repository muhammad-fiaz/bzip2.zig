# Contributing

Bug reports, documentation fixes, performance work and pull requests are all
welcome.

## Prerequisites

Zig 0.17.0. Get it from [ziglang.org/download](https://ziglang.org/download/).

## Before opening a pull request

```bash
# Format
zig fmt src examples build.zig build.zig.zon

# Confirm formatting is clean
zig fmt --check src examples build.zig build.zig.zon

# Run the test suite
zig build test --summary all

# Compile the library, the tests and every example
zig build check

# Run every example
zig build run-all-examples

# Run the suite in release mode as well
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseFast --summary all
```

Any change to the encoder should be checked against an external `bzip2` binary
before it is merged, to confirm that output sizes match at each level and that
streams decode in both directions. The embedded regression fixtures cover the
everyday cases on their own: `zig build test` decodes fourteen embedded
streams and re-encodes their plaintexts byte for byte, so most drift away
from the real format fails in seconds without any
external tool in place.

## Where code goes

```
src/
  bzip2.zig        public API
  compress.zig     encoder
  decompress.zig   decoder
  bwt.zig          Burrows-Wheeler transform
  huffman.zig      Huffman code construction and decoding
  mtf.zig          move-to-front and run lengths
  rle.zig          run-length stage
  randomise.zig    legacy randomised block support
  utils.zig        constants, errors, CRC, bit level I/O
  fixtures.zig     embedded regression streams and their metadata
  fixtures/        the streams themselves

The library is a library, not a program. Everything the user needs is reachable
from `src/bzip2.zig`; anything else stays private to its module.

## Tests

Tests live at the bottom of the file they cover, in the same module as the code
they exercise. Add a new test to the bottom of the relevant module rather than
to a separate file, and keep the existing style:

- Use fixed seeds and fixed byte patterns. Nothing may depend on the host, the
  clock or the allocator's behaviour.
- Name a test after the property it pins down, not the function it calls.
- Assert the specific value, and print the offset when a comparison fails so the
  failure is diagnosable.
- Cover the shape that actually broke, not just the happy path.
- Define the generators a module's tests need at the bottom of that module,
  above its tests. A module that needs one input shape defines one input shape,
  rather than depending on a shared helpers file.

## Input shapes

The round-trip suite works from generated inputs rather than committed files, so
a failure reproduces on any machine and nothing depends on the working directory.
The shapes live in the `shapes` table at the bottom of `src/bzip2.zig`:

| Shape | What it exercises |
| --- | --- |
| `emptyInput` | The minimal valid stream |
| `oneByteInput`, `twoBytesInput` | Inputs shorter than a block |
| `shortTextInput` | Ordinary prose |
| `repeatedBytesInput`, `repeatedByteWithTailInput` | Long runs, including one that ends mid-run |
| `alternatingInput` | A pattern with no run at all |
| `allByteValuesInput`, `allByteValuesRepeatedInput` | The full 256-value alphabet |
| `zeroByteInput`, `longZeroRunInput` | Embedded zeros and a run far past the 255 byte maximum |
| `highEntropyInput` | Incompressible data |
| `structuredEntropyInput` | Noise with runs punched into it |
| `repetitiveInput`, `periodicInput` | Patterns the block-sorting stage finds easy or hard |
| `justUnderOneBlockInput`, `justOverOneBlockInput` | The level 1 block boundary from both sides |
| `manyBlocksInput` | Input that spans several blocks at every level |
| `mixedInput` | Text records separated by binary blobs |

Each shape is round-tripped at all nine levels and again through the streaming
entry points. A module that needs a different shape defines it locally.

## Guidelines

- **No C.** The published library must not use `@cImport`, link a C library, or
  shell out to an external process.
- **Explicit allocators and I/O.** Every entry point takes what it needs. No
  global allocator, no global file handle, no hidden state.
- **Ownership is documented.** Slices passed in are borrowed for the duration of
  the call. Slices returned belong to the caller.
- **Errors describe the input.** A malformed stream gets an error that says what
  was wrong, not a generic failure. A decoder that returns wrong bytes is worse
  than one that refuses.
- **Format compatibility is not negotiable.** Compressed sizes must match other
  implementations at the same level, and streams must decode both ways. Check an
  encoder change against an external `bzip2` before submitting it.
- **Comments explain why, not what.** The code says what it does. A comment is
  for the reason behind a choice, the constraint behind a bound, or the format
  detail that is not obvious from the code.
- **Keep the docs true.** If a change alters behaviour, update `README.md` and
  the matching page under `docs/`.

## Reporting a bug

Open an issue with what you did, what you expected and what happened, plus the
Zig version, the target and the optimisation level. A minimal reproducer is
worth more than a description.

## Questions

Open an issue or email [contact@muhammadfiaz.com](mailto:contact@muhammadfiaz.com).