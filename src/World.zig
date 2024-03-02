const std = @import("std");
const Chunk = @import("Chunk.zig");

chunks: []Chunk,
in_use: []bool,

pub fn init(allocator: std.mem.Allocator) !@This() {
    const self: @This() = .{
        .chunks = try allocator.alloc(Chunk, 32),
        .in_use = try allocator.alloc(bool, 32),
    };

    @memset(self.in_use, false);

    return self;
}
