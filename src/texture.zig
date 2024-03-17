const std = @import("std");
const c = @import("c.zig");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const Engine = @import("Engine.zig");
const vk_utils = @import("vk_utils.zig");
const Block = @import("Block.zig");

const assert = std.debug.assert;

const vkd = vkk.dispatch.vkd;

pub fn loadFromFile(
    device: *const vkk.Device,
    staging_buffer: Engine.AllocatedBuffer,
    immediate_context: Engine.ImmediateContext,
    filename: [*:0]const u8,
) !Engine.AllocatedImage {
    var width: c_int = undefined;
    var height: c_int = undefined;
    var channels: c_int = undefined;

    const pixels = c.stbi_load(filename, &width, &height, &channels, c.STBI_rgb_alpha) orelse
        return error.TextureLoadingFailed;
    defer c.stbi_image_free(pixels);

    const image_size: vk.DeviceSize = @intCast(width * height * 4);
    const format: vk.Format = .r8g8b8a8_srgb;

    {
        const data = try vkd().mapMemory(device.handle, staging_buffer.memory, 0, image_size, .{});
        defer vkd().unmapMemory(device.handle, staging_buffer.memory);

        const ptr: [*]c.stbi_uc = @ptrCast(@alignCast(data));
        @memcpy(ptr, pixels[0..image_size]);
    }

    const extent: vk.Extent3D = .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 };
    const image = try vk_utils.createImage(
        device.handle,
        device.physical_device,
        format,
        .{ .transfer_dst_bit = true, .sampled_bit = true },
        extent,
        .{ .device_local_bit = true },
        .{ .color_bit = true },
        1,
        .{},
    );

    try Engine.immediateSubmit(device.handle, device.graphics_queue, immediate_context, ImageCopy{
        .image = image.handle,
        .buffer = staging_buffer.handle,
        .queue_family_index = device.graphics_queue_index,
        .extent = extent,
    });

    return image;
}

const ImageCopy = struct {
    image: vk.Image,
    buffer: vk.Buffer,
    queue_family_index: u32,
    extent: vk.Extent3D,

    pub fn recordCommands(ctx: @This(), cmd: vk.CommandBuffer) void {
        const range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };

        {
            const image_barrier = vk.ImageMemoryBarrier{
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
                .image = ctx.image,
                .subresource_range = range,
                .src_access_mask = .{},
                .dst_access_mask = .{ .transfer_write_bit = true },
                .src_queue_family_index = ctx.queue_family_index,
                .dst_queue_family_index = ctx.queue_family_index,
            };

            vkd().cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, 0, null, 0, null, 1, @ptrCast(&image_barrier));
        }

        const copy = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = ctx.extent,
        };

        vkd().cmdCopyBufferToImage(cmd, ctx.buffer, ctx.image, .transfer_dst_optimal, 1, @ptrCast(&copy));

        const image_barrier = vk.ImageMemoryBarrier{
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .image = ctx.image,
            .subresource_range = range,
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .src_queue_family_index = ctx.queue_family_index,
            .dst_queue_family_index = ctx.queue_family_index,
        };

        vkd().cmdPipelineBarrier(cmd, .{ .transfer_bit = true }, .{ .fragment_shader_bit = true }, .{}, 0, null, 0, null, 1, @ptrCast(&image_barrier));
    }
};

pub fn loadBlockTextures(
    device: *const vkk.Device,
    staging_buffer: Engine.AllocatedBuffer,
    immediate_context: Engine.ImmediateContext,
) !Engine.AllocatedImage {
    const image_size = Block.texture_width * Block.texture_height * 4;
    const data = try vkd().mapMemory(
        device.handle,
        staging_buffer.memory,
        0,
        Block.texture_names.kvs.len * image_size,
        .{},
    );
    defer vkd().unmapMemory(device.handle, staging_buffer.memory);

    const gpu_ptr: [*]c.stbi_uc = @ptrCast(@alignCast(data));

    const extent: vk.Extent3D = .{
        .width = @intCast(Block.texture_width),
        .height = @intCast(Block.texture_height),
        .depth = 1,
    };
    var copy_regions = try std.BoundedArray(vk.BufferImageCopy, 32).init(0);

    for (&Block.texture_names.kvs) |pair| {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var channels: c_int = undefined;

        const pixels = c.stbi_load(pair.key.ptr, &width, &height, &channels, c.STBI_rgb_alpha) orelse
            return error.TextureLoadingFailed;
        defer c.stbi_image_free(pixels);

        assert(width == 16 and height == 16);

        const offset = image_size * @as(u32, @intFromEnum(pair.value));
        @memcpy(gpu_ptr[offset .. offset + image_size], pixels[0..image_size]);

        const copy_region = vk.BufferImageCopy{
            .buffer_offset = @intCast(offset),
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = @intFromEnum(pair.value),
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = extent,
        };
        try copy_regions.append(copy_region);
    }

    const format: vk.Format = .r8g8b8a8_srgb;
    const image = try vk_utils.createImage(
        device.handle,
        device.physical_device,
        format,
        .{ .transfer_dst_bit = true, .sampled_bit = true },
        extent,
        .{ .device_local_bit = true },
        .{ .color_bit = true },
        .@"2d_array",
        Block.texture_names.kvs.len,
        .{},
    );

    try Engine.immediateSubmit(device.handle, device.graphics_queue, immediate_context, ImageArrayCopy{
        .image = image.handle,
        .buffer = staging_buffer.handle,
        .queue_family_index = device.graphics_queue_index,
        .extent = extent,
        .layer_count = Block.texture_names.kvs.len,
        .copy_regions = copy_regions.constSlice(),
    });

    return image;
}

