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
    uv: math.Vec2,

    pub fn getInputDescription() VertexInputDescription {
        return .{
            .bindings = .{
                .{ .binding = 0, .stride = @sizeOf(@This()), .input_rate = .vertex },
            },
            .attributes = .{
                .{ .binding = 0, .location = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(@This(), "pos") },
                .{ .binding = 0, .location = 1, .format = .r32g32_sfloat, .offset = @offsetOf(@This(), "uv") },
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

pub const Cube = struct {
    vertices: []Vertex,
    indices: []u16,
};

pub fn generateCube(
    sides: CubeSides,
    out_vertices: *std.ArrayList(Vertex),
    out_indices: *std.ArrayList(u16),
) !Cube {
    const count: u64 = @popCount(sides.toInt());
    assert(count < 7);
    assert(out_vertices.unusedCapacitySlice().len >= count * 4); // 4 vertices per side
    assert(out_indices.unusedCapacitySlice().len >= count * 6); // 6 indices per side

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

    const start_vertex = out_vertices.items.len;
    const start_index = out_indices.items.len;
    if (sides.contains(CubeSides.front_side)) {
        try appendIndices(@intCast(out_vertices.items.len), out_indices);
        try out_vertices.appendSlice(&.{
            .{ .pos = .{ -0.5, 0.5, 0.5 }, .uv = top_left_uv },
            .{ .pos = .{ -0.5, -0.5, 0.5 }, .uv = bottom_left_uv },
            .{ .pos = .{ 0.5, -0.5, 0.5 }, .uv = bottom_right_uv },
            .{ .pos = .{ 0.5, 0.5, 0.5 }, .uv = top_right_uv },
        });
    }
    if (sides.contains(CubeSides.back_side)) {
        try appendIndices(@intCast(out_vertices.items.len), out_indices);
        try out_vertices.appendSlice(&.{
            .{ .pos = .{ 0.5, 0.5, -0.5 }, .uv = top_left_uv },
            .{ .pos = .{ 0.5, -0.5, -0.5 }, .uv = bottom_left_uv },
            .{ .pos = .{ -0.5, -0.5, -0.5 }, .uv = bottom_right_uv },
            .{ .pos = .{ -0.5, 0.5, -0.5 }, .uv = top_right_uv },
        });
    }
    if (sides.contains(CubeSides.west_side)) {
        try appendIndices(@intCast(out_vertices.items.len), out_indices);
        try out_vertices.appendSlice(&.{
            .{ .pos = .{ -0.5, 0.5, -0.5 }, .uv = top_left_uv },
            .{ .pos = .{ -0.5, -0.5, -0.5 }, .uv = bottom_left_uv },
            .{ .pos = .{ -0.5, -0.5, 0.5 }, .uv = bottom_right_uv },
            .{ .pos = .{ -0.5, 0.5, 0.5 }, .uv = top_right_uv },
        });
    }
    if (sides.contains(CubeSides.east_side)) {
        try appendIndices(@intCast(out_vertices.items.len), out_indices);
        try out_vertices.appendSlice(&.{
            .{ .pos = .{ 0.5, 0.5, 0.5 }, .uv = top_left_uv },
            .{ .pos = .{ 0.5, -0.5, 0.5 }, .uv = bottom_left_uv },
            .{ .pos = .{ 0.5, -0.5, -0.5 }, .uv = bottom_right_uv },
            .{ .pos = .{ 0.5, 0.5, -0.5 }, .uv = top_right_uv },
        });
    }
    if (sides.contains(CubeSides.south_side)) {
        try appendIndices(@intCast(out_vertices.items.len), out_indices);
        try out_vertices.appendSlice(&.{
            .{ .pos = .{ -0.5, -0.5, 0.5 }, .uv = top_left_uv },
            .{ .pos = .{ -0.5, -0.5, -0.5 }, .uv = bottom_left_uv },
            .{ .pos = .{ 0.5, -0.5, -0.5 }, .uv = bottom_right_uv },
            .{ .pos = .{ 0.5, -0.5, 0.5 }, .uv = top_right_uv },
        });
    }
    if (sides.contains(CubeSides.north_side)) {
        try appendIndices(@intCast(out_vertices.items.len), out_indices);
        try out_vertices.appendSlice(&.{
            .{ .pos = .{ -0.5, 0.5, -0.5 }, .uv = top_left_uv },
            .{ .pos = .{ -0.5, 0.5, 0.5 }, .uv = bottom_left_uv },
            .{ .pos = .{ 0.5, 0.5, 0.5 }, .uv = bottom_right_uv },
            .{ .pos = .{ 0.5, 0.5, -0.5 }, .uv = top_right_uv },
        });
    }

    return .{
        .vertices = out_vertices.items[start_vertex..out_vertices.items.len],
        .indices = out_indices.items[start_index..out_indices.items.len],
    };
}

fn appendIndices(initial_vertex: u16, out_indices: *std.ArrayList(u16)) !void {
    try out_indices.appendSlice(&.{
        initial_vertex + 0,
        initial_vertex + 1,
        initial_vertex + 2,
        initial_vertex + 0,
        initial_vertex + 2,
        initial_vertex + 3,
    });
}
