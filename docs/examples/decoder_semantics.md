---
title: Decoder Semantics
description: Statistics, CRC verification on and off, and how bzip2.zig reports corruption and truncation instead of guessing.
keywords: decoder semantics, crc verification, truncated stream, corruption, statistics
---

# Decoder Semantics

Statistics, CRC verification on and off, and how corruption and truncation are
reported rather than guessed away.

```bash
zig build run-decoder_semantics
```

Source: [`examples/decoder_semantics.zig`](https://github.com/muhammad-fiaz/bzip2.zig/blob/main/examples/decoder_semantics.zig)

## Output

```text
round trip over 18900 bytes verified
stats after one stream: 1 block(s), 18900 bytes
stats keep counting: 2 block(s)
truncation still rejected with verification off: UnexpectedEndOfStream
bad magic: rejected with InvalidStreamHeader
truncated: rejected with UnexpectedEndOfStream
flipped bit rejected somewhere in the codec
first archive decoded; second stream slice 51..103 re-decoded now
second stream decoded from its own slice: 14 bytes
```

## Statistics

`blocks` counts decoded blocks; `output_bytes` counts bytes that left the
decoder. They accumulate across streams until `reset`:

```zig
var decoder = try bzip2.Decoder.init(gpa, .{});
defer decoder.deinit();

try decoder.stream(&source, &restored.writer);
const stats = decoder.decompressor.stats;
try std.testing.expectEqual(@as(u64, 1), stats.blocks);
try std.testing.expectEqual(text.items.len, stats.output_bytes);
```

A second stream through the same decoder continues the statistics:

```text
stats after one stream: 1 block(s), 18900 bytes
stats keep counting: 2 block(s)
```

## Verification off

The same bytes decode again, but damaged blocks that would have been rejected
now pass. It is only appropriate for data already known to be intact, such as
a stream this process just produced and still holds in memory. Truncation
still fails: the format itself cannot be decoded past its end.

```zig
var options = bzip2.DecompressionOptions{};
options.verify_crc = false;
var decoder = try bzip2.Decoder.init(gpa, options);
```

## Corruption taxonomy

Each damaged stream is decoded with the expectation spelled out:

```text
bad magic: rejected with InvalidStreamHeader
truncated: rejected with UnexpectedEndOfStream
flipped bit rejected somewhere in the codec
```

- `XZh9` is not a BZip2 header at all, and that is the one thing wrong with
  it. There is no reason to distinguish it further.
- A stream cut in the middle of a structured field reports truncation rather
  than a bad header, because the header was valid.
- A flipped bit inside a coded block changes the Huffman symbols that follow
  it, so the stream usually fails to parse before any CRC is compared; the
  reported error is not required to name the byte, only to refuse the stream.

## Matching on errors

The distinctions matter to a caller that wants to respond differently:

```zig
const restored = bzip2.decompress(gpa, untrusted, .{}) catch |err| switch (err) {
    error.InvalidStreamHeader => return error.NotAnArchive,
    error.UnexpectedEndOfStream => return error.TruncatedArchive,
    error.BlockCrcMismatch, error.StreamCrcMismatch => return error.CorruptArchive,
    else => return err,
};
```

## Concatenated streams

A decoded stream stops at its end-of-stream marker; what lies behind it is the
caller's business at the byte level. The example decodes the first archive,
then hands the decoder the second archive's own slice:

```zig
var source = std.Io.Reader.fixed(both.items);
try decoder.stream(&source, &restored.writer);
try std.testing.expectEqualStrings("first archive ", restored.written());

var second_archive = std.Io.Reader.fixed(both.items[one.len..]);
try decoder.stream(&second_archive, &second_pass.writer);
try std.testing.expectEqualStrings("second archive", second_pass.written());
```

## Related

- [Errors](/api/errors)
- [Decompressor](/api/decompressor)
- `file_compression.zig` rejects a damaged archive on disk
