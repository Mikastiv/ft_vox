const std = @import("std");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const c = @import("c.zig");
const Window = @import("Window.zig");
const vk_init = @import("vk_init.zig");
const vk_utils = @import("vk_utils.zig");
const pipeline = @import("pipeline.zig");
const shaders = @import("shaders");
const mesh = @import("mesh.zig");

const assert = std.debug.assert;

const vki = vkk.dispatch.vki;
const vkd = vkk.dispatch.vkd;

const staging_buffer_size = 1024 * 1024 * 100;

pub const AllocatedImage = struct {
    handle: vk.Image,
    view: vk.ImageView,
    format: vk.Format,
    extent: vk.Extent3D,
    memory: vk.DeviceMemory,
};

pub const AllocatedBuffer = struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
};

const ImmediateContext = struct {
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    fence: vk.Fence,
};

const frame_overlap = 2;

const FrameData = struct {
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    swapchain_semaphore: vk.Semaphore,
    render_semaphore: vk.Semaphore,
    render_fence: vk.Fence,
};

window: *Window,
surface: vk.SurfaceKHR,
instance: vkk.Instance,
physical_device: vkk.PhysicalDevice,
device: vkk.Device,

swapchain: vkk.Swapchain,
swapchain_images: []vk.Image,
swapchain_image_views: []vk.ImageView,
depth_image: AllocatedImage,
framebuffers: []vk.Framebuffer,

frames: [frame_overlap]FrameData,

immediate_context: ImmediateContext,
render_pass: vk.RenderPass,
default_pipeline_layout: vk.PipelineLayout,
default_pipeline: vk.Pipeline,

staging_buffer: AllocatedBuffer,
vertex_buffer: AllocatedBuffer,

deletion_queue: vk_utils.DeletionQueue,

frame_number: u64 = 0,

pub fn init(allocator: std.mem.Allocator, window: *Window) !@This() {
    const instance = try vkk.Instance.create(c.glfwGetInstanceProcAddress, .{
        .app_name = "ft_vox",
        .app_version = 1,
        .engine_name = "engine",
        .engine_version = 1,
        .required_api_version = vk.API_VERSION_1_1,
    });
    errdefer instance.destroy();

    const surface = try window.createSurface(instance.handle);
    errdefer vki().destroySurfaceKHR(instance.handle, surface, null);

    const physical_device = try vkk.PhysicalDevice.select(&instance, .{
        .surface = surface,
        .preferred_type = .discrete_gpu,
    });

    const device = try vkk.Device.create(&physical_device, null, null);
    errdefer device.destroy();

    const swapchain = try vkk.Swapchain.create(&device, surface, .{
        .desired_extent = window.extent(),
        .desired_formats = &.{
            .{ .format = .b8g8r8a8_unorm, .color_space = .srgb_nonlinear_khr },
        },
        .desired_present_modes = &.{
            .fifo_khr,
        },
    });
    errdefer swapchain.destroy();

    const images = try allocator.alloc(vk.Image, swapchain.image_count);
    try swapchain.getImages(images);

    const image_views = try allocator.alloc(vk.ImageView, swapchain.image_count);
    try swapchain.getImageViews(images, image_views);
    errdefer vk_utils.destroyImageViews(device.handle, image_views);

    const depth_image = try createImage(
        device.handle,
        physical_device.handle,
        .d32_sfloat,
        .{ .depth_stencil_attachment_bit = true },
        .{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 },
        .{ .device_local_bit = true },
        .{ .depth_bit = true },
    );
    errdefer vk_utils.destroyImage(device.handle, depth_image);

    var deletion_queue = try vk_utils.DeletionQueue.init(allocator, 32);
    errdefer deletion_queue.flush(device.handle);

    const render_pass = try vk_utils.defaultRenderPass(device.handle, swapchain.image_format, depth_image.format);
    try deletion_queue.append(render_pass);

    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.image_count);
    try vk_utils.createFramebuffers(device.handle, render_pass, swapchain.extent, image_views, depth_image.view, framebuffers);
    errdefer vk_utils.destroyFrameBuffers(device.handle, framebuffers);

    const immediate_context = try createImmediateContext(device.handle, device.graphics_queue_index);
    try deletion_queue.append(immediate_context.fence);
    try deletion_queue.append(immediate_context.command_pool);

    const frames = try createFrameData(device.handle, device.graphics_queue_index, &deletion_queue);

    const default_pipeline_layout = try vkd().createPipelineLayout(device.handle, &.{}, null);
    try deletion_queue.append(default_pipeline_layout);

    const default_pipeline = try createDefaultPipeline(
        device.handle,
        default_pipeline_layout,
        render_pass,
        swapchain.image_format,
        depth_image.format,
    );
    try deletion_queue.append(default_pipeline);

    const staging_buffer = try createBuffer(
        device.handle,
        physical_device.handle,
        staging_buffer_size,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true },
    );
    try deletion_queue.appendBuffer(staging_buffer);

    const vertices = try allocator.alloc(mesh.Vertex, 36);
    const cube = mesh.generateCube(.{ .north = true }, vertices);
    const vertex_buffer = try createBuffer(
        device.handle,
        physical_device.handle,
        @sizeOf(mesh.Vertex) * cube.len,
        .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .{ .device_local_bit = true },
    );
    try deletion_queue.appendBuffer(vertex_buffer);

    assert(cube.len == 6);
    try uploadMesh(device.handle, device.graphics_queue, immediate_context, staging_buffer, vertex_buffer, cube);

    return .{
        .window = window,
        .surface = surface,
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .swapchain = swapchain,
        .swapchain_images = images,
        .swapchain_image_views = image_views,
        .depth_image = depth_image,
        .framebuffers = framebuffers,
        .render_pass = render_pass,
        .immediate_context = immediate_context,
        .deletion_queue = deletion_queue,
        .default_pipeline_layout = default_pipeline_layout,
        .default_pipeline = default_pipeline,
        .frames = frames,
        .staging_buffer = staging_buffer,
        .vertex_buffer = vertex_buffer,
    };
}

