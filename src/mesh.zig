const std = @import("std");
const vk = @import("vulkan-zig");
const math = @import("math.zig");
const Block = @import("Block.zig");

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

    pub const empty: @This() = .{};
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

pub const max_vertices_per_block = 24;
pub const max_indices_per_block = 36;

const tile_width = 16.0;
const tile_height = 16.0;
const tex_width = 256.0;
const tex_height = 256.0;

pub fn generateCube(
    sides: CubeSides,
    block_id: Block.Id,
    out_vertices: *std.ArrayList(Vertex),
    out_indices: *std.ArrayList(u16),
    pos: math.Vec3,
) void {
    const count: u64 = @popCount(sides.toInt());
    assert(count < 7);
    assert(out_vertices.unusedCapacitySlice().len >= count * 4); // 4 vertices per side
    assert(out_indices.unusedCapacitySlice().len >= count * 6); // 6 indices per side

    const block = Block.fromId(block_id);

    if (sides.contains(CubeSides.front_side)) {
        const col = block.front[0];
        const row = block.front[1];

        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = math.vec.add(pos, .{ 0, 1, 1 }), .uv = uvTopLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 0, 0, 1 }), .uv = uvBottomLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 1, 0, 1 }), .uv = uvBottomRight(col, row) },
            .{ .pos = math.vec.add(pos, .{ 1, 1, 1 }), .uv = uvTopRight(col, row) },
        });
    }
    if (sides.contains(CubeSides.back_side)) {
        const col = block.back[0];
        const row = block.back[1];

        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = math.vec.add(pos, .{ 1, 1, 0 }), .uv = uvTopLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 1, 0, 0 }), .uv = uvBottomLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 0, 0, 0 }), .uv = uvBottomRight(col, row) },
            .{ .pos = math.vec.add(pos, .{ 0, 1, 0 }), .uv = uvTopRight(col, row) },
        });
    }
    if (sides.contains(CubeSides.west_side)) {
        const col = block.west[0];
        const row = block.west[1];

        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = math.vec.add(pos, .{ 0, 1, 0 }), .uv = uvTopLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 0, 0, 0 }), .uv = uvBottomLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 0, 0, 1 }), .uv = uvBottomRight(col, row) },
            .{ .pos = math.vec.add(pos, .{ 0, 1, 1 }), .uv = uvTopRight(col, row) },
        });
    }
    if (sides.contains(CubeSides.east_side)) {
        const col = block.east[0];
        const row = block.east[1];

        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = math.vec.add(pos, .{ 1, 1, 1 }), .uv = uvTopLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 1, 0, 1 }), .uv = uvBottomLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 1, 0, 0 }), .uv = uvBottomRight(col, row) },
            .{ .pos = math.vec.add(pos, .{ 1, 1, 0 }), .uv = uvTopRight(col, row) },
        });
    }
    if (sides.contains(CubeSides.south_side)) {
        const col = block.south[0];
        const row = block.south[1];

        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = math.vec.add(pos, .{ 0, 0, 1 }), .uv = uvTopLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 0, 0, 0 }), .uv = uvBottomLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 1, 0, 0 }), .uv = uvBottomRight(col, row) },
            .{ .pos = math.vec.add(pos, .{ 1, 0, 1 }), .uv = uvTopRight(col, row) },
        });
    }
    if (sides.contains(CubeSides.north_side)) {
        const col = block.north[0];
        const row = block.north[1];

        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = math.vec.add(pos, .{ 0, 1, 0 }), .uv = uvTopLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 0, 1, 1 }), .uv = uvBottomLeft(col, row) },
            .{ .pos = math.vec.add(pos, .{ 1, 1, 1 }), .uv = uvBottomRight(col, row) },
            .{ .pos = math.vec.add(pos, .{ 1, 1, 0 }), .uv = uvTopRight(col, row) },
        });
    }
}

fn appendIndices(initial_vertex: u16, out_indices: *std.ArrayList(u16)) void {
    out_indices.appendSliceAssumeCapacity(&.{
        initial_vertex + 0,
        initial_vertex + 1,
        initial_vertex + 2,
        initial_vertex + 0,
        initial_vertex + 2,
        initial_vertex + 3,
    });
}

fn uvTopLeft(col: u16, row: u16) math.Vec2 {
    const col_f: f32 = @floatFromInt(col);
    const row_f: f32 = @floatFromInt(row);
    return .{
        (col_f + 0.0) * tile_width / tex_width,
        (row_f + 0.0) * tile_height / tex_height,
    };
}

fn uvTopRight(col: u16, row: u16) math.Vec2 {
    const col_f: f32 = @floatFromInt(col);
    const row_f: f32 = @floatFromInt(row);
    return .{
        (col_f + 1.0) * tile_width / tex_width,
        (row_f + 0.0) * tile_height / tex_height,
    };
}

fn uvBottomLeft(col: u16, row: u16) math.Vec2 {
    const col_f: f32 = @floatFromInt(col);
    const row_f: f32 = @floatFromInt(row);
    return .{
        col_f * tile_width / tex_width,
        (row_f + 1.0) * tile_height / tex_height,
    };
}

fn uvBottomRight(col: u16, row: u16) math.Vec2 {
    const col_f: f32 = @floatFromInt(col);
    const row_f: f32 = @floatFromInt(row);
    return .{
        (col_f + 1.0) * tile_width / tex_width,
        (row_f + 1.0) * tile_height / tex_height,
    };
}
