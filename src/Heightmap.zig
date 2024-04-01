const std = @import("std");
const noise = @import("noise.zig");
const math = @import("mksv").math;
const Chunk = @import("Chunk.zig");

const assert = std.debug.assert;

const amplitude = 48.0;
const frequency = 0.05;
const iterations = 12;

pub const chunk_heightmap_size = Chunk.width * Chunk.depth;
pub const ChunkHeightmap = [chunk_heightmap_size]i16;

const max_entries = 512;

mappings: std.AutoHashMap(math.Vec2i, u16),
heightmaps: []ChunkHeightmap,
states: []bool,
delete_queue: std.ArrayList(math.Vec2i),

pub fn init(allocator: std.mem.Allocator) !@This() {
    var mappings = std.AutoHashMap(math.Vec2i, u16).init(allocator);
    try mappings.ensureTotalCapacity(max_entries);

    const states = try allocator.alloc(bool, max_entries);
    @memset(states, false);

    return .{
        .mappings = mappings,
        .heightmaps = try allocator.alloc(ChunkHeightmap, max_entries),
        .states = states,
        .delete_queue = try std.ArrayList(math.Vec2i).initCapacity(allocator, max_entries),
    };
}

pub fn get(self: *@This(), pos: math.Vec2i) !*const ChunkHeightmap {
    if (!self.mappings.contains(pos)) {
        const slot = self.getEmptySlot() orelse return error.NoEmptySlot;
        generate(pos, &self.heightmaps[slot]);
        try self.mappings.putNoClobber(pos, slot);
        self.states[slot] = true;
        try self.delete_queue.insert(0, pos);
        return &self.heightmaps[slot];
    } else {
        const slot = self.mappings.get(pos).?;
        return &self.heightmaps[slot];
    }
}

fn getEmptySlot(self: *@This()) ?u16 {
    if (self.mappings.count() < max_entries) {
        for (self.states, 0..) |state, i| {
            if (!state) return @intCast(i);
        }
    } else {
        const pos = self.delete_queue.pop();
        const slot = self.mappings.get(pos).?;
        _ = self.mappings.remove(pos);
        self.states[slot] = false;
        return slot;
    }

    return null;
}

fn generate(pos: math.Vec2i, slot: *ChunkHeightmap) void {
    const pos_f = math.vec.cast(f32, pos);
    for (0..chunk_heightmap_size) |i| {
        var freq: f32 = frequency;
        var amp: f32 = amplitude;

        const col: f32 = @floatFromInt(i % Chunk.width);
        const row: f32 = @floatFromInt(i / Chunk.depth);
        const x = pos_f[0] + col / Chunk.width;
        const y = pos_f[1] + row / Chunk.depth;

        var value: f32 = 0;
        for (0..iterations) |_| {
            value += noise.perlin(x * freq, y * freq) * amp;
            freq *= 2;
            amp /= 2;
        }

        slot[i] = @intFromFloat(value);
    }
}
