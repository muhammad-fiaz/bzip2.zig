# Security Policy

## Supported Versions

| Version | Supported |
| :--- | :--- |
| 0.0.x | Yes |

## Scope

A decompression library is usually pointed at data it did not produce. Archives
arrive from downloads, uploads, package registries and backups written years
ago. The decoder is written for that case:

- Every structural field is bounds checked against the block size the stream
  header declares before it is used. A malformed stream produces an error, not
  an out-of-range index.
- The per-block and stream CRCs are verified before any result is returned, so
  data that has been altered in transit or on disk is refused rather than
  decoded into something plausible.
- `max_output_size` bounds the total output, so a small stream that expands
  hugely fails with `error.OutputTooLarge` instead of consuming memory sized by
  the sender.
- No C, no `@cImport`, no external process, no unsafe pointer arithmetic beyond
  what the Zig standard library itself provides.

## Reporting a Vulnerability

If you find a memory safety bug, buffer overrun, out-of-bounds read or write,
unbounded allocation, denial of service through an unhandled panic or a loop
that does not terminate, please report it.

- **Email**: [contact@muhammadfiaz.com](mailto:contact@muhammadfiaz.com)
- **Subject**: `[SECURITY] bzip2.zig Vulnerability Report`

Please include:

1. What the issue is and what an attacker could achieve with it.
2. A minimal reproducer. A short byte slice and the call that mishandles it is
   ideal.
3. The version and target, including the Zig version.

Reports are acknowledged, investigated, and fixed. Coordinated disclosure is
requested for anything that could affect existing users, so a fix can be
released before details are published.

## What is not a vulnerability

- A stream this library produced failing to decode, when verification was
  disabled. That is the documented meaning of `verify_crc = false`.
- Memory use growing with the size of the input for `compress` and
  `decompress`, which return the whole result in one slice. The streaming entry
  points do not behave this way.
- Differences in compressed output between implementations for the same input
  and level. The format does not fix the exact bit sequence, only the decoded
  result.