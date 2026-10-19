# Getting Started

## Requirements

Zig 0.17.0. The library uses the `std.Io` interfaces introduced in that
release, so an older toolchain will not compile it.

Nothing else. There are no package dependencies, no build-time code generation
and no C library to link.

## Add the dependency

Install the tagged release:

```bash
zig fetch --save https://github.com/muhammad-fiaz/bzip2.zig/archive/refs/tags/0.0.1.tar.gz
```

To follow the main branch rather than a tagged release:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/bzip2.zig.git
```

## Wire it into the build

In `build.zig`:

```zig
const bzip2 = b.dependency("bzip2", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("bzip2", bzip2.module("bzip2"));
```

`target` and `optimize` are the ones your own project uses, declared the usual
way:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});
```

## Compress something

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

    std.debug.print("{d} bytes became {d} bytes\n", .{ text.len, compressed.len });
}
```

Run it:

```text
900 bytes became 124 bytes
```

## Decompress it again

```zig
const restored = try bzip2.decompress(gpa, compressed, .{});
defer gpa.free(restored);

std.debug.assert(std.mem.eql(u8, &text, restored));
```

`decompress` verifies the block and stream CRCs as it goes. Either the result
matches the input exactly or the call returns an error; there is no path that
returns wrong bytes quietly.

## Both slices are yours

`compress` and `decompress` return memory allocated with the allocator you
passed in. Free it with the same allocator. Nothing is cached between calls, so
the only thing keeping a buffer alive is your reference to it.

## Handle failure

Damaged input is an expected condition for anything that arrives over a network
or sits on disk for years, not an exceptional one:

```zig
const restored = bzip2.decompress(gpa, untrusted, .{}) catch |err| switch (err) {
    error.StreamCrcMismatch => return error.CorruptArchive,
    error.InvalidStreamHeader => return error.NotAnArchive,
    error.UnexpectedEndOfStream => return error.TruncatedArchive,
    else => return err,
};
defer gpa.free(restored);
```

See [Errors](/api/errors) for the full set.

## Where to go next

- [Compression](/guide/compression) explains the levels and what to expect from
  each
- [Streaming](/guide/streaming) covers input that does not fit in memory
- [Memory and Allocators](/guide/memory) covers allocator choice and reuse