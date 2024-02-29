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

pub fn renderPassBeginInfo(
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
    extent: vk.Extent2D,
    clear_values: []const vk.ClearValue,
) vk.RenderPassBeginInfo {
    return .{
        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        },
        .clear_value_count = @intCast(clear_values.len),
        .p_clear_values = clear_values.ptr,
    };
}

pub fn samplerCreateInfo(filter: vk.Filter) vk.SamplerCreateInfo {
    return .{
        .mag_filter = filter,
        .min_filter = filter,
        .mipmap_mode = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .mip_lod_bias = 0,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 0,
        .compare_enable = vk.FALSE,
        .compare_op = .never,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = vk.FALSE,
    };
}
