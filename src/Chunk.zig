const std = @import("std");
const mesh = @import("mesh.zig");
const Block = @import("Block.zig");
const math = @import("math.zig");

const assert = std.debug.assert;

pub const width = 16;
pub const height = 256;
pub const depth = 16;
pub const block_count = width * height * depth;

// 16 * 256 * 2 + 14 * 256 * 2 + 14 * 14 * 2 + 12 * 252 * 2 + 10 * 252 * 2 + 10 * 10 * 2 + 8 * 248 * 2 + 6 * 248 * 2 + 6 * 6 * 2 + 4 * 244 * 2 + 2 * 244 * 2 + 2 * 2 * 2 = 36992
pub const max_vertices = mesh.max_vertices_per_block * 36992;
pub const max_indices = mesh.max_indices_per_block * 36992;
pub const vertex_buffer_size = @sizeOf(mesh.Vertex) * max_vertices;
pub const index_buffer_size = @sizeOf(u16) * max_indices;

pub const Pos = [2]i32;

blocks: [width * height * depth]Block.Id,
pos: Pos,

pub fn default(self: *@This(), pos: Pos) void {
    self.blocks = std.mem.zeroes(@TypeOf(self.blocks));
    self.pos = pos;

    for (0..16) |z| {
        for (0..2) |y| {
            for (0..16) |x| {
                self.setBlock(x, y, z, .grass);
            }
        }
    }
    self.setBlock(8, 2, 8, .diamond_ore);
    self.setBlock(8, 3, 8, .diamond_ore);
    self.setBlock(8, 4, 8, .diamond_ore);
    self.setBlock(8, 5, 8, .diamond_ore);
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

    var sides: mesh.CubeSides = .{};

    if (z < depth - 1) {
        const front_cube = xyzTo1d(x, y, z + 1);
        if (self.blocks[front_cube] == .air)
            sides = sides.merge(.{ .front = true });
    } else {
        sides = sides.merge(.{ .front = true });
    }
    if (z > 0) {
        const back_cube = xyzTo1d(x, y, z - 1);
        if (self.blocks[back_cube] == .air)
            sides = sides.merge(.{ .back = true });
    } else {
        sides = sides.merge(.{ .back = true });
    }

    if (y < height - 1) {
        const top_cube = xyzTo1d(x, y + 1, z);
        if (self.blocks[top_cube] == .air)
            sides = sides.merge(.{ .north = true });
    } else {
        sides = sides.merge(.{ .north = true });
    }
    if (y > 0) {
        const bottom_cube = xyzTo1d(x, y - 1, z);
        if (self.blocks[bottom_cube] == .air)
            sides = sides.merge(.{ .south = true });
    } else {
        sides = sides.merge(.{ .south = true });
    }

    if (x < width - 1) {
        const east_cube = xyzTo1d(x + 1, y, z);
        if (self.blocks[east_cube] == .air)
            sides = sides.merge(.{ .east = true });
    } else {
        sides = sides.merge(.{ .east = true });
    }
    if (x > 0) {
        const west_cube = xyzTo1d(x - 1, y, z);
        if (self.blocks[west_cube] == .air)
            sides = sides.merge(.{ .west = true });
    } else {
        sides = sides.merge(.{ .west = true });
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
