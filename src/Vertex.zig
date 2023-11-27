const Self = @This();
const math = @import("math.zig");
const vk = @import("vulkan");

pos: math.Vec2,
color: math.Vec3,

pub fn bindingDescriptions() [1]vk.VertexInputBindingDescription {
    return .{
        .{
            .binding = 0,
            .stride = @sizeOf(Self),
            .input_rate = .vertex,
        },
    };
}

pub fn attributeDescriptions() [2]vk.VertexInputAttributeDescription {
    return .{
        .{
            .location = 0,
            .binding = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Self, "pos"),
        },
        .{
            .location = 1,
            .binding = 0,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Self, "color"),
        },
    };
}
