const std = @import("std");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const Engine = @import("Engine.zig");
const vk_init = @import("vk_init.zig");

const assert = std.debug.assert;

const vki = vkk.dispatch.vki;
const vkd = vkk.dispatch.vkd;

const HandleType = enum {
    image,
    image_view,
    fence,
    command_pool,
    memory,
    render_pass,
    pipeline_layout,
    pipeline,
    semaphore,
    buffer,
    descriptor_set_layout,
    descriptor_pool,
};

const DeletionEntry = struct {
    handle: usize,
    type: HandleType,
};

pub const DeletionQueue = struct {
    entries: std.ArrayList(DeletionEntry),

    pub fn init(allocator: std.mem.Allocator, initial_size: usize) !@This() {
        return .{
            .entries = try std.ArrayList(DeletionEntry).initCapacity(allocator, initial_size),
        };
    }

    pub fn append(self: *@This(), handle: anytype) !void {
        const T = @TypeOf(handle);
        const handle_type: HandleType = switch (T) {
            vk.Image => .image,
            vk.ImageView => .image_view,
            vk.Fence => .fence,
            vk.CommandPool => .command_pool,
            vk.DeviceMemory => .memory,
            vk.RenderPass => .render_pass,
            vk.PipelineLayout => .pipeline_layout,
            vk.Pipeline => .pipeline,
            vk.Semaphore => .semaphore,
            vk.Buffer => .buffer,
            vk.DescriptorSetLayout => .descriptor_set_layout,
            vk.DescriptorPool => .descriptor_pool,
            else => @compileError("unsupported type: " ++ @typeName(T)),
        };
        const handle_raw: usize = @intFromEnum(handle);
        assert(handle_raw != 0);

        try self.entries.append(.{ .handle = handle_raw, .type = handle_type });
    }

    pub fn appendImage(self: *@This(), image: Engine.AllocatedImage) !void {
        try self.append(image.handle);
        try self.append(image.memory);
        try self.append(image.view);
    }

    pub fn appendBuffer(self: *@This(), buffer: Engine.AllocatedBuffer) !void {
        try self.append(buffer.handle);
        try self.append(buffer.memory);
    }

    pub fn flush(self: *@This(), device: vk.Device) void {
        assert(device != .null_handle);

        var it = std.mem.reverseIterator(self.entries.items);
        while (it.next()) |entry| {
            switch (entry.type) {
                .image => vkd().destroyImage(device, @enumFromInt(entry.handle), null),
                .image_view => vkd().destroyImageView(device, @enumFromInt(entry.handle), null),
                .fence => vkd().destroyFence(device, @enumFromInt(entry.handle), null),
                .command_pool => vkd().destroyCommandPool(device, @enumFromInt(entry.handle), null),
                .memory => vkd().freeMemory(device, @enumFromInt(entry.handle), null),
                .render_pass => vkd().destroyRenderPass(device, @enumFromInt(entry.handle), null),
                .pipeline_layout => vkd().destroyPipelineLayout(device, @enumFromInt(entry.handle), null),
                .pipeline => vkd().destroyPipeline(device, @enumFromInt(entry.handle), null),
                .semaphore => vkd().destroySemaphore(device, @enumFromInt(entry.handle), null),
                .buffer => vkd().destroyBuffer(device, @enumFromInt(entry.handle), null),
                .descriptor_set_layout => vkd().destroyDescriptorSetLayout(device, @enumFromInt(entry.handle), null),
                .descriptor_pool => vkd().destroyDescriptorPool(device, @enumFromInt(entry.handle), null),
            }
        }
        self.entries.clearRetainingCapacity();
    }
};

pub fn createShaderModule(device: vk.Device, bytecode: []align(4) const u8) !vk.ShaderModule {
    assert(device != .null_handle);

    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = bytecode.len,
        .p_code = std.mem.bytesAsSlice(u32, bytecode).ptr,
    };

    return vkd().createShaderModule(device, &create_info, null);
}

pub fn destroyImageViews(device: vk.Device, image_views: []const vk.ImageView) void {
    assert(device != .null_handle);

    for (image_views) |view| {
        assert(view != .null_handle);
        vkd().destroyImageView(device, view, null);
    }
}

pub fn defaultRenderPass(device: vk.Device, image_format: vk.Format, depth_format: vk.Format) !vk.RenderPass {
    assert(device != .null_handle);
    assert(image_format != .undefined);
    assert(depth_format != .undefined);

    const color_attachment = vk.AttachmentDescription{
        .format = image_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const depth_attachment = vk.AttachmentDescription{
        .format = depth_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .depth_stencil_attachment_optimal,
    };

    const depth_attachment_ref = vk.AttachmentReference{
        .attachment = 1,
        .layout = .depth_stencil_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment_ref),
        .p_depth_stencil_attachment = @ptrCast(&depth_attachment_ref),
    };

    const dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
    };

    const depth_dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true },
    };

    const attachments = [_]vk.AttachmentDescription{ color_attachment, depth_attachment };
    const dependencies = [_]vk.SubpassDependency{ dependency, depth_dependency };
    const render_pass_info = vk.RenderPassCreateInfo{
        .attachment_count = attachments.len,
        .p_attachments = &attachments,
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = dependencies.len,
        .p_dependencies = &dependencies,
    };

    return vkd().createRenderPass(device, &render_pass_info, null);
}

