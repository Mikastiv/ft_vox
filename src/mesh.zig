const std = @import("std");
const vk = @import("vulkan-zig");
const math = @import("math.zig");
const Block = @import("Block.zig");

const assert = std.debug.assert;

pub const VertexInputDescription = struct {
    bindings: [1]vk.VertexInputBindingDescription,
    attributes: [2]vk.VertexInputAttributeDescription,
};

pub const Position = packed struct(u32) {
    x: u5,
    y: u5,
    z: u5,
    _unused: u17,

    pub fn fromVec(vec: math.Vec3) @This() {
        assert(vec[0] < 17);
        assert(vec[1] < 17);
        assert(vec[2] < 17);

        const x: u5 = @intFromFloat(vec[0]);
        const y: u5 = @intFromFloat(vec[1]);
        const z: u5 = @intFromFloat(vec[2]);

        return .{
            .x = x,
            .y = y,
            .z = z,
            ._unused = 0,
        };
    }
};

pub const Vertex = extern struct {
    uv: math.Vec2,
    pos: Position,

    pub fn getInputDescription() VertexInputDescription {
        return .{
            .bindings = .{
                .{ .binding = 0, .stride = @sizeOf(@This()), .input_rate = .vertex },
            },
            .attributes = .{
                .{ .binding = 0, .location = 0, .format = .r32g32_sfloat, .offset = @offsetOf(@This(), "uv") },
                .{ .binding = 0, .location = 1, .format = .r32_uint, .offset = @offsetOf(@This(), "pos") },
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
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 1, 1 })), .uv = block.front[0] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 0, 1 })), .uv = block.front[1] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 0, 1 })), .uv = block.front[2] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 1, 1 })), .uv = block.front[3] },
        });
    }
    if (sides.contains(CubeSides.back_side)) {
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 1, 0 })), .uv = block.back[0] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 0, 0 })), .uv = block.back[1] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 0, 0 })), .uv = block.back[2] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 1, 0 })), .uv = block.back[3] },
        });
    }
    if (sides.contains(CubeSides.west_side)) {
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 1, 0 })), .uv = block.west[0] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 0, 0 })), .uv = block.west[1] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 0, 1 })), .uv = block.west[2] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 1, 1 })), .uv = block.west[3] },
        });
    }
    if (sides.contains(CubeSides.east_side)) {
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 1, 1 })), .uv = block.east[0] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 0, 1 })), .uv = block.east[1] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 0, 0 })), .uv = block.east[2] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 1, 0 })), .uv = block.east[3] },
        });
    }
    if (sides.contains(CubeSides.south_side)) {
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 0, 1 })), .uv = block.south[0] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 0, 0 })), .uv = block.south[1] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 0, 0 })), .uv = block.south[2] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 0, 1 })), .uv = block.south[3] },
        });
    }
    if (sides.contains(CubeSides.north_side)) {
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 1, 0 })), .uv = block.north[0] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 0, 1, 1 })), .uv = block.north[1] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 1, 1 })), .uv = block.north[2] },
            .{ .pos = Position.fromVec(math.vec.add(pos, .{ 1, 1, 0 })), .uv = block.north[3] },
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
