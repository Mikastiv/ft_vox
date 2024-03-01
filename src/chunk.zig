const std = @import("std");
const mesh = @import("mesh.zig");
const Block = @import("Block.zig");

const assert = std.debug.assert;

pub const width = 16;
pub const height = 256;
pub const depth = 16;
pub const block_count = width * height * depth;

blocks: [width * height * depth]Block.Id,

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
                try mesh.generateCube(sides, block_id, out_vertices, out_indices, .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) });
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
