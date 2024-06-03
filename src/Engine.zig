const std = @import("std");
const vk = @import("vulkan");
const vkk = @import("vk-kickstart");
const c = @import("c.zig");
const Window = @import("Window.zig");
const vk_init = @import("vk_init.zig");
const vk_utils = @import("vk_utils.zig");
const pipeline = @import("pipeline.zig");
const shaders = @import("shaders");
const mesh = @import("mesh.zig");
const math = @import("mksv").math;
const descriptor = @import("descriptor.zig");
const texture = @import("texture.zig");
const Block = @import("Block.zig");
const Chunk = @import("Chunk.zig");
const Camera = @import("Camera.zig");
const World = @import("World.zig");
const Skybox = @import("Skybox.zig");
const GraphicsContext = @import("GraphicsContext.zig");

const assert = std.debug.assert;

pub const staging_buffer_size = 1024 * 1024 * 100;

const mouse_sensivity = 15.0;
const move_speed = 8.0;

const ns_per_tick: comptime_int = @intFromFloat(std.time.ns_per_ms * 16.6);
const delta_time_fixed = @as(comptime_float, ns_per_tick) / @as(comptime_float, std.time.ns_per_s);

const global_vertex_buffer_size = Chunk.vertex_buffer_size * World.max_loaded_chunks;
const global_index_buffer_size = Chunk.index_buffer_size * World.max_loaded_chunks;

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

