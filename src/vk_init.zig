const vk = @import("vulkan-zig");

pub fn commandBufferAllocateInfo(command_pool: vk.CommandPool) vk.CommandBufferAllocateInfo {
    return .{
        .command_pool = command_pool,
        .command_buffer_count = 1,
        .level = .primary,
    };
}

pub fn imageCreateInfo(format: vk.Format, usage: vk.ImageUsageFlags, extent: vk.Extent3D) vk.ImageCreateInfo {
    return .{
        .image_type = .@"2d",
        .format = format,
        .extent = .{
            .width = extent.width,
            .height = extent.height,
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };
}

pub fn imageViewCreateInfo(format: vk.Format, image: vk.Image, aspect_flags: vk.ImageAspectFlags) vk.ImageViewCreateInfo {
    return .{
        .view_type = .@"2d",
        .image = image,
        .format = format,
        .subresource_range = .{
            .aspect_mask = aspect_flags,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
    };
}
