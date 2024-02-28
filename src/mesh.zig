const std = @import("std");
const vk = @import("vulkan-zig");
const math = @import("math.zig");

const assert = std.debug.assert;

pub const VertexInputDescription = struct {
    bindings: [1]vk.VertexInputBindingDescription,
    attributes: [1]vk.VertexInputAttributeDescription,
};

pub const Vertex = extern struct {
    pos: math.Vec3,

    pub fn getInputDescription() VertexInputDescription {
        return .{
            .bindings = .{
                .{ .binding = 0, .stride = @sizeOf(@This()), .input_rate = .vertex },
            },
            .attributes = .{
                .{ .binding = 0, .location = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(@This(), "pos") },
            },
        };
    }
};

pub const CubeSides = packed struct {
    north: bool = false,
    south: bool = false,
    east: bool = false,
    west: bool = false,
    top: bool = false,
    bottom: bool = false,

    pub usingnamespace vk.FlagsMixin(CubeSides);

    pub const north_side: @This() = .{ .north = true };
};

pub fn generateCube(sides: CubeSides, buffer: []Vertex) []Vertex {
    const count = @popCount(sides.toInt());
    assert(count < 7);
    assert(buffer.len >= count * 6); // 6 vertices per side

    var current: usize = 0;
    if (sides.contains(CubeSides.north_side)) {
        buffer[current + 0] = .{ .pos = .{ -0.5, 0.5, 0.5 } };
        buffer[current + 1] = .{ .pos = .{ 0.5, 0.5, 0.5 } };
        buffer[current + 2] = .{ .pos = .{ 0.5, -0.5, 0.5 } };
        buffer[current + 3] = .{ .pos = .{ 0.5, -0.5, 0.5 } };
        buffer[current + 4] = .{ .pos = .{ -0.5, -0.5, 0.5 } };
        buffer[current + 5] = .{ .pos = .{ -0.5, 0.5, 0.5 } };
        current += 6;
    }

    return buffer[0..current];
}