pub fn createFramebuffers(
    device: vk.Device,
    render_pass: vk.RenderPass,
    extent: vk.Extent2D,
    image_views: []const vk.ImageView,
    depth_image_view: vk.ImageView,
    buffer: []vk.Framebuffer,
) !void {
    assert(device != .null_handle);
    assert(render_pass != .null_handle);
    assert(extent.width > 0);
    assert(extent.height > 0);
    assert(buffer.len == image_views.len);
    for (image_views) |view| assert(view != .null_handle);
    assert(depth_image_view != .null_handle);

    var initialized_count: u32 = 0;
    errdefer {
        for (0..initialized_count) |i| {
            vkd().destroyFramebuffer(device, buffer[i], null);
        }
    }

    var framebuffer_info = vk.FramebufferCreateInfo{
        .render_pass = render_pass,
        .width = extent.width,
        .height = extent.height,
        .layers = 1,
    };

    for (0..image_views.len) |i| {
        const attachments = [_]vk.ImageView{ image_views[i], depth_image_view };
        framebuffer_info.attachment_count = attachments.len;
        framebuffer_info.p_attachments = &attachments;
        buffer[i] = try vkd().createFramebuffer(device, &framebuffer_info, null);
        initialized_count += 1;
    }
}

pub fn destroyImage(device: vk.Device, image: Engine.AllocatedImage) void {
    vkd().destroyImageView(device, image.view, null);
    vkd().destroyImage(device, image.handle, null);
    vkd().freeMemory(device, image.memory, null);
}

pub fn destroyFrameBuffers(device: vk.Device, framebuffers: []const vk.Framebuffer) void {
    for (framebuffers) |framebuffer| {
        vkd().destroyFramebuffer(device, framebuffer, null);
    }
}

pub fn scale(comptime T: type, value: T, factor: f32) T {
    if (@typeInfo(T) != .Int) @compileError("only integer");

    const value_f32: f32 = @floatFromInt(value);
    const scaled = value_f32 * factor;
    return @intFromFloat(scaled);
}

pub fn createBuffer(
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    property_flags: vk.MemoryPropertyFlags,
) !Engine.AllocatedBuffer {
    assert(device != .null_handle);
    assert(physical_device != .null_handle);

    const create_info: vk.BufferCreateInfo = .{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    };
    const buffer = try vkd().createBuffer(device, &create_info, null);
    errdefer vkd().destroyBuffer(device, buffer, null);

    const requirements = vkd().getBufferMemoryRequirements(device, buffer);
    const memory_properties = vki().getPhysicalDeviceMemoryProperties(physical_device);

    const memory_type = findMemoryType(
        memory_properties,
        requirements.memory_type_bits,
        property_flags,
    ) orelse return error.NoSuitableMemoryType;

    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    };
    const memory = try vkd().allocateMemory(device, &alloc_info, null);
    errdefer vkd().freeMemory(device, memory, null);

    try vkd().bindBufferMemory(device, buffer, memory, 0);

    return .{
        .handle = buffer,
        .memory = memory,
        .size = size,
    };
}

pub fn createImage(
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    extent: vk.Extent3D,
    property_flags: vk.MemoryPropertyFlags,
    aspect_flags: vk.ImageAspectFlags,
) !Engine.AllocatedImage {
    assert(device != .null_handle);
    assert(physical_device != .null_handle);
    assert(format != .undefined);

    const image_info = vk_init.imageCreateInfo(format, usage, extent);
    const image = try vkd().createImage(device, &image_info, null);
    errdefer vkd().destroyImage(device, image, null);

    const requirements = vkd().getImageMemoryRequirements(device, image);
    const memory_properties = vki().getPhysicalDeviceMemoryProperties(physical_device);

    const memory_type = findMemoryType(
        memory_properties,
        requirements.memory_type_bits,
        property_flags,
    ) orelse return error.NoSuitableMemoryType;

    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    };
    const memory = try vkd().allocateMemory(device, &alloc_info, null);
    errdefer vkd().freeMemory(device, memory, null);

    try vkd().bindImageMemory(device, image, memory, 0);

    const image_view_info = vk_init.imageViewCreateInfo(format, image, aspect_flags);
    const image_view = try vkd().createImageView(device, &image_view_info, null);
    errdefer vkd().destroyImageView(device, image_view, null);

    return .{
        .handle = image,
        .view = image_view,
        .format = format,
        .extent = extent,
        .memory = memory,
    };
}

fn findMemoryType(
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    type_filter: u32,
    properties: vk.MemoryPropertyFlags,
) ?u32 {
    for (0..memory_properties.memory_type_count) |i| {
        const memory_type = memory_properties.memory_types[i];
        const property_flags = memory_type.property_flags;
        const mask = @as(u32, 1) << @intCast(i);
        if (type_filter & mask != 0 and property_flags.contains(properties)) {
            return @intCast(i);
        }
    }

    return null;
}
