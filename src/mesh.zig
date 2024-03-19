const std = @import("std");
const vk = @import("vulkan-zig");
const math = @import("math.zig");
const Block = @import("Block.zig");
const Chunk = @import("Chunk.zig");

const assert = std.debug.assert;

pub const VertexInputDescription = struct {
    bindings: [1]vk.VertexInputBindingDescription,
    attributes: [1]vk.VertexInputAttributeDescription,
};

pub const Face = enum(u3) {
    front = 0,
    back,
    east,
    west,
    north,
    south,
};

pub const PackedVertex = packed struct(u32) {
    x: u5,
    y: u5,
    z: u5,
    index: u8,
    face: Face,
    _unused: u6 = 0,

    pub fn init(vec: math.Vec3i, texture_index: u8, face: Face) @This() {
        assert(vec[0] <= Chunk.width);
        assert(vec[1] <= Chunk.height);
        assert(vec[2] <= Chunk.depth);

        const x: u5 = @intCast(vec[0]);
        const y: u5 = @intCast(vec[1]);
        const z: u5 = @intCast(vec[2]);

        return .{
            .x = x,
            .y = y,
            .z = z,
            .index = texture_index,
            .face = face,
        };
    }
};

pub const Vertex = extern struct {
    data: PackedVertex,

    pub fn getInputDescription() VertexInputDescription {
        return .{
            .bindings = .{
                .{ .binding = 0, .stride = @sizeOf(@This()), .input_rate = .vertex },
            },
            .attributes = .{
                .{ .binding = 0, .location = 0, .format = .r32_uint, .offset = @offsetOf(@This(), "data") },
            },
        };
    }
};

pub const SkyboxVertex = extern struct {
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
    pos: math.Vec3i,
    out_vertices: *std.ArrayList(Vertex),
    out_indices: *std.ArrayList(u16),
) void {
    const count: u64 = @popCount(sides.toInt());
    assert(count < 7);
    assert(out_vertices.unusedCapacitySlice().len >= count * 4); // 4 vertices per side
    assert(out_indices.unusedCapacitySlice().len >= count * 6); // 6 indices per side

    const block = Block.fromId(block_id);

    if (sides.contains(CubeSides.front_side)) {
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 1, 1 }), block.front, .front) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 0, 1 }), block.front, .front) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 0, 1 }), block.front, .front) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 1, 1 }), block.front, .front) },
        });
    }
    if (sides.contains(CubeSides.back_side)) {
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 1, 0 }), block.back, .back) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 0, 0 }), block.back, .back) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 0, 0 }), block.back, .back) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 1, 0 }), block.back, .back) },
        });
    }
    if (sides.contains(CubeSides.west_side)) {
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 1, 0 }), block.west, .west) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 0, 0 }), block.west, .west) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 0, 1 }), block.west, .west) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 1, 1 }), block.west, .west) },
        });
    }
    if (sides.contains(CubeSides.east_side)) {
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 1, 1 }), block.east, .east) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 0, 1 }), block.east, .east) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 0, 0 }), block.east, .east) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 1, 0 }), block.east, .east) },
        });
    }
    if (sides.contains(CubeSides.south_side)) {
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 0, 1 }), block.south, .south) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 0, 0 }), block.south, .south) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 0, 0 }), block.south, .south) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 0, 1 }), block.south, .south) },
        });
    }
    if (sides.contains(CubeSides.north_side)) {
        appendIndices(@intCast(out_vertices.items.len), out_indices);
        out_vertices.appendSliceAssumeCapacity(&.{
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 1, 0 }), block.north, .north) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 0, 1, 1 }), block.north, .north) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 1, 1 }), block.north, .north) },
            .{ .data = PackedVertex.init(math.vec.add(pos, .{ 1, 1, 0 }), block.north, .north) },
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
