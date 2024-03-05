const std = @import("std");
const mesh = @import("mesh.zig");
const Block = @import("Block.zig");
const math = @import("math.zig");
const vk = @import("vulkan-zig");

const assert = std.debug.assert;

pub const width = 16;
pub const height = 16;
pub const depth = 16;
pub const block_count = width * height * depth;

// Worst case is checkerboard pattern
pub const max_vertices = mesh.max_vertices_per_block * block_count / 2;
pub const max_indices = mesh.max_indices_per_block * block_count / 2;
pub const vertex_buffer_size = @sizeOf(mesh.Vertex) * max_vertices;
pub const index_buffer_size = @sizeOf(u16) * max_indices;

const Blocks = [width * height * depth]Block.Id;

blocks: Blocks = std.mem.zeroes(Blocks),
pos: math.Vec3i = .{ 0, 0, 0 },

pub fn default(self: *@This()) void {
    self.blocks = std.mem.zeroes(@TypeOf(self.blocks));

    for (0..depth) |z| {
        for (0..2) |y| {
            for (0..width) |x| {
                self.setBlock(x, y, z, .grass);
            }
        }
    }
    self.setBlock(8, 2, 8, .tnt);
    self.setBlock(8, 3, 8, .tnt);
    self.setBlock(8, 4, 8, .tnt);
    self.setBlock(8, 5, 8, .tnt);
}

pub fn generateMesh(
    self: *const @This(),
    out_vertices: *std.ArrayList(mesh.Vertex),
    out_indices: *std.ArrayList(u16),
) !void {
    for (0..depth) |z| {
        for (0..height) |y| {
            for (0..width) |x| {
                const block_id = self.blocks[xyzTo1d(x, y, z)];
                if (block_id == .air) continue;
                const sides = self.getBlockSides(x, y, z);
                if (sides.toInt() == mesh.CubeSides.empty.toInt()) continue;
                mesh.generateCube(
                    sides,
                    block_id,
                    out_vertices,
                    out_indices,
                    .{
                        @floatFromInt(x),
                        @floatFromInt(y),
                        @floatFromInt(z),
                    },
                );
            }
        }
    }
}

pub fn getBlockSides(self: *const @This(), x: usize, y: usize, z: usize) mesh.CubeSides {
    assert(x < width);
    assert(y < height);
    assert(z < depth);

    const pos: math.Vec3i = .{ @intCast(x), @intCast(y), @intCast(z) };
    const bits: [6]mesh.CubeSides = .{
        mesh.CubeSides.front_side,
        mesh.CubeSides.back_side,
        mesh.CubeSides.north_side,
        mesh.CubeSides.south_side,
        mesh.CubeSides.east_side,
        mesh.CubeSides.west_side,
    };
    const directions: [6]math.Vec3i = .{
        .{ 0, 0, 1 },
        .{ 0, 0, -1 },
        .{ 0, 1, 0 },
        .{ 0, -1, 0 },
        .{ 1, 0, 0 },
        .{ -1, 0, 0 },
    };

    var sides: mesh.CubeSides = .{};
    for (0..6) |i| {
        const bit = bits[i];
        const direction = directions[i];
        const neighbor = math.vec.add(pos, direction);
        if (inBounds(neighbor)) {
            const idx = xyzTo1d(@intCast(neighbor[0]), @intCast(neighbor[1]), @intCast(neighbor[2]));
            if (self.blocks[idx] == .air)
                sides = sides.merge(bit);
        } else {
            sides = sides.merge(bit);
        }
    }

    return sides;
}

pub fn getBlock(self: *const @This(), x: usize, y: usize, z: usize) Block.Id {
    return self.blocks[xyzTo1d(x, y, z)];
}

pub fn setBlock(self: *@This(), x: usize, y: usize, z: usize, block: Block.Id) void {
    self.blocks[xyzTo1d(x, y, z)] = block;
}

fn xyzTo1d(x: usize, y: usize, z: usize) usize {
    return z * width * height + y * width + x;
}

fn inBounds(pos: math.Vec3i) bool {
    return pos[0] >= 0 and pos[0] < width and
        pos[1] >= 0 and pos[1] < height and
        pos[2] >= 0 and pos[2] < depth;
}