pub fn deinit(self: *@This()) void {
    self.deletion_queue.flush(self.device.handle);
    vk_utils.destroyFrameBuffers(self.device.handle, self.framebuffers);
    vk_utils.destroyImage(self.device.handle, self.depth_image);
    vk_utils.destroyImageViews(self.device.handle, self.swapchain_image_views);
    self.swapchain.destroy();
    self.device.destroy();
    vki().destroySurfaceKHR(self.instance.handle, self.surface, null);
    self.instance.destroy();
    self.window.deinit();
}

pub fn run(self: *@This()) !void {
    while (!self.window.shouldClose()) {
        c.glfwPollEvents();

        try self.draw();
    }

    try vkd().deviceWaitIdle(self.device.handle);
}

fn draw(self: *@This()) !void {
    const frame = self.currentFrame();
    const device = self.device.handle;
    const cmd = frame.command_buffer;

    const fence_result = try vkd().waitForFences(device, 1, @ptrCast(&frame.render_fence), vk.TRUE, std.time.ns_per_s);
    assert(fence_result == .success);

    try vkd().resetFences(device, 1, @ptrCast(&frame.render_fence));

    const next_image_result = try vkd().acquireNextImageKHR(
        device,
        self.swapchain.handle,
        std.time.ns_per_s,
        frame.swapchain_semaphore,
        .null_handle,
    );
    assert(next_image_result.result == .success);

    const image_index = next_image_result.image_index;

    try vkd().resetCommandPool(device, frame.command_pool, .{});

    const command_begin_info: vk.CommandBufferBeginInfo = .{ .flags = .{ .one_time_submit_bit = true } };
    try vkd().beginCommandBuffer(cmd, &command_begin_info);

    const clear_value = vk.ClearValue{ .color = .{ .float_32 = .{ 0.1, 0.1, 0.1, 1 } } };
    const depth_clear = vk.ClearValue{ .depth_stencil = .{ .depth = 0, .stencil = 0 } };
    const clear_values = [_]vk.ClearValue{ clear_value, depth_clear };

    const render_pass_info = vk_init.renderPassBeginInfo(
        self.render_pass,
        self.framebuffers[image_index],
        self.swapchain.extent,
        &clear_values,
    );
    vkd().cmdBeginRenderPass(cmd, &render_pass_info, .@"inline");

    vkd().cmdBindPipeline(cmd, .graphics, self.default_pipeline);

    const viewport: vk.Viewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(self.swapchain.extent.width),
        .height = @floatFromInt(self.swapchain.extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    vkd().cmdSetViewport(cmd, 0, 1, @ptrCast(&viewport));

    const scissor: vk.Rect2D = .{
        .extent = self.swapchain.extent,
        .offset = .{ .x = 0, .y = 0 },
    };
    vkd().cmdSetScissor(cmd, 0, 1, @ptrCast(&scissor));

    vkd().cmdBindVertexBuffers(cmd, 0, 1, @ptrCast(&self.vertex_buffer.handle), &[_]vk.DeviceSize{0});

    vkd().cmdDraw(cmd, 6, 1, 0, 0);

    vkd().cmdEndRenderPass(cmd);
    try vkd().endCommandBuffer(cmd);

    const wait_stage = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
    const submit = vk.SubmitInfo{
        .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&frame.swapchain_semaphore),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&frame.render_semaphore),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd),
    };
    try vkd().queueSubmit(self.device.graphics_queue, 1, @ptrCast(&submit), frame.render_fence);

    const present_info = vk.PresentInfoKHR{
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.swapchain.handle),
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&frame.render_semaphore),
        .p_image_indices = @ptrCast(&image_index),
    };
    const present_result = try vkd().queuePresentKHR(self.device.graphics_queue, &present_info);
    assert(present_result == .success);

    assert(self.frame_number != std.math.maxInt(u64));
    self.frame_number += 1;
}

