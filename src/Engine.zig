const std = @import("std");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const c = @import("c.zig");
const Window = @import("Window.zig");
const vk_init = @import("vk_init.zig");
const vk_utils = @import("vk_utils.zig");

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

render_pass: vk.RenderPass,
immediate_context: ImmediateContext,

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
    errdefer destroyImageViews(device.handle, image_views);

    var deletion_queue = try vk_utils.DeletionQueue.init(allocator, 32);
    errdefer deletion_queue.flush(device.handle);

    const depth_image = try createImage(
        &device,
        .d32_sfloat,
        .{ .depth_stencil_attachment_bit = true },
        .{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 },
        .{ .device_local_bit = true },
        .{ .depth_bit = true },
    );
    try deletion_queue.appendImage(depth_image);

    const render_pass = try defaultRenderPass(device.handle, swapchain.image_format, depth_image.format);
    try deletion_queue.append(render_pass);

    const immediate_context = try createImmediateContext(device.handle, device.graphics_queue_index);
    try deletion_queue.append(immediate_context.fence);
    try deletion_queue.append(immediate_context.command_pool);

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
    };
}

pub fn deinit(self: *@This()) void {
    self.deletion_queue.flush(self.device.handle);
    destroyImageViews(self.device.handle, self.swapchain_image_views);
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

pub fn createImage(
    device: *const vkk.Device,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    extent: vk.Extent3D,
    property_flags: vk.MemoryPropertyFlags,
    aspect_flags: vk.ImageAspectFlags,
) !AllocatedImage {
    const image_info = vk_init.imageCreateInfo(format, usage, extent);
    const image = try vkd().createImage(device.handle, &image_info, null);
    errdefer vkd().destroyImage(device.handle, image, null);

    const requirements = vkd().getImageMemoryRequirements(device.handle, image);
    const memory_properties = vki().getPhysicalDeviceMemoryProperties(device.physical_device);

    const memory_type = findMemoryType(
        memory_properties,
        requirements.memory_type_bits,
        property_flags,
    ) orelse return error.NoSuitableMemoryType;

    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = requirements.size,
        .memory_type_index = memory_type,
    };
    const memory = try vkd().allocateMemory(device.handle, &alloc_info, null);
    errdefer vkd().freeMemory(device.handle, memory, null);

    try vkd().bindImageMemory(device.handle, image, memory, 0);

    const image_view_info = vk_init.imageViewCreateInfo(format, image, aspect_flags);
    const image_view = try vkd().createImageView(device.handle, &image_view_info, null);
    errdefer vkd().destroyImageView(device.handle, image_view, null);

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

fn destroyImageViews(device: vk.Device, image_views: []vk.ImageView) void {
    assert(device != .null_handle);

    for (image_views) |view| {
        assert(view != .null_handle);
        vkd().destroyImageView(device, view, null);
    }
}

fn defaultRenderPass(device: vk.Device, image_format: vk.Format, depth_format: vk.Format) !vk.RenderPass {
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
