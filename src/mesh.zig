const std = @import("std");
const vk = @import("vulkan-zig");
const math = @import("math.zig");

const assert = std.debug.assert;

pub const VertexInputDescription = struct {
    bindings: [1]vk.VertexInputBindingDescription,
    attributes: [2]vk.VertexInputAttributeDescription,
};

pub const Vertex = extern struct {
    pos: math.Vec3,
    color: math.Vec3,

    pub fn getInputDescription() VertexInputDescription {
        return .{
            .bindings = .{
                .{ .binding = 0, .stride = @sizeOf(@This()), .input_rate = .vertex },
            },
            .attributes = .{
                .{ .binding = 0, .location = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(@This(), "pos") },
                .{ .binding = 0, .location = 1, .format = .r32g32b32_sfloat, .offset = @offsetOf(@This(), "color") },
            },
        };
    }
};

pub const CubeSides = packed struct {
    north: bool = false,
    south: bool = false,
    east: bool = false,
    west: bool = false,
    front: bool = false,
    back: bool = false,

    pub usingnamespace vk.FlagsMixin(CubeSides);

    pub const north_side: @This() = .{ .north = true };
    pub const south_side: @This() = .{ .south = true };
    pub const east_side: @This() = .{ .east = true };
    pub const west_side: @This() = .{ .west = true };
    pub const front_side: @This() = .{ .front = true };
    pub const back_side: @This() = .{ .back = true };
};

pub fn generateCube(sides: CubeSides, buffer: []Vertex) []Vertex {
    const count: u64 = @popCount(sides.toInt());
    assert(count < 7);
    assert(buffer.len >= count * 6); // 6 vertices per side

    var current: usize = 0;
    if (sides.contains(CubeSides.front_side)) {
        buffer[current + 0] = .{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 1, 0, 0 } };
        buffer[current + 1] = .{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 1, 0, 0 } };
        buffer[current + 2] = .{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 1, 0, 0 } };
        buffer[current + 3] = .{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 1, 0, 0 } };
        buffer[current + 4] = .{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 1, 0, 0 } };
        buffer[current + 5] = .{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 1, 0, 0 } };
        current += 6;
    }
    if (sides.contains(CubeSides.back_side)) {
        buffer[current + 0] = .{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0, 1, 0 } };
        buffer[current + 1] = .{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0, 1, 0 } };
        buffer[current + 2] = .{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0, 1, 0 } };
        buffer[current + 3] = .{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0, 1, 0 } };
        buffer[current + 4] = .{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0, 1, 0 } };
        buffer[current + 5] = .{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0, 1, 0 } };
        current += 6;
    }
    if (sides.contains(CubeSides.west_side)) {
        buffer[current + 0] = .{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0, 0, 1 } };
        buffer[current + 1] = .{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0, 0, 1 } };
        buffer[current + 2] = .{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0, 0, 1 } };
        buffer[current + 3] = .{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0, 0, 1 } };
        buffer[current + 4] = .{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0, 0, 1 } };
        buffer[current + 5] = .{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0, 0, 1 } };
        current += 6;
    }
    if (sides.contains(CubeSides.east_side)) {
        buffer[current + 0] = .{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0, 1, 1 } };
        buffer[current + 1] = .{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0, 1, 1 } };
        buffer[current + 2] = .{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0, 1, 1 } };
        buffer[current + 3] = .{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0, 1, 1 } };
        buffer[current + 4] = .{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0, 1, 1 } };
        buffer[current + 5] = .{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0, 1, 1 } };
        current += 6;
    }
    if (sides.contains(CubeSides.south_side)) {
        buffer[current + 0] = .{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 1, 1, 0 } };
        buffer[current + 1] = .{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 1, 1, 0 } };
        buffer[current + 2] = .{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 1, 1, 0 } };
        buffer[current + 3] = .{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 1, 1, 0 } };
        buffer[current + 4] = .{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 1, 1, 0 } };
        buffer[current + 5] = .{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 1, 1, 0 } };
        current += 6;
    }
    if (sides.contains(CubeSides.north_side)) {
        buffer[current + 0] = .{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 1, 0, 1 } };
        buffer[current + 1] = .{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 1, 0, 1 } };
        buffer[current + 2] = .{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 1, 0, 1 } };
        buffer[current + 3] = .{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 1, 0, 1 } };
        buffer[current + 4] = .{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 1, 0, 1 } };
        buffer[current + 5] = .{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 1, 0, 1 } };
        current += 6;
    }

    return buffer[0..current];
}
