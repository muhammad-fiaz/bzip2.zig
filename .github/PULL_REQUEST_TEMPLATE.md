## Description

Describe what changed and why. Reference the issue it closes, for example
`Fixes #123`.

## Type of Change

- [ ] Bug fix
- [ ] New feature
- [ ] Performance improvement
- [ ] Breaking change
- [ ] Documentation update
- [ ] Build system or CI change

## Checklist

- [ ] `zig fmt --check src examples build.zig build.zig.zon` passes
- [ ] `zig build test --summary all` passes in Debug, ReleaseSafe and ReleaseFast
- [ ] `zig build check` passes, which compiles the library, the tests and every example
- [ ] `zig build run-all-examples` passes
- [ ] The change is covered by a test at the bottom of the module it affects
- [ ] Encoder changes were checked against an external `bzip2`
- [ ] The public API takes its allocator and I/O explicitly, and allocates
      nothing globally
- [ ] `README.md` and the matching page under `docs/` still describe the behaviour

## Notes

Anything a reviewer should know before reading the diff.