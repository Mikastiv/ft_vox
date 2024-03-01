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
const math = @import("math.zig");
const descriptor = @import("descriptor.zig");
const texture = @import("texture.zig");
const Block = @import("Block.zig");
const Chunk = @import("Chunk.zig");
const Camera = @import("Camera.zig");

const assert = std.debug.assert;

const vki = vkk.dispatch.vki;
const vkd = vkk.dispatch.vkd;

const staging_buffer_size = 1024 * 1024 * 100;

const GpuSceneData = extern struct {
    view: math.Mat4 = math.mat.identity(math.Mat4),
    proj: math.Mat4 = math.mat.identity(math.Mat4),
    view_proj: math.Mat4 = math.mat.identity(math.Mat4),
};

const GpuPushConstants = extern struct {
    model: math.Mat4 = math.mat.identity(math.Mat4),
};

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
    size: vk.DeviceSize,
};

pub const ImmediateContext = struct {
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
index_buffer: AllocatedBuffer,
scene_data_buffer: AllocatedBuffer,

vertices: std.ArrayList(mesh.Vertex),
indices: std.ArrayList(u16),
rotation: math.Vec3 = .{ 0, 0, 0 },
camera: Camera,

descriptor_set: vk.DescriptorSet,
scene_data: GpuSceneData = .{},
texture_atlas: AllocatedImage,
nearest_sampler: vk.Sampler,

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
        .required_features = .{
            .fill_mode_non_solid = vk.TRUE,
        },
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

    const depth_image = try vk_utils.createImage(
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

    var descriptor_layout_builder = try descriptor.LayoutBuilder.init(allocator, 10);
    try descriptor_layout_builder.addBinding(0, .uniform_buffer_dynamic);
    try descriptor_layout_builder.addBinding(1, .combined_image_sampler);
    const descriptor_layout = try descriptor_layout_builder.build(device.handle, .{ .vertex_bit = true, .fragment_bit = true });
    try deletion_queue.append(descriptor_layout);

    const push_constant_range: vk.PushConstantRange = .{
        .offset = 0,
        .size = @sizeOf(GpuPushConstants),
        .stage_flags = .{ .vertex_bit = true },
    };
    const default_pipeline_layout = try vkd().createPipelineLayout(
        device.handle,
        &.{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_constant_range),
        },
        null,
    );
    try deletion_queue.append(default_pipeline_layout);

    const default_pipeline = try createDefaultPipeline(
        device.handle,
        default_pipeline_layout,
        render_pass,
        swapchain.image_format,
        depth_image.format,
    );
    try deletion_queue.append(default_pipeline);

    const staging_buffer = try vk_utils.createBuffer(
        device.handle,
        physical_device.handle,
        staging_buffer_size,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true },
    );
    try deletion_queue.appendBuffer(staging_buffer);

    const texture_atlas = try texture.loadFromFile(&device, staging_buffer, immediate_context, "assets/atlas.png");
    try deletion_queue.appendImage(texture_atlas);

    const nearest_sampler_info = vk_init.samplerCreateInfo(.nearest);
    const nearest_sampler = try vkd().createSampler(device.handle, &nearest_sampler_info, null);
    try deletion_queue.append(nearest_sampler);

    var vertices = try std.ArrayList(mesh.Vertex).initCapacity(allocator, Chunk.block_count * 24);
    var indices = try std.ArrayList(u16).initCapacity(allocator, Chunk.block_count * 36);

    const chunk = try allocator.create(Chunk);
    chunk.blocks = std.mem.zeroes(@TypeOf(chunk.blocks));

    for (0..16) |z| {
        for (0..2) |y| {
            for (0..16) |x| {
                chunk.setBlock(x, y, z, .grass);
            }
        }
    }
    try chunk.generateMesh(&vertices, &indices);

    const vertex_buffer = try vk_utils.createBuffer(
        device.handle,
        physical_device.handle,
        @sizeOf(mesh.Vertex) * vertices.items.len,
        .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .{ .device_local_bit = true },
    );
    try deletion_queue.appendBuffer(vertex_buffer);

    const index_buffer = try vk_utils.createBuffer(
        device.handle,
        physical_device.handle,
        @sizeOf(u16) * indices.items.len,
        .{ .transfer_dst_bit = true, .index_buffer_bit = true },
        .{ .device_local_bit = true },
    );
    try deletion_queue.appendBuffer(index_buffer);

    try uploadMesh(device.handle, device.graphics_queue, immediate_context, staging_buffer, vertex_buffer, index_buffer, vertices.items, indices.items);

    const min_alignment = physical_device.properties.limits.min_uniform_buffer_offset_alignment;
    assert(min_alignment > 0);

    const global_scene_data_size = std.mem.alignForward(vk.DeviceSize, @sizeOf(GpuSceneData), min_alignment) * frame_overlap;
    const scene_data_buffer = try vk_utils.createBuffer(
        device.handle,
        physical_device.handle,
        global_scene_data_size,
        .{ .uniform_buffer_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    try deletion_queue.appendBuffer(scene_data_buffer);

    const ratios = [_]descriptor.Allocator.PoolSizeRatio{
        .{ .type = .uniform_buffer_dynamic, .ratio = 0.5 },
        .{ .type = .combined_image_sampler, .ratio = 0.5 },
    };
    var descriptor_allocator = try descriptor.Allocator.init(allocator, device.handle, 10, &ratios);
    try deletion_queue.append(descriptor_allocator.pool);

    const descriptor_set = try descriptor_allocator.alloc(device.handle, descriptor_layout);

    var writer = descriptor.Writer.init(allocator);
    try writer.writeBuffer(0, scene_data_buffer.handle, @sizeOf(GpuSceneData), 0, .uniform_buffer_dynamic);
    try writer.writeImage(1, texture_atlas.view, .shader_read_only_optimal, nearest_sampler, .combined_image_sampler);
    writer.updateSet(device.handle, descriptor_set);

    var self: @This() = .{
        .window = window,
        .camera = Camera.init(.{ 0, 4, 0 }),
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
        .vertices = vertices,
        .indices = indices,
        .staging_buffer = staging_buffer,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .scene_data_buffer = scene_data_buffer,
        .descriptor_set = descriptor_set,
        .texture_atlas = texture_atlas,
        .nearest_sampler = nearest_sampler,
    };

    try self.initImGui();

    return self;
}

pub fn deinit(self: *@This()) void {
    c.cImGui_ImplVulkan_Shutdown();
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

        self.renderImGuiFrame();
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

    self.scene_data.view = self.camera.viewMatrix();
    self.scene_data.proj = math.mat.perspective(std.math.degreesToRadians(f32, 70), self.window.aspectRatio(), 10000, 0.1);
    self.scene_data.view_proj = math.mat.mul(&self.scene_data.proj, &self.scene_data.view);

    const alignment = std.mem.alignForward(vk.DeviceSize, @sizeOf(GpuSceneData), self.physical_device.properties.limits.min_uniform_buffer_offset_alignment);
    const frame_index = self.frame_number % frame_overlap;
    const uniform_offset: u32 = @intCast(alignment * frame_index);
    {
        const data = try vkd().mapMemory(self.device.handle, self.scene_data_buffer.memory, 0, vk.WHOLE_SIZE, .{});
        defer vkd().unmapMemory(self.device.handle, self.scene_data_buffer.memory);

        const ptr: [*]u8 = @ptrCast(@alignCast(data));
        @memcpy(ptr[uniform_offset .. uniform_offset + @sizeOf(GpuSceneData)], std.mem.asBytes(&self.scene_data));
    }

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
    vkd().cmdBindIndexBuffer(cmd, self.index_buffer.handle, 0, .uint16);
    vkd().cmdBindDescriptorSets(cmd, .graphics, self.default_pipeline_layout, 0, 1, @ptrCast(&self.descriptor_set), 1, @ptrCast(&uniform_offset));

    var model = math.mat.identity(math.Mat4);
    model = math.mat.translate(&model, .{ 0, -2, 0 });
    model = math.mat.rotate(&model, std.math.degreesToRadians(f32, self.rotation[0]), .{ 1, 0, 0 });
    model = math.mat.rotate(&model, std.math.degreesToRadians(f32, self.rotation[1]), .{ 0, 1, 0 });
    model = math.mat.rotate(&model, std.math.degreesToRadians(f32, self.rotation[2]), .{ 0, 0, 1 });
    const push_constants: GpuPushConstants = .{
        .model = model,
    };
    vkd().cmdPushConstants(cmd, self.default_pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(GpuPushConstants), @ptrCast(&push_constants));

    vkd().cmdDrawIndexed(cmd, @intCast(self.indices.items.len), 1, 0, 0, 0);

    c.cImGui_ImplVulkan_RenderDrawData(c.ImGui_GetDrawData(), c.vkZigHandleToC(c.VkCommandBuffer, cmd));

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

fn renderImGuiFrame(self: *@This()) void {
    c.cImGui_ImplVulkan_NewFrame();
    c.cImGui_ImplGlfw_NewFrame();
    c.ImGui_NewFrame();

    if (c.ImGui_Begin("model", null, c.ImGuiWindowFlags_None)) {
        _ = c.ImGui_SliderFloat3("rotation", @ptrCast(&self.rotation), 0, 360);

        c.ImGui_End();
    }

    c.ImGui_Render();
}

fn uploadMesh(
    device: vk.Device,
    queue: vk.Queue,
    immediate_ctx: ImmediateContext,
    staging_buffer: AllocatedBuffer,
    vertex_buffer: AllocatedBuffer,
    index_buffer: AllocatedBuffer,
    vertices: []const mesh.Vertex,
    indices: []const u16,
) !void {
    assert(device != .null_handle);
    assert(queue != .null_handle);
    assert(vertex_buffer.handle != .null_handle);
    assert(vertex_buffer.memory != .null_handle);
    assert(index_buffer.handle != .null_handle);
    assert(index_buffer.memory != .null_handle);
    assert(immediate_ctx.command_buffer != .null_handle);
    assert(immediate_ctx.command_pool != .null_handle);
    assert(immediate_ctx.fence != .null_handle);

    const vertex_size = @sizeOf(mesh.Vertex) * vertices.len;
    const index_size = @sizeOf(u16) * indices.len;
    assert(vertex_size + index_size <= staging_buffer_size);

    {
        const data = try vkd().mapMemory(device, staging_buffer.memory, 0, vertex_size + index_size, .{});
        defer vkd().unmapMemory(device, staging_buffer.memory);

        const ptr: [*]u8 = @ptrCast(@alignCast(data));
        @memcpy(ptr[0..vertex_size], std.mem.sliceAsBytes(vertices));
        @memcpy(ptr[vertex_size .. vertex_size + index_size], std.mem.sliceAsBytes(indices));
    }

    const MeshCopy = struct {
        staging_buffer: vk.Buffer,
        vertex_buffer: vk.Buffer,
        vertex_size: vk.DeviceSize,
        index_buffer: vk.Buffer,
        index_size: vk.DeviceSize,

        fn recordCommands(ctx: @This(), cmd: vk.CommandBuffer) void {
            const vertex_copy = vk.BufferCopy{ .size = ctx.vertex_size, .src_offset = 0, .dst_offset = 0 };
            vkd().cmdCopyBuffer(cmd, ctx.staging_buffer, ctx.vertex_buffer, 1, @ptrCast(&vertex_copy));

            const index_copy = vk.BufferCopy{ .size = ctx.index_size, .src_offset = ctx.vertex_size, .dst_offset = 0 };
            vkd().cmdCopyBuffer(cmd, ctx.staging_buffer, ctx.index_buffer, 1, @ptrCast(&index_copy));
        }
    };

    try immediateSubmit(device, queue, immediate_ctx, MeshCopy{
        .staging_buffer = staging_buffer.handle,
        .vertex_buffer = vertex_buffer.handle,
        .vertex_size = vertex_size,
        .index_buffer = index_buffer.handle,
        .index_size = index_size,
    });
}

fn currentFrame(self: *const @This()) *const FrameData {
    return &self.frames[self.frame_number % 2];
}

pub fn immediateSubmit(device: vk.Device, queue: vk.Queue, ctx: ImmediateContext, submit_ctx: anytype) !void {
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

fn initImGui(self: *@This()) !void {
    const pool = try createImguiDescriptorPool(self.device.handle);
    try self.deletion_queue.append(pool);

    _ = c.ImGui_CreateContext(null);
    if (!c.cImGui_ImplGlfw_InitForVulkan(self.window.handle, true)) return error.ImGuiInitFailed;

    var init_info = c.ImGui_ImplVulkan_InitInfo{
        .Instance = c.vkZigHandleToC(c.VkInstance, self.instance.handle),
        .PhysicalDevice = c.vkZigHandleToC(c.VkPhysicalDevice, self.physical_device.handle),
        .Device = c.vkZigHandleToC(c.VkDevice, self.device.handle),
        .Queue = c.vkZigHandleToC(c.VkQueue, self.device.graphics_queue),
        .DescriptorPool = c.vkZigHandleToC(c.VkDescriptorPool, pool),
        .MinImageCount = self.swapchain.image_count,
        .ImageCount = self.swapchain.image_count,
        .MSAASamples = c.VK_SAMPLE_COUNT_1_BIT,
        .RenderPass = c.vkZigHandleToC(c.VkRenderPass, self.render_pass),
    };

    if (!c.cImGui_ImplVulkan_Init(@ptrCast(&init_info))) return error.ImGuiInitFailed;
    if (!c.cImGui_ImplVulkan_CreateFontsTexture()) return error.ImGuiInitFailed;
}

fn createImguiDescriptorPool(device: vk.Device) !vk.DescriptorPool {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .sampler, .descriptor_count = 1000 },
        .{ .type = .combined_image_sampler, .descriptor_count = 1000 },
        .{ .type = .sampled_image, .descriptor_count = 1000 },
        .{ .type = .storage_image, .descriptor_count = 1000 },
        .{ .type = .uniform_texel_buffer, .descriptor_count = 1000 },
        .{ .type = .storage_texel_buffer, .descriptor_count = 1000 },
        .{ .type = .uniform_buffer, .descriptor_count = 1000 },
        .{ .type = .storage_buffer, .descriptor_count = 1000 },
        .{ .type = .uniform_buffer_dynamic, .descriptor_count = 1000 },
        .{ .type = .storage_buffer_dynamic, .descriptor_count = 1000 },
        .{ .type = .input_attachment, .descriptor_count = 1000 },
    };

    const pool_info = vk.DescriptorPoolCreateInfo{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = 1000,
        .pool_size_count = @intCast(pool_sizes.len),
        .p_pool_sizes = &pool_sizes,
    };

    return vkd().createDescriptorPool(device, &pool_info, null);
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
        .cull_mode = .{ .back_bit = true },
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
