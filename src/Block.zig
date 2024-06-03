const std = @import("std");
const math = @import("mksv").math;

const assert = std.debug.assert;

pub const texture_width = 16;
pub const texture_height = 16;

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
    planks,
    log,
    gravel,
    sand,
    tnt,
    coal_ore,
    iron_ore,
    gold_ore,
    diamond_ore,
    emerald_ore,

    fn tileIndex(comptime self: @This(), comptime face: Face) u8 {
        return switch (self) {
            .air => 0,
            .stone => @intFromEnum(Texture.stone),
            .cobblestone => @intFromEnum(Texture.cobblestone),
            .dirt => @intFromEnum(Texture.dirt),
            .grass => switch (face) {
                .front, .back, .east, .west => @intFromEnum(Texture.grass_side),
                .north => @intFromEnum(Texture.grass_top),
                .south => @intFromEnum(Texture.dirt),
            },
            .planks => @intFromEnum(Texture.planks),
            .log => switch (face) {
                .front, .back, .east, .west => @intFromEnum(Texture.log_side),
                .north, .south => @intFromEnum(Texture.log_top),
            },
            .gravel => @intFromEnum(Texture.gravel),
            .sand => @intFromEnum(Texture.sand),
            .tnt => switch (face) {
                .front, .back, .east, .west => @intFromEnum(Texture.tnt_side),
                .north => @intFromEnum(Texture.tnt_top),
                .south => @intFromEnum(Texture.tnt_bottom),
            },
            .coal_ore => @intFromEnum(Texture.coal_ore),
            .iron_ore => @intFromEnum(Texture.iron_ore),
            .gold_ore => @intFromEnum(Texture.gold_ore),
            .diamond_ore => @intFromEnum(Texture.diamond_ore),
            .emerald_ore => @intFromEnum(Texture.emerald_ore),
        };
    }
};

front: u8,
back: u8,
north: u8,
south: u8,
east: u8,
west: u8,

pub fn fromId(id: Id) @This() {
    return face_uvs[@intFromEnum(id)];
}

const face_uvs: [@typeInfo(Id).Enum.fields.len]@This() = blk: {
    var array: [@typeInfo(Id).Enum.fields.len]@This() = undefined;

    for (std.enums.values(Id)) |id| {
        array[@intFromEnum(id)] = .{
            .front = id.tileIndex(.front),
            .back = id.tileIndex(.back),
            .east = id.tileIndex(.east),
            .west = id.tileIndex(.west),
            .north = id.tileIndex(.north),
            .south = id.tileIndex(.south),
        };
    }

    break :blk array;
};

const Texture = enum(u8) {
    bricks = 0,
    coal_ore,
    cobblestone,
    diamond_ore,
    dirt,
    emerald_ore,
    gold_ore,
    grass_side,
    grass_top,
    gravel,
    iron_ore,
    log_side,
    log_top,
    planks,
    sand,
    stone,
    tnt_bottom,
    tnt_top,
    tnt_side,
};

const block_textures_folder = "assets/blocks/";
pub const texture_names = std.StaticStringMap(Texture).initComptime(.{
    .{ block_textures_folder ++ "bricks.png", .bricks },
    .{ block_textures_folder ++ "coal_ore.png", .coal_ore },
    .{ block_textures_folder ++ "cobblestone.png", .cobblestone },
    .{ block_textures_folder ++ "diamond_ore.png", .diamond_ore },
    .{ block_textures_folder ++ "dirt.png", .dirt },
    .{ block_textures_folder ++ "emerald_ore.png", .emerald_ore },
    .{ block_textures_folder ++ "gold_ore.png", .gold_ore },
    .{ block_textures_folder ++ "grass_side.png", .grass_side },
    .{ block_textures_folder ++ "grass_top.png", .grass_top },
    .{ block_textures_folder ++ "gravel.png", .gravel },
    .{ block_textures_folder ++ "iron_ore.png", .iron_ore },
    .{ block_textures_folder ++ "log_top.png", .log_top },
    .{ block_textures_folder ++ "log_side.png", .log_side },
    .{ block_textures_folder ++ "planks.png", .planks },
    .{ block_textures_folder ++ "sand.png", .sand },
    .{ block_textures_folder ++ "stone.png", .stone },
    .{ block_textures_folder ++ "tnt_bottom.png", .tnt_bottom },
    .{ block_textures_folder ++ "tnt_top.png", .tnt_top },
    .{ block_textures_folder ++ "tnt_side.png", .tnt_side },
});
