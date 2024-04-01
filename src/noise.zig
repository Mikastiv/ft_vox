const std = @import("std");
const math = @import("mksv").math;

fn randomGradient(ix: i32, iy: i32) math.Vec2 {
    // No precomputed gradients mean this works for any number of grid coordinates
    const w = 8 * @sizeOf(u32);
    const s = w / 2; // rotation width
    var a: u32 = @bitCast(ix);
    var b: u32 = @bitCast(iy);
    a *%= 3284157443;
    b ^= a << s | a >> w - s;
    b *%= 1911520717;
    a ^= b << s | b >> w - s;
    a *%= 2048419325;
    const random = @as(f32, @floatFromInt(a)) * (std.math.pi / @as(f32, @floatFromInt(~(~@as(u32, 0) >> 1)))); // in [0, 2*Pi]
    return .{ @cos(random), @sin(random) };
}

// Computes the dot product of the distance and gradient vectors.
fn dotGridGradient(ix: i32, iy: i32, x: f32, y: f32) f32 {
    // Get gradient from integer coordinates
    const gradient = randomGradient(ix, iy);

    // Compute the distance vector
    const dx = x - @as(f32, @floatFromInt(ix));
    const dy = y - @as(f32, @floatFromInt(iy));

    // Compute the dot-product
    return (dx * gradient[0] + dy * gradient[1]);
}

// Compute Perlin noise at coordinates x, y
pub fn perlin(x: f32, y: f32) f32 {
    // Determine grid cell coordinates
    const x0: i32 = @intFromFloat(@floor(x));
    const x1: i32 = x0 + 1;
    const y0: i32 = @intFromFloat(@floor(y));
    const y1: i32 = y0 + 1;

    // Determine interpolation weights
    // Could also use higher order polynomial/s-curve here
    const sx = x - @as(f32, @floatFromInt(x0));
    const sy = y - @as(f32, @floatFromInt(y0));

    // Interpolate between grid point gradients

    var n0 = dotGridGradient(x0, y0, x, y);
    var n1 = dotGridGradient(x1, y0, x, y);
    const ix0 = std.math.lerp(n0, n1, sx);

    n0 = dotGridGradient(x0, y1, x, y);
    n1 = dotGridGradient(x1, y1, x, y);
    const ix1 = std.math.lerp(n0, n1, sx);

    return std.math.lerp(ix0, ix1, sy);
}

// const perlin_size = 256;
// const permutation: [perlin_size * 2]i32 = .{
//     151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225, 140, 36,  103, 30,  69,  142, 8,   99,  37,  240, 21,  10,  23,
//     190, 6,   148, 247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203, 117, 35,  11,  32,  57,  177, 33,  88,  237, 149, 56,  87,  174, 20,
//     125, 136, 171, 168, 68,  175, 74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122, 60,  211, 133, 230, 220, 105, 92,
//     41,  55,  46,  245, 40,  244, 102, 143, 54,  65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169, 200, 196, 135, 130,
//     116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,  52,  217, 226, 250, 124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212, 207,
//     206, 59,  227, 47,  16,  58,  17,  182, 189, 28,  42,  223, 183, 170, 213, 119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,
//     172, 9,   129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104, 218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144,
//     12,  191, 179, 162, 241, 81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157, 184, 84,  204, 176, 115, 121, 50,  45,
//     127, 4,   150, 254, 138, 236, 205, 93,  222, 114, 67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
// };

// fn fade(t: f32) f32 {
//     return t * t * t * (t * (t * 6 - 15) + 10);
// }

// fn grad(hash: i32, x: f32, y: f32, z: f32) f32 {
//     const h = hash & 0xF;
//     const u = if (h < 8) x else y;
//     const v = if (h < 4) y else if (h == 12 or h == 14) x else z;

//     const a = if (h & 1 == 0) u else -u;
//     const b = if (h & 2 == 0) v else -v;
//     return a + b;
// }

// pub fn perlin(x: f32, y: f32, z: f32) f32 {

// }