fn uploadMesh(
    device: vk.Device,
    queue: vk.Queue,
    immediate_ctx: ImmediateContext,
    staging_buffer: AllocatedBuffer,
    dst_buffer: AllocatedBuffer,
    vertices: []const mesh.Vertex,
) !void {
    assert(device != .null_handle);
    assert(queue != .null_handle);
    assert(immediate_ctx.command_buffer != .null_handle);
    assert(immediate_ctx.command_pool != .null_handle);
    assert(immediate_ctx.fence != .null_handle);

    const size = @sizeOf(mesh.Vertex) * vertices.len;
    assert(size <= staging_buffer_size);

    {
        const data = try vkd().mapMemory(device, staging_buffer.memory, 0, size, .{});
        defer vkd().unmapMemory(device, staging_buffer.memory);

        const ptr: [*]mesh.Vertex = @ptrCast(@alignCast(data));
        @memcpy(ptr, vertices);
    }

    const MeshCopy = struct {
        staging_buffer: vk.Buffer,
        dst_buffer: vk.Buffer,
        size: vk.DeviceSize,

        fn recordCommands(ctx: @This(), cmd: vk.CommandBuffer) void {
            const copy = vk.BufferCopy{ .size = ctx.size, .src_offset = 0, .dst_offset = 0 };
            vkd().cmdCopyBuffer(cmd, ctx.staging_buffer, ctx.dst_buffer, 1, @ptrCast(&copy));
        }
    };

    try immediateSubmit(device, queue, immediate_ctx, MeshCopy{
        .staging_buffer = staging_buffer.handle,
        .dst_buffer = dst_buffer.handle,
        .size = size,
    });
}

fn currentFrame(self: *const @This()) *const FrameData {
    return &self.frames[self.frame_number % 2];
}

fn immediateSubmit(device: vk.Device, queue: vk.Queue, ctx: ImmediateContext, submit_ctx: anytype) !void {
    assert(device != .null_handle);
    assert(queue != .null_handle);
    assert(ctx.command_buffer != .null_handle);
    assert(ctx.command_pool != .null_handle);
    assert(ctx.fence != .null_handle);

    const cmd = ctx.command_buffer;

    const cmd_begin_info: vk.CommandBufferBeginInfo = .{ .flags = .{ .one_time_submit_bit = true } };
    try vkd().beginCommandBuffer(cmd, &cmd_begin_info);

    submit_ctx.recordCommands(cmd);

    try vkd().endCommandBuffer(cmd);

    const submit: vk.SubmitInfo = .{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&cmd) };
    try vkd().queueSubmit(queue, 1, @ptrCast(&submit), ctx.fence);

    const res = try vkd().waitForFences(device, 1, @ptrCast(&ctx.fence), vk.TRUE, std.time.ns_per_s);
    if (res != .success) return error.Timeout;

    try vkd().resetFences(device, 1, @ptrCast(&ctx.fence));

    try vkd().resetCommandPool(device, ctx.command_pool, .{});
}

