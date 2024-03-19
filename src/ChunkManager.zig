const std = @import("std");
const math = @import("math.zig");
const Heightmap = @import("Heightmap.zig");
const Block = @import("Block.zig");
const mesh = @import("mesh.zig");

const assert = std.debug.assert;

pub const Chunk = struct {
    pub const width = 16;
    pub const height = 16;
    pub const depth = 16;
    pub const block_count = width * height * depth;

    // Worst case is checkerboard pattern
    pub const max_vertices = mesh.max_vertices_per_block * block_count / 2 / 2;
    pub const max_indices = mesh.max_indices_per_block * block_count / 2 / 2;
    pub const vertex_buffer_size = @sizeOf(mesh.Vertex) * max_vertices;
    pub const index_buffer_size = @sizeOf(u16) * max_indices;

    pub const directions: [6]math.Vec3i = .{
        .{ 0, 0, 1 },
        .{ 0, 0, -1 },
        .{ 0, 1, 0 },
        .{ 0, -1, 0 },
        .{ 1, 0, 0 },
        .{ -1, 0, 0 },
    };

    pub const State = enum {
        empty,
        in_use,
    };

    pub const SolidBlocksBitArray = std.bit_set.ArrayBitSet(u64, block_count);
    const Blocks = [block_count]Block.Id;

    blocks: Blocks = std.mem.zeroes(Blocks),
    solid_blocks: SolidBlocksBitArray,
    state: State,
};

pos_dict: std.AutoHashMap(math.Vec3i, usize),
chunks: std.MultiArrayList(Chunk),

pub fn generateChunk(self: *@This(), pos: math.Vec3i, heightmap: *const Heightmap.ChunkHeightmap) !void {
    assert(self.pos_dict.get(pos) == null);

    const chunk_idx = self.getFreeSlot() orelse return error.NoChunkSpaceLeft;

    for (0..Chunk.depth) |z| {
        for (0..Chunk.height) |y| {
            for (0..Chunk.width) |x| {
                const block_pos: math.Vec3i = .{ @intCast(x), @intCast(y), @intCast(z) };
                const pos_height = heightmap[z * Chunk.depth + x];
                const block_height = pos[1] * Chunk.height + @as(i32, @intCast(y));

                if (block_height <= pos_height) {
                    if (block_height == pos_height)
                        self.setBlock(chunk_idx, block_pos, .grass)
                    else
                        self.setBlock(chunk_idx, block_pos, .dirt);
                } else {
                    self.setBlock(chunk_idx, block_pos, .air);
                }
            }
        }
    }
}

pub fn generateMesh(
    self: *const @This(),
    pos: math.Vec3i,
    out_vertices: *std.ArrayList(mesh.Vertex),
    out_indices: *std.ArrayList(u16),
) !void {
    const idx = self.pos_dict.get(pos) orelse return error.InvalidChunk;
    const neighbors = self.getChunkNeighbors(pos) orelse return error.MissingNeighbors;
    const slice = self.chunks.slice();

    for (0..Chunk.depth) |z| {
        for (0..Chunk.height) |y| {
            for (0..Chunk.width) |x| {
                const block_id = slice.items(.blocks)[idx][xyzTo1d(x, y, z)];
                if (block_id == .air) continue;

                const block_pos: math.Vec3i = .{ @intCast(x), @intCast(y), @intCast(z) };
                const sides = self.getBlockSides(idx, block_pos, neighbors);
                if (sides.toInt() == mesh.CubeSides.empty.toInt()) continue;

                mesh.generateCube(sides, block_id, block_pos, out_vertices, out_indices);
            }
        }
    }
}

fn getBlockSides(
    self: *const @This(),
    chunk_idx: usize,
    block_pos: math.Vec3i,
    neighbor_chunks: [Chunk.directions.len]usize,
) mesh.CubeSides {
    assert(block_pos[0] < Chunk.width);
    assert(block_pos[1] < Chunk.height);
    assert(block_pos[2] < Chunk.depth);

    const solid_blocks = self.chunks.items(.solid_blocks);

    const bits: [Chunk.directions.len]mesh.CubeSides = .{
        mesh.CubeSides.front_side,
        mesh.CubeSides.back_side,
        mesh.CubeSides.north_side,
        mesh.CubeSides.south_side,
        mesh.CubeSides.east_side,
        mesh.CubeSides.west_side,
    };

    var sides: mesh.CubeSides = .{};
    for (0..Chunk.directions.len) |i| {
        const bit = bits[i];
        const direction = Chunk.directions[i];
        const neighbor_block = math.vec.add(block_pos, direction);

        if (Chunk.inBounds(neighbor_block)) {
            const idx = vecTo1d(neighbor_block);
            if (solid_blocks[chunk_idx].isSet(idx))
                sides = sides.merge(bit);
        } else {
            const neighbor_chunk_idx = neighbor_chunks[i];
            const neighbor_chunk_block_idx = xyzTo1d(
                @intCast(@mod(neighbor_block[0], Chunk.width)),
                @intCast(@mod(neighbor_block[1], Chunk.height)),
                @intCast(@mod(neighbor_block[2], Chunk.depth)),
            );
            if (solid_blocks[neighbor_chunk_idx].isSet(neighbor_chunk_block_idx))
                sides = sides.merge(bit);
        }
    }

    return sides;
}

fn getChunkNeighbors(self: *const @This(), chunk_pos: math.Vec3i) ?[Chunk.directions.len]usize {
    var neighbor_chunks: [Chunk.directions.len]usize = undefined;

    for (0..Chunk.directions.len) |i| {
        const neighbor_idx = self.pos_dict.get(math.vec.add(chunk_pos, Chunk.directions[i])) orelse return null;
        neighbor_chunks[i] = neighbor_idx;
    }

    return neighbor_chunks;
}

fn setBlock(self: *@This(), chunk_idx: usize, block_pos: math.Vec3i, block_id: Block.Id) void {
    const block_idx = vecTo1d(block_pos);
    const slice = self.chunks.slice();
    slice.items(.solid_blocks)[chunk_idx].setValue(block_idx, if (block_id == .air) false else true);
    slice.items(.blocks)[chunk_idx][block_idx] = block_id;
}

fn getBlock(self: *const @This(), chunk_idx: usize, block_pos: math.Vec3i) Block.Id {
    const block_idx = vecTo1d(block_pos);
    const slice = self.chunks.slice();
    return slice.items(.blocks)[chunk_idx][block_idx];
}

fn isBlockSolid(self: *const @This(), chunk_idx: usize, block_pos: math.Vec3i) bool {
    const block_idx = vecTo1d(block_pos);
    const slice = self.chunks.slice();
    return slice.items(.solid_blocks)[chunk_idx].isSet(block_idx);
}

fn getFreeSlot(self: *const @This()) ?usize {
    for (self.chunks.items(.state), 0..) |state, i| {
        if (state == .empty) return i;
    }

    return null;
}

inline fn vecTo1d(pos: math.Vec3i) usize {
    const x: usize = @intCast(pos[0]);
    const y: usize = @intCast(pos[1]);
    const z: usize = @intCast(pos[2]);

    return z * Chunk.width * Chunk.height + y * Chunk.width + x;
}

inline fn xyzTo1d(x: usize, y: usize, z: usize) usize {
    return z * Chunk.width * Chunk.height + y * Chunk.width + x;
}