const ImageArrayCopy = struct {
    image: vk.Image,
    buffer: vk.Buffer,
    queue_family_index: u32,
    extent: vk.Extent3D,
    layer_count: u32,
    copy_regions: []const vk.BufferImageCopy,

    pub fn recordCommands(ctx: @This(), cmd: vk.CommandBuffer) void {
        const range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = ctx.layer_count,
        };

        {
            const image_barrier = vk.ImageMemoryBarrier{
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
                .image = ctx.image,
                .subresource_range = range,
                .src_access_mask = .{},
                .dst_access_mask = .{ .transfer_write_bit = true },
                .src_queue_family_index = ctx.queue_family_index,
                .dst_queue_family_index = ctx.queue_family_index,
            };

            vkd().cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, 0, null, 0, null, 1, @ptrCast(&image_barrier));
        }

        vkd().cmdCopyBufferToImage(cmd, ctx.buffer, ctx.image, .transfer_dst_optimal, @intCast(ctx.copy_regions.len), ctx.copy_regions.ptr);

        const image_barrier = vk.ImageMemoryBarrier{
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .image = ctx.image,
            .subresource_range = range,
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .src_queue_family_index = ctx.queue_family_index,
            .dst_queue_family_index = ctx.queue_family_index,
        };

        vkd().cmdPipelineBarrier(cmd, .{ .transfer_bit = true }, .{ .fragment_shader_bit = true }, .{}, 0, null, 0, null, 1, @ptrCast(&image_barrier));
    }
};

pub fn loadCubemap(
    device: *const vkk.Device,
    staging_buffer: Engine.AllocatedBuffer,
    immediate_context: Engine.ImmediateContext,
    filenames: [6][*:0]const u8,
) !Engine.AllocatedImage {
    const data = try vkd().mapMemory(device.handle, staging_buffer.memory, 0, vk.WHOLE_SIZE, .{});
    defer vkd().unmapMemory(device.handle, staging_buffer.memory);

    const gpu_ptr: [*]c.stbi_uc = @ptrCast(@alignCast(data));

    var extent: vk.Extent3D = undefined;

    var copy_regions = try std.BoundedArray(vk.BufferImageCopy, 32).init(0);
    var current_offset: usize = 0;
    for (filenames, 0..) |filename, i| {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var channels: c_int = undefined;

        const pixels = c.stbi_load(filename, &width, &height, &channels, c.STBI_rgb_alpha) orelse
            return error.TextureLoadingFailed;
        defer c.stbi_image_free(pixels);

        const image_size: usize = @intCast(width * height * 4);

        @memcpy(gpu_ptr[current_offset .. current_offset + image_size], pixels[0..image_size]);

        if (i == 0) {
            extent = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .depth = 1,
            };
        } else {
            assert(extent.width == @as(u32, @intCast(width)));
            assert(extent.height == @as(u32, @intCast(height)));
        }

        const copy_region = vk.BufferImageCopy{
            .buffer_offset = @intCast(current_offset),
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = @intCast(i),
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = extent,
        };
        try copy_regions.append(copy_region);

        current_offset += image_size;
    }

    const format: vk.Format = .r8g8b8a8_srgb;
    const image = try vk_utils.createImage(
        device.handle,
        device.physical_device,
        format,
        .{ .transfer_dst_bit = true, .sampled_bit = true },
        extent,
        .{ .device_local_bit = true },
        .{ .color_bit = true },
        .cube,
        6,
        .{ .cube_compatible_bit = true },
    );

    try Engine.immediateSubmit(device.handle, device.graphics_queue, immediate_context, ImageArrayCopy{
        .image = image.handle,
        .buffer = staging_buffer.handle,
        .queue_family_index = device.graphics_queue_index,
        .extent = extent,
        .layer_count = 6,
        .copy_regions = copy_regions.constSlice(),
    });

    return image;
}
