const std = @import("std");
const math = @import("math.zig");

pos: math.Vec3,
right: math.Vec3,
dir: math.Vec3,
up: math.Vec3 = .{ 0, 1, 0 },
pitch: f32,
yaw: f32,

smooth_dir: math.Vec3,

pub fn init(pos: math.Vec3) @This() {
    var self: @This() = .{
        .pos = pos,
        .right = .{ 0, 0, 0 },
        .dir = .{ 0, 0, 0 },
        .smooth_dir = .{ 0, 0, 0 },
        .pitch = 0,
        .yaw = 0,
    };

    self.update(.{ 0, 0 });
    return self;
}

pub fn update(self: *@This(), offset: math.Vec2) void {
    self.yaw += offset[0];
    self.pitch += offset[1];

    if (self.pitch > 89) self.pitch = 89;
    if (self.pitch < -89) self.pitch = -89;

    const pitch = std.math.degreesToRadians(f32, self.pitch);
    const yaw = std.math.degreesToRadians(f32, self.yaw);

    const dir = math.Vec3{
        @cos(yaw) * @cos(pitch),
        @sin(pitch),
        @sin(yaw) * @cos(pitch),
    };

    self.dir = math.vec.normalize(dir);
    self.smooth_dir = math.vec.add(math.vec.mul(self.dir, 0.15), math.vec.mul(self.smooth_dir, 0.85));
    self.right = math.vec.normalize(math.vec.cross(self.smooth_dir, .{ 0, 1, 0 }));
    self.up = math.vec.cross(self.right, self.smooth_dir);
}

pub fn viewMatrix(self: *const @This()) math.Mat4 {
    return math.mat.lookAtDir(self.pos, self.smooth_dir, self.up);
}
