# Installation

## Requirements

- Zig 0.17.0 or newer
- No other dependencies

The library depends on `std.Io.Reader` and `std.Io.Writer`, which arrived in
Zig 0.17.0. Older toolchains will not compile it, and the build file declares
`0.17.0` as its minimum.

## Add the package

Install the tagged release:

```bash
zig fetch --save https://github.com/muhammad-fiaz/bzip2.zig/archive/refs/tags/0.0.1.tar.gz
```

`zig fetch --save` writes the dependency into `build.zig.zon` for you and
leaves `build.zig` alone.

## Use the module

### From a build script

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my-program",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("bzip2", b.dependency("bzip2", .{
        .target = target,
        .optimize = optimize,
    }).module("bzip2"));

    b.installArtifact(exe);
}
```

Pass `target` and `optimize` through to the dependency so both are built for the
same platform and optimisation level. Skipping them makes the package build for
the host defaults, which is usually not what a cross-compiling project wants.

### As a static library

```zig
const bzip2_dep = b.dependency("bzip2", .{
    .target = target,
    .optimize = optimize,
});
b.installArtifact(bzip2_dep.artifact("bzip2"));
```

`zig build` in the package itself produces a static library in
`zig-out/lib`.

## Track the main branch

Use this to follow development:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/bzip2.zig.git
```

Pinning to a commit gives reproducible builds at the cost of not picking up
fixes:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/bzip2.zig#<commit>
```

## Verify the installation

```bash
zig build deps
zig fetch
```

If the package resolves, `zig build` in your own project will compile it.

## Toolchain

| Component | Requirement |
| --- | --- |
| Zig | 0.17.0 or newer |
| libc | not required |
| Other packages | none |

`link_libc` is false for the library module, so it builds for 64- and 32-bit
systems alike with no C to link and no platform-specific code.