const std = @import("std");
const math = @import("math.zig");
const Heightmap = @import("Heightmap.zig");
const Block = @import("Block.zig");
const mesh = @import("mesh.zig");
const Camera = @import("Camera.zig");

const assert = std.debug.assert;

const loaded_chunk_radius = 48;
const view_radius = 16;
const max_generate_per_update = 16;

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

const RenderList = struct {
    queue: std.ArrayList(math.Vec3i),
    pos_dict: std.AutoArrayHashMap(math.Vec3i, usize),
};

pos_dict: std.AutoArrayHashMap(math.Vec3i, usize),
generate_queue: std.ArrayList(math.Vec3i),
visible_list: std.ArrayList(math.Vec3i),
render_list: RenderList,
chunks: std.MultiArrayList(Chunk),
heightmap: Heightmap,

pub fn update(self: *@This(), camera: *const Camera) !void {
    self.updateGenerateQueue(camera);
    const generate_count = @min(self.generate_queue.items.len, max_generate_per_update);
    for (0..generate_count) |i| {
        const pos = self.generate_queue.items[i];
        const chunk_heightmap = self.heightmap.get(pos[0], pos[2]);
        try self.generateChunk(pos, &chunk_heightmap);
    }
    try self.generate_queue.replaceRange(0, generate_count, &.{});
    self.updateVisibleList(camera);
    self.updateRenderList(camera);
}

fn updateRenderList(self: *@This(), camera: *const Camera) void {}

fn updateVisibleList(self: *@This(), camera: *const Camera) void {
    const current_chunk = math.vec.floatToInt(math.Vec3i, camera.pos);
    loop: for (0..view_radius * 2) |k| {
        for (0..view_radius * 2) |j| {
            for (0..view_radius * 2) |i| {
                const x: i32 = @intCast(i);
                const y: i32 = @intCast(j);
                const z: i32 = @intCast(k);
                const pos: math.Vec3i = .{
                    current_chunk[0] + x - view_radius,
                    current_chunk[1] + y - view_radius,
                    current_chunk[2] + z - view_radius,
                };

                if (self.pos_dict.get(pos) == null) continue;

                const dist = math.vec.length2(math.vec.sub(pos, current_chunk));
                if (dist < view_radius * view_radius) {
                    if (self.visible_list.capacity <= self.visible_list.items.len) break :loop;
                    self.visible_list.appendAssumeCapacity(pos);
                }
            }
        }
    }
}

fn updateGenerateQueue(self: *@This(), camera: *const Camera) void {
    const current_chunk = math.vec.floatToInt(math.Vec3i, camera.pos);
    loop: for (0..loaded_chunk_radius * 2) |k| {
        for (0..loaded_chunk_radius * 2) |j| {
            for (0..loaded_chunk_radius * 2) |i| {
                const x: i32 = @intCast(i);
                const y: i32 = @intCast(j);
                const z: i32 = @intCast(k);
                const pos: math.Vec3i = .{
                    current_chunk[0] + x - loaded_chunk_radius,
                    current_chunk[1] + y - loaded_chunk_radius,
                    current_chunk[2] + z - loaded_chunk_radius,
                };
                const dist = math.vec.length2(math.vec.sub(pos, current_chunk));
                if (dist < loaded_chunk_radius * loaded_chunk_radius) {
                    if (self.generate_queue.capacity <= self.generate_queue.items.len) break :loop;
                    self.generate_queue.appendAssumeCapacity(pos);
                }
            }
        }
    }
}

fn generateChunk(self: *@This(), pos: math.Vec3i, heightmap: *const Heightmap.ChunkHeightmap) !void {
    assert(self.pos_dict.get(pos) == null);

    const chunk_idx = self.getFreeSlot() orelse return error.NoChunkSpaceLeft;
    try self.pos_dict.put(pos, chunk_idx);

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

fn generateMesh(
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
