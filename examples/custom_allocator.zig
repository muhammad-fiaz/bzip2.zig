//! A custom allocator at work: a counting wrapper fronts the real allocator,
//! then proves the library returns every buffer it borrowed.
//!
//! Run with: zig build run-custom_allocator

const std = @import("std");
const bzip2 = @import("bzip2");

pub fn main(init: std.process.Init) !void {
    var counted = CountingAllocator.init(init.gpa);
    defer counted.checkZero();
    const allocator = counted.allocator();

    // A round trip through the counting allocator. Two streams run through
    // the same reused Compressor, demonstrating that a context's scratch
    // buffers stay put between streams.
    var compressor = try bzip2.Compressor.init(allocator, .{ .level = 4 });
    defer compressor.deinit();
    const texts = [_][]const u8{
        "allocation counting stream one - repetitive repetition repeated\n",
        "allocation counting stream two - different words, same allocator\n",
    };

    for (texts) |text| {
        // Bulk both messages up to a length that outlasts one small buffer,
        // so the codec does real work and the allocator sees dozens of calls.
        var message = try std.ArrayList(u8).initCapacity(allocator, text.len * 60);
        defer message.deinit(allocator);
        for (0..60) |_| try message.appendSlice(allocator, text);

        var sink: std.Io.Writer.Allocating = .init(allocator);
        defer sink.deinit();

        compressor.reset();
        try compressor.write(&sink.writer, message.items);
        try compressor.finish(&sink.writer);

        var restored: std.Io.Writer.Allocating = .init(allocator);
        defer restored.deinit();
        var source = std.Io.Reader.fixed(sink.written());
        try bzip2.decompressStream(allocator, &source, &restored.writer, .{});

        try std.testing.expectEqualStrings(message.items, restored.written());
        std.debug.print("verified: {d} -> {d} bytes through the counting allocator\n", .{
            message.items.len,
            sink.written().len,
        });
    }

    // Writer.Allocating grows with the library's scratch buffers on top of
    // the codec's own fixed-size block buffers. What matters here is the
    // balance: every byte allocated must be freed again by the end.
    std.debug.print("allocs {d}, resizes {d}, remaps {d}, frees {d}\n", .{
        counted.allocs,
        counted.resizes,
        counted.remaps,
        counted.frees,
    });
}

/// An allocator that counts calls and balances bytes. When it goes out of
/// scope, live_bytes must be zero; allocs versus frees need not match,
/// because Writer.Allocating legitimately keeps its buffers, but the byte
/// account is exact.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    resizes: usize = 0,
    remaps: usize = 0,
    frees: usize = 0,
    live_bytes: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn checkZero(self: *CountingAllocator) void {
        std.debug.assert(self.live_bytes == 0);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.allocs += 1;
            self.live_bytes += len;
        }
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) {
            self.resizes += 1;
            self.account(memory.len, new_len);
        }
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            self.remaps += 1;
            self.account(memory.len, new_len);
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.frees += 1;
        self.live_bytes -= memory.len;
    }

    /// Byte accounting across a resize or remap from old.length to new_len.
    /// Signed arithmetic keeps the decrement of a shrink correct.
    fn account(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        const delta: i64 = @as(i64, @intCast(new_len)) - @as(i64, @intCast(old_len));
        const live: i64 = @as(i64, @intCast(self.live_bytes)) + delta;
        std.debug.assert(live >= 0);
        self.live_bytes = @intCast(live);
    }
};
