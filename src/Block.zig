const std = @import("std");
const math = @import("math.zig");

const assert = std.debug.assert;

const tile_width = 16.0;
const tile_height = 16.0;
const tex_width = 256.0;
const tex_height = 256.0;

const Face = enum {
    front,
    back,
    north,
    south,
    east,
    west,
};

pub const Id = enum(u8) {
    air = 0,
    stone,
    cobblestone,
    dirt,
    grass,
    plank,
    log,
    gravel,
    sand,
    tnt,
    coal_ore,
    iron_ore,
    gold_ore,
    diamond_ore,
    emerald_ore,

    fn tileCoords(comptime self: @This(), comptime face: Face) [2]u16 {
        return switch (self) {
            .air => .{ 0, 0 },
            .stone => .{ 6, 0 },
            .cobblestone => .{ 7, 0 },
            .dirt => .{ 2, 0 },
            .grass => switch (face) {
                .front, .back, .east, .west => .{ 1, 0 },
                .north => .{ 0, 0 },
                .south => .{ 2, 0 },
            },
            .plank => .{ 3, 0 },
            .log => switch (face) {
                .front, .back, .east, .west => .{ 4, 0 },
                .north, .south => .{ 5, 0 },
            },
            .gravel => .{ 13, 0 },
            .sand => .{ 12, 0 },
            .tnt => switch (face) {
                .front, .back, .east, .west => .{ 9, 0 },
                .north => .{ 10, 0 },
                .south => .{ 11, 0 },
            },
            .coal_ore => .{ 14, 0 },
            .iron_ore => .{ 15, 0 },
            .gold_ore => .{ 2, 1 },
            .diamond_ore => .{ 1, 1 },
            .emerald_ore => .{ 0, 1 },
        };
    }
};

front: [4]math.Vec2,
back: [4]math.Vec2,
north: [4]math.Vec2,
south: [4]math.Vec2,
east: [4]math.Vec2,
west: [4]math.Vec2,

pub fn fromId(id: Id) @This() {
    return face_uvs[@intFromEnum(id)];
}

const face_uvs: [@typeInfo(Id).Enum.fields.len]@This() = blk: {
    var array: [@typeInfo(Id).Enum.fields.len]@This() = undefined;

    for (std.enums.values(Id)) |id| {
        const coords_front = id.tileCoords(.front);
        const coords_back = id.tileCoords(.back);
        const coords_east = id.tileCoords(.east);
        const coords_west = id.tileCoords(.west);
        const coords_north = id.tileCoords(.north);
        const coords_south = id.tileCoords(.south);

        array[@intFromEnum(id)] = .{
            .front = .{
                uvTopLeft(coords_front[0], coords_front[1]),
                uvBottomLeft(coords_front[0], coords_front[1]),
                uvBottomRight(coords_front[0], coords_front[1]),
                uvTopRight(coords_front[0], coords_front[1]),
            },
            .back = .{
                uvTopLeft(coords_back[0], coords_back[1]),
                uvBottomLeft(coords_back[0], coords_back[1]),
                uvBottomRight(coords_back[0], coords_back[1]),
                uvTopRight(coords_back[0], coords_back[1]),
            },
            .east = .{
                uvTopLeft(coords_east[0], coords_east[1]),
                uvBottomLeft(coords_east[0], coords_east[1]),
                uvBottomRight(coords_east[0], coords_east[1]),
                uvTopRight(coords_east[0], coords_east[1]),
            },
            .west = .{
                uvTopLeft(coords_west[0], coords_west[1]),
                uvBottomLeft(coords_west[0], coords_west[1]),
                uvBottomRight(coords_west[0], coords_west[1]),
                uvTopRight(coords_west[0], coords_west[1]),
            },
            .north = .{
                uvTopLeft(coords_north[0], coords_north[1]),
                uvBottomLeft(coords_north[0], coords_north[1]),
                uvBottomRight(coords_north[0], coords_north[1]),
                uvTopRight(coords_north[0], coords_north[1]),
            },
            .south = .{
                uvTopLeft(coords_south[0], coords_south[1]),
                uvBottomLeft(coords_south[0], coords_south[1]),
                uvBottomRight(coords_south[0], coords_south[1]),
                uvTopRight(coords_south[0], coords_south[1]),
            },
        };
    }

    break :blk array;
};

fn uvTopLeft(x: u16, y: u16) math.Vec2 {
    const col: f32 = @floatFromInt(x);
    const row: f32 = @floatFromInt(y);
    return .{
        (col + 0.0) * tile_width / tex_width,
        (row + 0.0) * tile_height / tex_height,
    };
}

fn uvTopRight(x: u16, y: u16) math.Vec2 {
    const col: f32 = @floatFromInt(x);
    const row: f32 = @floatFromInt(y);
    return .{
        (col + 1.0) * tile_width / tex_width,
        (row + 0.0) * tile_height / tex_height,
    };
}

fn uvBottomLeft(x: u16, y: u16) math.Vec2 {
    const col: f32 = @floatFromInt(x);
    const row: f32 = @floatFromInt(y);
    return .{
        col * tile_width / tex_width,
        (row + 1.0) * tile_height / tex_height,
    };
}

fn uvBottomRight(x: u16, y: u16) math.Vec2 {
    const col: f32 = @floatFromInt(x);
    const row: f32 = @floatFromInt(y);
    return .{
        (col + 1.0) * tile_width / tex_width,
        (row + 1.0) * tile_height / tex_height,
    };
}
