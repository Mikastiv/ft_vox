const std = @import("std");
const noise = @import("noise.zig");
const math = @import("math.zig");
const Chunk = @import("Chunk.zig");

const assert = std.debug.assert;

const amplitude = 48.0;
const frequency = 0.05;
const iterations = 12;

pub const size = Chunk.width * Chunk.depth;

values: [size]i32,

pub fn generate(pos: math.Vec3i) @This() {
    const pos_f = math.vec.intToFloat(f32, pos);
    var heightmap: @This() = undefined;
    for (0..size) |i| {
        var freq: f32 = frequency;
        var amp: f32 = amplitude;

        const col: f32 = @floatFromInt(i % Chunk.width);
        const row: f32 = @floatFromInt(i / Chunk.depth);
        const x = pos_f[0] + col / Chunk.width;
        const y = pos_f[2] + row / Chunk.depth;

        var value: f32 = 0;
        for (0..iterations) |_| {
            value += noise.perlin(x * freq, y * freq) * amp;
            freq *= 2;
            amp /= 2;
        }

        heightmap.values[i] = @intFromFloat(value);
    }

    return heightmap;
}
