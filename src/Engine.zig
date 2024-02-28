const std = @import("std");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const c = @import("c.zig");
const Window = @import("Window.zig");
const vk_init = @import("vk_init.zig");
const vk_utils = @import("vk_utils.zig");
const pipeline = @import("pipeline.zig");
const shaders = @import("shaders");

const assert = std.debug.assert;

const vki = vkk.dispatch.vki;
const vkd = vkk.dispatch.vkd;

pub const AllocatedImage = struct {
    handle: vk.Image,
    view: vk.ImageView,
    format: vk.Format,
    extent: vk.Extent3D,
    memory: vk.DeviceMemory,
};

const ImmediateContext = struct {
    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,
    fence: vk.Fence,
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

immediate_context: ImmediateContext,
render_pass: vk.RenderPass,
default_pipeline_layout: vk.PipelineLayout,
default_pipeline: vk.Pipeline,

deletion_queue: vk_utils.DeletionQueue,

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

    const image_views = try allocator.alloc(vk.ImageView, images.len);
    try swapchain.getImageViews(images, image_views);
    errdefer vk_utils.destroyImageViews(device.handle, image_views);

    var deletion_queue = try vk_utils.DeletionQueue.init(allocator, 32);
    errdefer deletion_queue.flush(device.handle);

    const depth_image = try createImage(
        device.handle,
        physical_device.handle,
        .d32_sfloat,
        .{ .depth_stencil_attachment_bit = true },
        .{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 },
        .{ .device_local_bit = true },
        .{ .depth_bit = true },
    );
    try deletion_queue.appendImage(depth_image);

    const render_pass = try vk_utils.defaultRenderPass(device.handle, swapchain.image_format, depth_image.format);
    try deletion_queue.append(render_pass);

    const immediate_context = try createImmediateContext(device.handle, device.graphics_queue_index);
    try deletion_queue.append(immediate_context.fence);
    try deletion_queue.append(immediate_context.command_pool);

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
        .render_pass = render_pass,
        .immediate_context = immediate_context,
        .deletion_queue = deletion_queue,
        .default_pipeline_layout = default_pipeline_layout,
        .default_pipeline = default_pipeline,
    };
}

pub fn deinit(self: *@This()) void {
    self.deletion_queue.flush(self.device.handle);
    vk_utils.destroyImageViews(self.device.handle, self.swapchain_image_views);
    self.swapchain.destroy();
    self.device.destroy();
    vki().destroySurfaceKHR(self.instance.handle, self.surface, null);
    self.instance.destroy();
    self.window.deinit();
}

pub fn run(self: *@This()) !void {
    _ = self;
}

fn immediateSubmit(device: vk.Device, queue: vk.Queue, ctx: ImmediateContext, submit_ctx: anytype) !void {
    assert(device != .null_handle);
    assert(queue != .null_handle);
    assert(ctx.command_buffer != .null_handle);
    assert(ctx.command_pool != .null_handle);
    assert(ctx.fence != .null_handle);

    const cmd = ctx.command_buffer;

    const cmd_begin_info = vk_init.commandBufferBeginInfo(.{ .one_time_submit_bit = true });
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
