---
title: Errors
description: Every error bzip2.zig can return — from CrcMismatch to UnexpectedEndOfStream — and what each one says about the input.
keywords: bzip2 errors, crc mismatch, unexpected end of stream, invalid header, output too large
---

# Errors

Every failure that concerns the stream has its own error. A caller can tell a
corrupt archive from a truncated one from something that was never a BZip2
stream, which matters because those cases need different responses.

`error.OutOfMemory` is the only error that does not describe the input.

## Error sets

```zig
pub const Error = error{ ... };       // the codec and its input
pub const IoError = std.Io.Writer.Error || std.Io.Reader.Error;
pub const StreamError = Error || IoError;
pub const FileError = std.Io.File.OpenError || std.Io.Dir.RenameError ||
    error{SamePathAsSourceAndDestination};
pub const FileStreamError = StreamError || FileError;
```

| Alias | Returned by |
| --- | --- |
| `Error` | `blockSizeOfStream`, `maxCompressedSize` |
| `StreamError` | `compress`, `decompress`, `compressStream`, `decompressStream` |
| `FileStreamError` | `compressFile`, `decompressFile` |

The whole-file helpers add the file open errors (and the rename errors the
staged publication uses), since a missing or unreadable source is a different
problem from a damaged stream.

## Compression

| Error | Cause |
| --- | --- |
| `InvalidCompressionLevel` | A level outside 1 through 9 was requested |

Checked before any work is done, so no buffers are allocated for an invalid
level.

## Structure

| Error | Cause |
| --- | --- |
| `InvalidStreamHeader` | The `BZh<level>` header is not well formed |
| `InvalidBlockMarker` | A 48 bit block marker was expected and not found |
| `InvalidEndOfStreamMarker` | The end-of-stream marker was expected and not found |
| `InvalidSymbolMap` | The symbol map is empty or inconsistent |
| `InvalidSelectors` | The selector count was zero, or a selector value was out of range |
| `InvalidHuffmanTable` | A code length was outside 1 through 20, or the code was over-subscribed |
| `InvalidHuffmanCode` | A code word did not resolve against the current table |
| `InvalidSequence` | A block decoded to a symbol stream the format cannot express |
| `InvalidOrigPtr` | `orig_ptr` does not address a row of the reconstructed block |
| `RunLengthOverflow` | A RUNA/RUNB run exceeded the largest block the format can express |
| `UnexpectedEndOfStream` | The stream ended in the middle of a structural element |

Every one of these is raised after the relevant value has been bounds checked
against limits derived from the block size the header declares. A malformed
stream never reaches an unchecked index.

## Integrity

| Error | Cause |
| --- | --- |
| `BlockCrcMismatch` | A block CRC does not match the decoded bytes |
| `StreamCrcMismatch` | The stream CRC does not match the stream |

Each block stores a CRC of the bytes it encoded and the trailer stores a CRC
combined across all blocks. Both are verified before a result is returned.

These two errors usually mean the same thing to a caller, corruption in
transit or on disk. They are separate because a stream CRC failure with intact
block CRCs points at the framing rather than the payload.

## Limits

| Error | Cause |
| --- | --- |
| `OutputTooLarge` | `max_output_size` was exceeded |
| `TrailingData` | Bytes after the end-of-stream marker were rejected |
| `SamePathAsSourceAndDestination` | A whole-file call was asked to read and write the same path |
| `OutOfMemory` | The allocator refused a request |

`OutputTooLarge` is the one to set up for on untrusted input. A small stream can
expand into a much larger one, and this stops that before any of it is
allocated.

`TrailingData` is part of the set for callers who want to reject trailing bytes
themselves. The default path ignores them, which matches what other
implementations do.

`SamePathAsSourceAndDestination` is refused before either path is opened, so the
input cannot be destroyed by a whole-file call.

## Matching on errors

Switching keeps the cases distinct:

```zig
const restored = bzip2.decompress(gpa, untrusted, .{}) catch |err| switch (err) {
    error.InvalidStreamHeader => return error.NotAnArchive,
    error.UnexpectedEndOfStream => return error.TruncatedArchive,
    error.BlockCrcMismatch, error.StreamCrcMismatch => return error.CorruptArchive,
    error.OutputTooLarge => return error.DecompressionBomb,
    error.OutOfMemory => return err,
    else => return err,
};
defer gpa.free(restored);
```

A decoder that returns wrong bytes is worse than one that refuses, so any
unhandled error should be treated as "do not trust this data" rather than
"retry".

## Errors while doing I/O

The streaming and file entry points also return the relevant `std.Io` errors,
which is what makes a disk failure or a closed pipe distinguishable from a bad
stream:

| Set | Covers |
| --- | --- |
| `std.Io.Reader.Error` | `EndOfStream`, `ReadFailed` |
| `std.Io.Writer.Error` | `WriteFailed`, `DiskFull`, and the rest |
| `std.Io.File.OpenError` | `FileNotFound`, `AccessDenied`, `IsDir`, and the rest |

`error.EndOfStream` reaching a caller of `decompressStream` means the stream
ended before the end marker, which is a truncated stream rather than a
successful end of input. The streaming decoder converts it to
`error.UnexpectedEndOfStream` where it can, and the raw reader error surfaces
only when the source fails underneath.

## Testing against error behaviour

```zig
test "a corrupted stream CRC is detected" {
    const compressed = try bzip2.compress(gpa, input, .{ .level = 9 });
    defer gpa.free(compressed);

    const corrupted = try gpa.dupe(u8, compressed);
    defer gpa.free(corrupted);
    // The stream CRC is the last 32 bits, so its most significant bit is the
    // top bit of the fourth byte from the end. The final byte also carries zero
    // padding, which is why it is not the one to flip.
    corrupted[corrupted.len - 4] ^= 0x80;

    try std.testing.expectError(
        error.StreamCrcMismatch,
        bzip2.decompress(gpa, corrupted, .{}),
    );
}
```

The test sections at the bottom of `src/decompress.zig` cover every structural
error, along with truncation at every offset, single-bit flips, byte
substitutions and random noise.