pub const AllocatedMemory = struct {
    handle: vk.DeviceMemory,
    size: vk.DeviceSize,
    alignment: vk.DeviceSize,
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
ctx: GraphicsContext,

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
skybox: Skybox,

staging_buffer: AllocatedBuffer,
scene_data_buffer: AllocatedBuffer,

world: World,
camera: Camera,

descriptor_set: vk.DescriptorSet,
scene_data: GpuSceneData = .{},
block_textures: AllocatedImage,
nearest_sampler: vk.Sampler,
linear_sampler: vk.Sampler,

deletion_queue: vk_utils.DeletionQueue,

frame_number: u64 = 0,
fps: f32 = 0,
chunk_upload_history: [128]u64 = .{0} ** 128,
chunk_upload_current: usize = 0,
timer: std.time.Timer,
prev_dir: math.Vec3 = .{ 0, 0, 0 },

swapchain_resize_requested: bool = false,

pub fn init(allocator: std.mem.Allocator, window: *Window) !@This() {
    const ctx = try GraphicsContext.init(allocator, window);

    const swapchain = try vkk.Swapchain.create(ctx.device.handle, ctx.physical_device.handle, ctx.surface, .{
        .graphics_queue_index = ctx.graphics_queue_index,
        .present_queue_index = ctx.present_queue_index,
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
    errdefer vk_utils.destroyImageViews(&ctx, image_views);

    const depth_image = try createDepthImage(&ctx, .d32_sfloat, swapchain.extent);
    errdefer vk_utils.destroyImage(&ctx, depth_image);

    var deletion_queue = try vk_utils.DeletionQueue.init(allocator, 32);
    errdefer deletion_queue.flush(&ctx);

    const render_pass = try vk_utils.defaultRenderPass(&ctx, swapchain.image_format, depth_image.format);
    try deletion_queue.append(render_pass);

    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.image_count);
    try vk_utils.createFramebuffers(&ctx, render_pass, swapchain.extent, image_views, depth_image.view, framebuffers);
    errdefer vk_utils.destroyFrameBuffers(&ctx, framebuffers);

    const immediate_context = try createImmediateContext(&ctx, ctx.graphics_queue_index);
    try deletion_queue.append(immediate_context.fence);
    try deletion_queue.append(immediate_context.command_pool);

    const frames = try createFrameData(&ctx, &deletion_queue);

    var descriptor_layout_builder = try descriptor.LayoutBuilder.init(allocator, 10);
    try descriptor_layout_builder.addBinding(0, .uniform_buffer_dynamic);
    try descriptor_layout_builder.addBinding(1, .combined_image_sampler);
    const descriptor_layout = try descriptor_layout_builder.build(&ctx, .{ .vertex_bit = true, .fragment_bit = true });
    try deletion_queue.append(descriptor_layout);

    const push_constant_range: vk.PushConstantRange = .{
        .offset = 0,
        .size = @sizeOf(GpuPushConstants),
        .stage_flags = .{ .vertex_bit = true },
    };
    const default_pipeline_layout = try ctx.device.createPipelineLayout(
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
        &ctx,
        default_pipeline_layout,
        render_pass,
        swapchain.image_format,
        depth_image.format,
    );
    try deletion_queue.append(default_pipeline);

    const staging_buffer = try vk_utils.createBuffer(
        &ctx,
        staging_buffer_size,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true },
    );
    try deletion_queue.appendBuffer(staging_buffer);

    const block_textures = try texture.loadBlockTextures(&ctx, staging_buffer, immediate_context);
    try deletion_queue.appendImage(block_textures);

    const nearest_sampler_info = vk_init.samplerCreateInfo(.nearest);
    const nearest_sampler = try ctx.device.createSampler(&nearest_sampler_info, null);
    try deletion_queue.append(nearest_sampler);

    var linear_sampler_info = vk_init.samplerCreateInfo(.linear);
    if (ctx.physical_device.features.sampler_anisotropy == vk.TRUE) {
        linear_sampler_info.anisotropy_enable = vk.TRUE;
        linear_sampler_info.max_anisotropy = ctx.physical_device.properties.limits.max_sampler_anisotropy;
    }
    const linear_sampler = try ctx.device.createSampler(&linear_sampler_info, null);
    try deletion_queue.append(linear_sampler);

    const ratios = [_]descriptor.Allocator.PoolSizeRatio{
        .{ .type = .uniform_buffer_dynamic, .ratio = 0.5 },
        .{ .type = .combined_image_sampler, .ratio = 0.5 },
    };
    var descriptor_allocator = try descriptor.Allocator.init(allocator, &ctx, 10, &ratios);
    try deletion_queue.append(descriptor_allocator.pool);

    const skybox = try Skybox.init(
        &ctx,
        descriptor_layout,
        render_pass,
        swapchain.image_format,
        staging_buffer,
        immediate_context,
        &descriptor_allocator,
        &deletion_queue,
    );

    const vertex_buffer_info: vk.BufferCreateInfo = .{
        .size = global_vertex_buffer_size,
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    };
    const vertex_buffer_ref = try ctx.device.createBuffer(&vertex_buffer_info, null);
    defer ctx.device.destroyBuffer(vertex_buffer_ref, null);

    const vertex_buffer_memory = try vk_utils.allocateMemory(&ctx, vertex_buffer_ref, .{ .device_local_bit = true });
    try deletion_queue.append(vertex_buffer_memory.handle);

    const index_buffer_info: vk.BufferCreateInfo = .{
        .size = global_index_buffer_size,
        .usage = .{ .transfer_dst_bit = true, .index_buffer_bit = true },
        .sharing_mode = .exclusive,
    };
    const index_buffer_ref = try ctx.device.createBuffer(&index_buffer_info, null);
    defer ctx.device.destroyBuffer(index_buffer_ref, null);

    const index_buffer_memory = try vk_utils.allocateMemory(&ctx, index_buffer_ref, .{ .device_local_bit = true });
    try deletion_queue.append(index_buffer_memory.handle);

    std.log.info(
        "index buffers: size: {:.2}, alignment: {d}",
        .{ std.fmt.fmtIntSizeBin(index_buffer_memory.size), index_buffer_memory.alignment },
    );

    std.log.info(
        "vertex buffers: size: {:.2}, alignment: {d}",
        .{ std.fmt.fmtIntSizeBin(vertex_buffer_memory.size), vertex_buffer_memory.alignment },
    );

    var world = try World.init(allocator, &ctx, vertex_buffer_memory, index_buffer_memory, &deletion_queue);

    for (0..World.chunk_radius * 2) |j| {
        for (0..World.chunk_radius * 2) |i| {
            for (0..World.chunk_radius * 2) |k| {
                const x: i32 = @intCast(i);
                const y: i32 = @intCast(j);
                const z: i32 = @intCast(k);
                const pos: math.Vec3i = .{
                    @intCast(x - World.chunk_radius),
                    @intCast(y - World.chunk_radius),
                    @intCast(z - World.chunk_radius),
                };
                if (math.vec.length2(pos) < World.chunk_radius * World.chunk_radius) {
                    try world.addChunk(pos);
                }
            }
        }
    }

    while (world.upload_queue.len > 0) {
        const cmd = try beginImmediateSubmit(&ctx, immediate_context);
        _ = try world.uploadChunkFromQueue(&ctx, cmd, staging_buffer);
        try endImmediateSubmit(&ctx, immediate_context, cmd);
    }

    const min_alignment = ctx.physical_device.properties.limits.min_uniform_buffer_offset_alignment;
    assert(min_alignment > 0);

    const global_scene_data_size = std.mem.alignForward(vk.DeviceSize, @sizeOf(GpuSceneData), min_alignment) * frame_overlap;
    const scene_data_buffer = try vk_utils.createBuffer(
        &ctx,
        global_scene_data_size,
        .{ .uniform_buffer_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    try deletion_queue.appendBuffer(scene_data_buffer);

    const descriptor_set = try descriptor_allocator.alloc(&ctx, descriptor_layout);

    var writer = descriptor.Writer.init(allocator);
    try writer.writeBuffer(0, scene_data_buffer.handle, @sizeOf(GpuSceneData), 0, .uniform_buffer_dynamic);
    try writer.writeImage(1, block_textures.view, .shader_read_only_optimal, nearest_sampler, .combined_image_sampler);
    writer.updateSet(&ctx, descriptor_set);

    writer.clear();
    try writer.writeBuffer(0, scene_data_buffer.handle, @sizeOf(GpuSceneData), 0, .uniform_buffer_dynamic);
    try writer.writeImage(1, skybox.cubemap.view, .shader_read_only_optimal, linear_sampler, .combined_image_sampler);
    writer.updateSet(&ctx, skybox.descriptor_set);

    var self: @This() = .{
        .window = window,
        .camera = Camera.init(.{ 0, 4, 0 }),
        .ctx = ctx,
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
        .world = world,
        .skybox = skybox,
        .scene_data_buffer = scene_data_buffer,
        .descriptor_set = descriptor_set,
        .block_textures = block_textures,
        .nearest_sampler = nearest_sampler,
        .linear_sampler = linear_sampler,
        .timer = try std.time.Timer.start(),
    };

    try self.initImGui();

    return self;
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    c.cImGui_ImplVulkan_Shutdown();
    self.deletion_queue.flush(&self.ctx);
    vk_utils.destroyFrameBuffers(&self.ctx, self.framebuffers);
    vk_utils.destroyImage(&self.ctx, self.depth_image);
    vk_utils.destroyImageViews(&self.ctx, self.swapchain_image_views);
    self.swapchain.destroy();
    self.ctx.deinit(allocator);
    self.window.deinit();
}

pub fn run(self: *@This()) !void {
    var timer = try std.time.Timer.start();
    var tick_remainder = timer.read();

    var fps_history = std.mem.zeroes([60]f32);
    var current_history: usize = 0;

    while (!self.window.shouldClose()) {
        c.glfwPollEvents();

        if (self.window.framebuffer_resized or self.swapchain_resize_requested) {
            try self.recreateSwapchain();
            self.window.framebuffer_resized = false;
            self.swapchain_resize_requested = false;
        }
        self.window.update();

        const delta_ns = timer.lap();
        const delta_s: f32 = @as(f32, @floatFromInt(delta_ns)) / std.time.ns_per_s;

        fps_history[current_history] = 1.0 / delta_s;
        current_history = (current_history + 1) % fps_history.len;

        var fps_sum: f32 = 0;
        for (fps_history) |fps| {
            fps_sum += fps;
        }
        self.fps = fps_sum / @as(f32, @floatFromInt(fps_history.len));

        var tick_time = tick_remainder + delta_ns;
        if (tick_time > @as(u64, @intFromFloat(ns_per_tick))) {
            try self.fixedUpdate();
            tick_time -= ns_per_tick;
        }
        tick_remainder = tick_time;

        try self.update(delta_s);
        self.window.mouse.delta = .{ 0, 0 };

        self.renderImGuiFrame();
        try self.draw();
    }

    try self.ctx.device.deviceWaitIdle();
}

fn fixedUpdate(self: *@This()) !void {
    const speed = move_speed * delta_time_fixed;
    const forward = math.vec.mul(self.camera.dir, speed);
    const right = math.vec.mul(self.camera.right, speed);
    const up = math.vec.mul(self.camera.up, speed);

    const prev_pos = self.camera.pos;
    if (self.window.keyboard.keys[c.GLFW_KEY_W].down) self.camera.pos = self.camera.pos + forward;
    if (self.window.keyboard.keys[c.GLFW_KEY_S].down) self.camera.pos = self.camera.pos - forward;
    if (self.window.keyboard.keys[c.GLFW_KEY_D].down) self.camera.pos = self.camera.pos + right;
    if (self.window.keyboard.keys[c.GLFW_KEY_A].down) self.camera.pos = self.camera.pos - right;
    if (self.window.keyboard.keys[c.GLFW_KEY_SPACE].down) self.camera.pos = self.camera.pos + up;
    if (self.window.keyboard.keys[c.GLFW_KEY_LEFT_SHIFT].down) self.camera.pos = self.camera.pos - up;

    const curr_dir = self.camera.dir;
    const curr_pos = self.camera.pos;
    const current_chunk: math.Vec3i = .{
        @intFromFloat(self.camera.pos[0] / Chunk.width),
        @intFromFloat(self.camera.pos[1] / Chunk.height),
        @intFromFloat(self.camera.pos[2] / Chunk.depth),
    };
    if (!math.vec.eql(curr_dir, self.prev_dir) or !math.vec.eql(curr_pos, prev_pos)) {
        const frustum = math.Frustum.init(std.math.degreesToRadians(100), self.window.aspectRatio(), 0.1, 10000, self.camera.pos, self.camera.dir);
        var chunk_it = self.world.chunkIterator();
        while (chunk_it.next()) |chunk| {
            var corners: [8]math.Vec3i = undefined;
            corners[0] = .{ chunk.position[0] * Chunk.width, chunk.position[1] * Chunk.height, chunk.position[2] * Chunk.depth };
            corners[1] = corners[0] + math.Vec3i{ Chunk.width, 0, 0 };
            corners[2] = corners[0] + math.Vec3i{ Chunk.width, 0, Chunk.depth };
            corners[3] = corners[0] + math.Vec3i{ 0, 0, Chunk.depth };
            corners[4] = corners[0] + math.Vec3i{ 0, Chunk.height, 0 };
            corners[5] = corners[4] + math.Vec3i{ Chunk.width, 0, 0 };
            corners[6] = corners[4] + math.Vec3i{ Chunk.width, 0, Chunk.depth };
            corners[7] = corners[4] + math.Vec3i{ 0, 0, Chunk.depth };

            for (corners) |corner| {
                if (math.vec.eql(current_chunk, chunk.position) or frustum.isPointInside(math.vec.cast(f32, corner))) {
                    break;
                }
            } else {
                self.world.removeChunk(chunk.position);
            }
        }

        for (0..World.chunk_radius) |j| {
            for (0..World.chunk_radius * 2) |i| {
                for (0..World.chunk_radius * 2) |k| {
                    const x: i32 = @intCast(i);
                    const y: i32 = @intCast(j);
                    const z: i32 = @intCast(k);
                    const pos: math.Vec3i = .{
                        current_chunk[0] + x - World.chunk_radius,
                        current_chunk[1] + y - World.chunk_radius / 2,
                        current_chunk[2] + z - World.chunk_radius,
                    };
                    // const dist = math.vec.length2(math.vec.sub(pos, current_chunk));
                    // if (dist < World.chunk_radius * World.chunk_radius) {
                    //     try self.world.addChunk(pos);
                    // }
                    var corners: [8]math.Vec3i = undefined;
                    corners[0] = .{ pos[0] * Chunk.width, pos[1] * Chunk.height, pos[2] * Chunk.depth };
                    corners[1] = corners[0] + math.Vec3i{ Chunk.width, 0, 0 };
                    corners[2] = corners[0] + math.Vec3i{ Chunk.width, 0, Chunk.depth };
                    corners[3] = corners[0] + math.Vec3i{ 0, 0, Chunk.depth };
                    corners[4] = corners[0] + math.Vec3i{ 0, Chunk.height, 0 };
                    corners[5] = corners[4] + math.Vec3i{ Chunk.width, 0, 0 };
                    corners[6] = corners[4] + math.Vec3i{ Chunk.width, 0, Chunk.depth };
                    corners[7] = corners[4] + math.Vec3i{ 0, 0, Chunk.depth };

                    for (corners) |corner| {
                        if (frustum.isPointInside(math.vec.cast(f32, corner))) {
                            try self.world.addChunk(pos);
                            break;
                        }
                    }
                }
            }
        }
    }
}

fn update(self: *@This(), delta_time: f32) !void {
    const camera_delta = math.vec.mul(self.window.mouse.delta, delta_time * mouse_sensivity);
    self.prev_dir = self.camera.dir;
    self.camera.update(camera_delta);

    if (self.window.keyboard.keys[c.GLFW_KEY_M].pressed) self.window.setMouseCapture(!self.window.mouse_captured);
}

fn draw(self: *@This()) !void {
    const frame = self.currentFrame();
    const cmd = GraphicsContext.CommandBuffer.init(frame.command_buffer, self.ctx.vkd);

    const fence_result = try self.ctx.device.waitForFences(1, @ptrCast(&frame.render_fence), vk.TRUE, std.time.ns_per_s);
    assert(fence_result == .success);

    try self.ctx.device.resetFences(1, @ptrCast(&frame.render_fence));

    const next_image_result = self.ctx.device.acquireNextImageKHR(
        self.swapchain.handle,
        std.time.ns_per_s,
        frame.swapchain_semaphore,
        .null_handle,
    ) catch |err| {
        if (err == error.OutOfDateKHR) {
            self.swapchain_resize_requested = true;
            return;
        } else {
            return err;
        }
    };
    assert(next_image_result.result == .success);

    const image_index = next_image_result.image_index;

    try self.ctx.device.resetCommandPool(frame.command_pool, .{});

    self.scene_data.view = self.camera.viewMatrix();
    self.scene_data.proj = math.mat.perspective(std.math.degreesToRadians(80), self.window.aspectRatio(), 10000, 0.1);
    self.scene_data.view_proj = math.mat.mul(self.scene_data.proj, self.scene_data.view);

    const alignment = std.mem.alignForward(vk.DeviceSize, @sizeOf(GpuSceneData), self.ctx.physical_device.properties.limits.min_uniform_buffer_offset_alignment);
    const frame_index = self.frame_number % frame_overlap;
    const uniform_offset: u32 = @intCast(alignment * frame_index);
    {
        const data = try self.ctx.device.mapMemory(self.scene_data_buffer.memory, 0, vk.WHOLE_SIZE, .{});
        defer self.ctx.device.unmapMemory(self.scene_data_buffer.memory);

        const ptr: [*]u8 = @ptrCast(@alignCast(data));
        @memcpy(ptr[uniform_offset .. uniform_offset + @sizeOf(GpuSceneData)], std.mem.asBytes(&self.scene_data));
    }

    const command_begin_info: vk.CommandBufferBeginInfo = .{ .flags = .{ .one_time_submit_bit = true } };
    try self.ctx.device.beginCommandBuffer(cmd.handle, &command_begin_info);

    self.timer.reset();
    const uploaded = try self.world.uploadChunkFromQueue(&self.ctx, cmd.handle, self.staging_buffer);
    if (uploaded) {
        self.chunk_upload_history[self.chunk_upload_current] = self.timer.lap();
        self.chunk_upload_current = (self.chunk_upload_current + 1) % self.chunk_upload_history.len;
    }

    const clear_value = vk.ClearValue{ .color = .{ .float_32 = .{ 0.1, 0.1, 0.1, 1 } } };
    const depth_clear = vk.ClearValue{ .depth_stencil = .{ .depth = 0, .stencil = 0 } };
    const clear_values = [_]vk.ClearValue{ clear_value, depth_clear };

    const render_pass_info = vk_init.renderPassBeginInfo(
        self.render_pass,
        self.framebuffers[image_index],
        self.swapchain.extent,
        &clear_values,
    );
    cmd.beginRenderPass(&render_pass_info, .@"inline");

    const viewport: vk.Viewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(self.swapchain.extent.width),
        .height = @floatFromInt(self.swapchain.extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    cmd.setViewport(0, 1, @ptrCast(&viewport));

    const scissor: vk.Rect2D = .{ .extent = self.swapchain.extent, .offset = .{ .x = 0, .y = 0 } };
    cmd.setScissor(0, 1, @ptrCast(&scissor));

    cmd.bindPipeline(.graphics, self.skybox.pipeline);
    self.skybox.draw(&self.ctx, cmd.handle, uniform_offset);

    cmd.bindPipeline(.graphics, self.default_pipeline);
    cmd.bindDescriptorSets(.graphics, self.default_pipeline_layout, 0, 1, @ptrCast(&self.descriptor_set), 1, @ptrCast(&uniform_offset));

    var chunk_it = self.world.chunkIterator();
    while (chunk_it.next()) |chunk| {
        if (chunk.state != .loaded or chunk.index_count == 0) continue;

        cmd.bindVertexBuffers(0, 1, @ptrCast(&chunk.vertex_buffer), &[_]vk.DeviceSize{0});
        cmd.bindIndexBuffer(chunk.index_buffer, 0, .uint16);

        var model = math.mat.identity(math.Mat4);
        model = math.mat.translate(model, .{ @floatFromInt(chunk.position[0] * Chunk.width), @floatFromInt(chunk.position[1] * Chunk.height), @floatFromInt(chunk.position[2] * Chunk.depth) });
        const push_constants: GpuPushConstants = .{ .model = model };
        cmd.pushConstants(self.default_pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(GpuPushConstants), @ptrCast(&push_constants));

        cmd.drawIndexed(chunk.index_count, 1, 0, 0, 0);
    }

    c.cImGui_ImplVulkan_RenderDrawData(c.ImGui_GetDrawData(), c.vkZigHandleToC(c.VkCommandBuffer, cmd.handle));

    cmd.endRenderPass();
    try self.ctx.device.endCommandBuffer(cmd.handle);

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
    try self.ctx.graphics_queue.submit(1, @ptrCast(&submit), frame.render_fence);

    const present_info = vk.PresentInfoKHR{
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.swapchain.handle),
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&frame.render_semaphore),
        .p_image_indices = @ptrCast(&image_index),
    };
    const present_result = self.ctx.present_queue.presentKHR(&present_info) catch |err| {
        if (err == error.OutOfDateKHR) {
            self.swapchain_resize_requested = true;
            assert(self.frame_number != std.math.maxInt(u64));
            self.frame_number += 1;
            return;
        } else {
            return err;
        }
    };
    assert(present_result == .success);

    assert(self.frame_number != std.math.maxInt(u64));
    self.frame_number += 1;
}

fn renderImGuiFrame(self: *@This()) void {
    c.cImGui_ImplVulkan_NewFrame();
    c.cImGui_ImplGlfw_NewFrame();
    c.ImGui_NewFrame();

    if (c.ImGui_Begin("info", null, c.ImGuiWindowFlags_None)) {
        c.ImGui_Text("Fps: %.2f", self.fps);
        const average = math.average(u64, &self.chunk_upload_history);
        var buffer: [16]u8 = undefined;
        _ = std.fmt.bufPrintZ(&buffer, "{:.3}", .{std.fmt.fmtDuration(average)}) catch @panic("buffer too small");
        c.ImGui_Text("Average chunk upload: %s", &buffer);
        c.ImGui_BeginDisabled(true);
        _ = c.ImGui_Checkbox("mouse captured", &self.window.mouse_captured);
        c.ImGui_EndDisabled();

        c.ImGui_End();
    }

    c.ImGui_Render();
}

fn recreateSwapchain(self: *@This()) !void {
    try self.ctx.device.deviceWaitIdle();

    vk_utils.destroyImageViews(&self.ctx, self.swapchain_image_views);
    vk_utils.destroyImage(&self.ctx, self.depth_image);
    vk_utils.destroyFrameBuffers(&self.ctx, self.framebuffers);

    const old_swapchain = self.swapchain;
    self.swapchain = try vkk.Swapchain.create(self.ctx.device.handle, self.ctx.physical_device.handle, self.ctx.surface, .{
        .graphics_queue_index = self.ctx.graphics_queue_index,
        .present_queue_index = self.ctx.present_queue_index,
        .desired_extent = self.window.extent(),
        .desired_formats = &.{
            .{ .format = .b8g8r8a8_unorm, .color_space = .srgb_nonlinear_khr },
        },
        .desired_present_modes = &.{
            .fifo_khr,
        },
        .old_swapchain = old_swapchain.handle,
    });
    old_swapchain.destroy();

    try self.swapchain.getImages(self.swapchain_images);
    try self.swapchain.getImageViews(self.swapchain_images, self.swapchain_image_views);
    self.depth_image = try createDepthImage(&self.ctx, self.depth_image.format, self.swapchain.extent);
    try vk_utils.createFramebuffers(&self.ctx, self.render_pass, self.swapchain.extent, self.swapchain_image_views, self.depth_image.view, self.framebuffers);
}

fn createDepthImage(ctx: *const GraphicsContext, format: vk.Format, extent: vk.Extent2D) !AllocatedImage {
    return vk_utils.createImage(
        ctx,
        format,
        .{ .depth_stencil_attachment_bit = true },
        .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .{ .device_local_bit = true },
        .{ .depth_bit = true },
        .@"2d_array",
        1,
        .{},
    );
}

fn uploadMesh(
    ctx: *const GraphicsContext,
    immediate_ctx: ImmediateContext,
    staging_buffer: AllocatedBuffer,
    vertex_buffer: AllocatedBuffer,
    index_buffer: AllocatedBuffer,
    vertices: []const mesh.Vertex,
    indices: []const u16,
) !void {
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
        const data = try ctx.device.mapMemory(staging_buffer.memory, 0, vertex_size + index_size, .{});
        defer ctx.device.unmapMemory(staging_buffer.memory);

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

        fn recordCommands(self: @This(), gctx: *const GraphicsContext, cmd: vk.CommandBuffer) void {
            const cmd_proxy = GraphicsContext.CommandBuffer.init(cmd, gctx.vkd);
            const vertex_copy = vk.BufferCopy{ .size = self.vertex_size, .src_offset = 0, .dst_offset = 0 };
            cmd_proxy.copyBuffer(cmd, self.staging_buffer, self.vertex_buffer, 1, @ptrCast(&vertex_copy));

            const index_copy = vk.BufferCopy{ .size = self.index_size, .src_offset = self.vertex_size, .dst_offset = 0 };
            cmd_proxy.copyBuffer(cmd, self.staging_buffer, self.index_buffer, 1, @ptrCast(&index_copy));
        }
    };

    try immediateSubmit(ctx, immediate_ctx, MeshCopy{
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

pub fn immediateSubmit(ctx: *const GraphicsContext, imctx: ImmediateContext, submit_ctx: anytype) !void {
    assert(imctx.command_buffer != .null_handle);
    assert(imctx.command_pool != .null_handle);
    assert(imctx.fence != .null_handle);

    const cmd = imctx.command_buffer;

    const cmd_begin_info: vk.CommandBufferBeginInfo = .{ .flags = .{ .one_time_submit_bit = true } };
    try ctx.device.beginCommandBuffer(cmd, &cmd_begin_info);

    submit_ctx.recordCommands(ctx, cmd);

    try ctx.device.endCommandBuffer(cmd);

    const submit: vk.SubmitInfo = .{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&cmd) };
    try ctx.graphics_queue.submit(1, @ptrCast(&submit), imctx.fence);

    const res = try ctx.device.waitForFences(1, @ptrCast(&imctx.fence), vk.TRUE, std.time.ns_per_s);
    if (res != .success) return error.Timeout;

    try ctx.device.resetFences(1, @ptrCast(&imctx.fence));

    try ctx.device.resetCommandPool(imctx.command_pool, .{});
}

fn beginImmediateSubmit(ctx: *const GraphicsContext, imctx: ImmediateContext) !vk.CommandBuffer {
    const cmd_begin_info: vk.CommandBufferBeginInfo = .{ .flags = .{ .one_time_submit_bit = true } };
    try ctx.device.beginCommandBuffer(imctx.command_buffer, &cmd_begin_info);

    return imctx.command_buffer;
}

fn endImmediateSubmit(ctx: *const GraphicsContext, imctx: ImmediateContext, cmd: vk.CommandBuffer) !void {
    try ctx.device.endCommandBuffer(cmd);

    const submit: vk.SubmitInfo = .{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&cmd) };
    try ctx.graphics_queue.submit(1, @ptrCast(&submit), imctx.fence);

    const res = try ctx.device.waitForFences(1, @ptrCast(&imctx.fence), vk.TRUE, std.time.ns_per_s);
    if (res != .success) return error.Timeout;

    try ctx.device.resetFences(1, @ptrCast(&imctx.fence));

    try ctx.device.resetCommandPool(imctx.command_pool, .{});
}

fn initImGui(self: *@This()) !void {
    const pool = try createImguiDescriptorPool(&self.ctx);
    try self.deletion_queue.append(pool);

    _ = c.ImGui_CreateContext(null);
    if (!c.cImGui_ImplGlfw_InitForVulkan(self.window.handle, true)) return error.ImGuiInitFailed;

    var init_info = c.ImGui_ImplVulkan_InitInfo{
        .Instance = c.vkZigHandleToC(c.VkInstance, self.ctx.instance.handle),
        .PhysicalDevice = c.vkZigHandleToC(c.VkPhysicalDevice, self.ctx.physical_device.handle),
        .Device = c.vkZigHandleToC(c.VkDevice, self.ctx.device.handle),
        .Queue = c.vkZigHandleToC(c.VkQueue, self.ctx.graphics_queue.handle),
        .DescriptorPool = c.vkZigHandleToC(c.VkDescriptorPool, pool),
        .MinImageCount = self.swapchain.image_count,
        .ImageCount = self.swapchain.image_count,
        .MSAASamples = c.VK_SAMPLE_COUNT_1_BIT,
        .RenderPass = c.vkZigHandleToC(c.VkRenderPass, self.render_pass),
    };

    if (!c.cImGui_ImplVulkan_Init(@ptrCast(&init_info))) return error.ImGuiInitFailed;
    if (!c.cImGui_ImplVulkan_CreateFontsTexture()) return error.ImGuiInitFailed;
}

fn createImguiDescriptorPool(ctx: *const GraphicsContext) !vk.DescriptorPool {
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

    return ctx.device.createDescriptorPool(&pool_info, null);
}

fn createFrameData(
    ctx: *const GraphicsContext,
    deletion_queue: *vk_utils.DeletionQueue,
) ![frame_overlap]FrameData {
    var frames: [frame_overlap]FrameData = undefined;

    const command_pool_info: vk.CommandPoolCreateInfo = .{ .queue_family_index = ctx.graphics_queue_index };
    const fence_info: vk.FenceCreateInfo = .{ .flags = .{ .signaled_bit = true } };
    const semaphore_info: vk.SemaphoreCreateInfo = .{};

    for (&frames) |*frame| {
        frame.command_pool = try ctx.device.createCommandPool(&command_pool_info, null);
        try deletion_queue.append(frame.command_pool);

        const command_buffer_info = vk_init.commandBufferAllocateInfo(frame.command_pool);
        try ctx.device.allocateCommandBuffers(&command_buffer_info, @ptrCast(&frame.command_buffer));

        frame.render_fence = try ctx.device.createFence(&fence_info, null);
        try deletion_queue.append(frame.render_fence);

        frame.render_semaphore = try ctx.device.createSemaphore(&semaphore_info, null);
        try deletion_queue.append(frame.render_semaphore);

        frame.swapchain_semaphore = try ctx.device.createSemaphore(&semaphore_info, null);
        try deletion_queue.append(frame.swapchain_semaphore);
    }

    return frames;
}

fn createDefaultPipeline(
    ctx: *const GraphicsContext,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
    image_format: vk.Format,
    depth_format: vk.Format,
) !vk.Pipeline {
    assert(layout != .null_handle);
    assert(image_format != .undefined);
    assert(depth_format != .undefined);

    const vertex_shader = try vk_utils.createShaderModule(ctx, &shaders.triangle_vert);
    defer ctx.device.destroyShaderModule(vertex_shader, null);

    const fragment_shader = try vk_utils.createShaderModule(ctx, &shaders.triangle_frag);
    defer ctx.device.destroyShaderModule(fragment_shader, null);

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

    return builder.build(ctx);
}

fn createImmediateContext(ctx: *const GraphicsContext, graphics_family_index: u32) !ImmediateContext {
    const fence_info: vk.FenceCreateInfo = .{};
    const fence = try ctx.device.createFence(&fence_info, null);
    errdefer ctx.device.destroyFence(fence, null);

    const command_pool_info: vk.CommandPoolCreateInfo = .{ .queue_family_index = graphics_family_index };
    const command_pool = try ctx.device.createCommandPool(&command_pool_info, null);
    errdefer ctx.device.destroyCommandPool(command_pool, null);

    const command_buffer_info = vk_init.commandBufferAllocateInfo(command_pool);
    var command_buffer: vk.CommandBuffer = undefined;
    try ctx.device.allocateCommandBuffers(&command_buffer_info, @ptrCast(&command_buffer));

    return .{
        .fence = fence,
        .command_pool = command_pool,
        .command_buffer = command_buffer,
    };
}
