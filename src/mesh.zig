const std = @import("std");
const vk = @import("vulkan-zig");
const math = @import("math.zig");

const assert = std.debug.assert;

pub const VertexInputDescription = struct {
    bindings: [1]vk.VertexInputBindingDescription,
    attributes: [3]vk.VertexInputAttributeDescription,
};

pub const Vertex = extern struct {
    pos: math.Vec3,
    color: math.Vec3,
    uv: math.Vec2,

    pub fn getInputDescription() VertexInputDescription {
        return .{
            .bindings = .{
                .{ .binding = 0, .stride = @sizeOf(@This()), .input_rate = .vertex },
            },
            .attributes = .{
                .{ .binding = 0, .location = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(@This(), "pos") },
                .{ .binding = 0, .location = 1, .format = .r32g32b32_sfloat, .offset = @offsetOf(@This(), "color") },
                .{ .binding = 0, .location = 2, .format = .r32g32_sfloat, .offset = @offsetOf(@This(), "uv") },
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

    const row = 0.0;
    const col = 2.0;
    const tile_width = 16.0;
    const tile_height = 16.0;
    const tex_width = 512.0;
    const tex_height = 512.0;

    const top_left_uv: math.Vec2 = .{ col * tile_width / tex_width, row * tile_height / tex_height };
    const top_right_uv: math.Vec2 = .{ (col + 1.0) * tile_width / tex_width, row * tile_height / tex_height };
    const bottom_left_uv: math.Vec2 = .{ col * tile_width / tex_width, (row + 1.0) * tile_height / tex_height };
    const bottom_right_uv: math.Vec2 = .{ (col + 1.0) * tile_width / tex_width, (row + 1.0) * tile_height / tex_height };

    var current: usize = 0;
    if (sides.contains(CubeSides.front_side)) {
        buffer[current + 0] = .{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 1, 0, 0 }, .uv = top_left_uv };
        buffer[current + 1] = .{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 1, 0, 0 }, .uv = bottom_right_uv };
        buffer[current + 2] = .{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 1, 0, 0 }, .uv = top_right_uv };
        buffer[current + 3] = .{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 1, 0, 0 }, .uv = bottom_right_uv };
        buffer[current + 4] = .{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 1, 0, 0 }, .uv = top_left_uv };
        buffer[current + 5] = .{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 1, 0, 0 }, .uv = bottom_left_uv };
        current += 6;
    }
    if (sides.contains(CubeSides.back_side)) {
        buffer[current + 0] = .{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0, 1, 0 }, .uv = top_right_uv };
        buffer[current + 1] = .{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0, 1, 0 }, .uv = top_left_uv };
        buffer[current + 2] = .{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0, 1, 0 }, .uv = bottom_left_uv };
        buffer[current + 3] = .{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0, 1, 0 }, .uv = bottom_left_uv };
        buffer[current + 4] = .{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0, 1, 0 }, .uv = bottom_right_uv };
        buffer[current + 5] = .{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0, 1, 0 }, .uv = top_right_uv };
        current += 6;
    }
    if (sides.contains(CubeSides.west_side)) {
        buffer[current + 0] = .{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0, 0, 1 }, .uv = top_right_uv };
        buffer[current + 1] = .{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 0, 0, 1 }, .uv = top_left_uv };
        buffer[current + 2] = .{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0, 0, 1 }, .uv = bottom_left_uv };
        buffer[current + 3] = .{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 0, 0, 1 }, .uv = top_right_uv };
        buffer[current + 4] = .{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 0, 0, 1 }, .uv = bottom_left_uv };
        buffer[current + 5] = .{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 0, 0, 1 }, .uv = bottom_right_uv };
        current += 6;
    }
    if (sides.contains(CubeSides.east_side)) {
        buffer[current + 0] = .{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0, 1, 1 }, .uv = top_left_uv };
        buffer[current + 1] = .{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0, 1, 1 }, .uv = bottom_right_uv };
        buffer[current + 2] = .{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 0, 1, 1 }, .uv = top_right_uv };
        buffer[current + 3] = .{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 0, 1, 1 }, .uv = top_left_uv };
        buffer[current + 4] = .{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 0, 1, 1 }, .uv = bottom_left_uv };
        buffer[current + 5] = .{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 0, 1, 1 }, .uv = bottom_right_uv };
        current += 6;
    }
    if (sides.contains(CubeSides.south_side)) {
        buffer[current + 0] = .{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 1, 1, 0 }, .uv = top_right_uv };
        buffer[current + 1] = .{ .pos = .{ -0.5, -0.5, 0.5 }, .color = .{ 1, 1, 0 }, .uv = top_left_uv };
        buffer[current + 2] = .{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 1, 1, 0 }, .uv = bottom_left_uv };
        buffer[current + 3] = .{ .pos = .{ 0.5, -0.5, 0.5 }, .color = .{ 1, 1, 0 }, .uv = top_right_uv };
        buffer[current + 4] = .{ .pos = .{ -0.5, -0.5, -0.5 }, .color = .{ 1, 1, 0 }, .uv = bottom_left_uv };
        buffer[current + 5] = .{ .pos = .{ 0.5, -0.5, -0.5 }, .color = .{ 1, 1, 0 }, .uv = bottom_right_uv };
        current += 6;
    }
    if (sides.contains(CubeSides.north_side)) {
        buffer[current + 0] = .{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 1, 0, 1 }, .uv = bottom_right_uv };
        buffer[current + 1] = .{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 1, 0, 1 }, .uv = top_left_uv };
        buffer[current + 2] = .{ .pos = .{ -0.5, 0.5, 0.5 }, .color = .{ 1, 0, 1 }, .uv = bottom_left_uv };
        buffer[current + 3] = .{ .pos = .{ 0.5, 0.5, 0.5 }, .color = .{ 1, 0, 1 }, .uv = bottom_right_uv };
        buffer[current + 4] = .{ .pos = .{ 0.5, 0.5, -0.5 }, .color = .{ 1, 0, 1 }, .uv = top_right_uv };
        buffer[current + 5] = .{ .pos = .{ -0.5, 0.5, -0.5 }, .color = .{ 1, 0, 1 }, .uv = top_left_uv };
        current += 6;
    }

    return buffer[0..current];
}