fn createFrameData(
    device: vk.Device,
    queue_family_index: u32,
    deletion_queue: *vk_utils.DeletionQueue,
) ![frame_overlap]FrameData {
    assert(device != .null_handle);

    var frames: [frame_overlap]FrameData = undefined;

    const command_pool_info: vk.CommandPoolCreateInfo = .{ .queue_family_index = queue_family_index };
    const fence_info: vk.FenceCreateInfo = .{ .flags = .{ .signaled_bit = true } };
    const semaphore_info: vk.SemaphoreCreateInfo = .{};

    for (&frames) |*frame| {
        frame.command_pool = try vkd().createCommandPool(device, &command_pool_info, null);
        try deletion_queue.append(frame.command_pool);

        const command_buffer_info = vk_init.commandBufferAllocateInfo(frame.command_pool);
        try vkd().allocateCommandBuffers(device, &command_buffer_info, @ptrCast(&frame.command_buffer));

        frame.render_fence = try vkd().createFence(device, &fence_info, null);
        try deletion_queue.append(frame.render_fence);

        frame.render_semaphore = try vkd().createSemaphore(device, &semaphore_info, null);
        try deletion_queue.append(frame.render_semaphore);

        frame.swapchain_semaphore = try vkd().createSemaphore(device, &semaphore_info, null);
        try deletion_queue.append(frame.swapchain_semaphore);
    }

    return frames;
}

fn createDefaultPipeline(
    device: vk.Device,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
    image_format: vk.Format,
    depth_format: vk.Format,
) !vk.Pipeline {
    assert(device != .null_handle);
    assert(layout != .null_handle);
    assert(image_format != .undefined);
    assert(depth_format != .undefined);

    const vertex_shader = try vk_utils.createShaderModule(device, &shaders.triangle_vert);
    defer vkd().destroyShaderModule(device, vertex_shader, null);

    const fragment_shader = try vk_utils.createShaderModule(device, &shaders.triangle_frag);
    defer vkd().destroyShaderModule(device, fragment_shader, null);

    const builder = pipeline.Builder.init(.{
        .vertex_input_description = mesh.Vertex.getInputDescription(),
        .render_pass = render_pass,
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
        .layout = layout,
        .topology = .triangle_list,
        .polygon_mode = .fill,
        .cull_mode = .{},
        .front_face = .counter_clockwise,
        .enable_depth = true,
        .depth_compare_op = .greater_or_equal,
        .color_attachment_format = image_format,
        .depth_attachment_format = depth_format,
    });

    return builder.build(device);
}

fn createImmediateContext(device: vk.Device, graphics_family_index: u32) !ImmediateContext {
    assert(device != .null_handle);

    const fence_info: vk.FenceCreateInfo = .{};
    const fence = try vkd().createFence(device, &fence_info, null);
    errdefer vkd().destroyFence(device, fence, null);

    const command_pool_info: vk.CommandPoolCreateInfo = .{ .queue_family_index = graphics_family_index };
    const command_pool = try vkd().createCommandPool(device, &command_pool_info, null);
    errdefer vkd().destroyCommandPool(device, command_pool, null);

    const command_buffer_info = vk_init.commandBufferAllocateInfo(command_pool);
    var command_buffer: vk.CommandBuffer = undefined;
    try vkd().allocateCommandBuffers(device, &command_buffer_info, @ptrCast(&command_buffer));

    return .{
        .fence = fence,
        .command_pool = command_pool,
        .command_buffer = command_buffer,
    };
}

fn createBuffer(
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    property_flags: vk.MemoryPropertyFlags,
) !AllocatedBuffer {
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
    };
}

fn createImage(
    device: vk.Device,
    physical_device: vk.PhysicalDevice,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    extent: vk.Extent3D,
    property_flags: vk.MemoryPropertyFlags,
    aspect_flags: vk.ImageAspectFlags,
) !AllocatedImage {
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
