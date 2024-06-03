const vk = @import("vulkan");
const vkk = @import("vk-kickstart");
const Engine = @import("Engine.zig");
const vk_utils = @import("vk_utils.zig");
const shaders = @import("shaders");
const pipeline = @import("pipeline.zig");
const mesh = @import("mesh.zig");
const texture = @import("texture.zig");
const descriptor = @import("descriptor.zig");
const GraphicsContext = @import("GraphicsContext.zig");

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,
cubemap: Engine.AllocatedImage,
vertex_buffer: Engine.AllocatedBuffer,
descriptor_set: vk.DescriptorSet,

pub fn init(
    ctx: *const GraphicsContext,
    descriptor_layout: vk.DescriptorSetLayout,
    render_pass: vk.RenderPass,
    image_format: vk.Format,
    staging_buffer: Engine.AllocatedBuffer,
    immediate_context: Engine.ImmediateContext,
    descriptor_allocator: *descriptor.Allocator,
    deletion_queue: *vk_utils.DeletionQueue,
) !@This() {
    const pipeline_layout_info: vk.PipelineLayoutCreateInfo = .{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&descriptor_layout),
    };
    const pipeline_layout = try ctx.device.createPipelineLayout(&pipeline_layout_info, null);
    try deletion_queue.append(pipeline_layout);

    const vertex_shader = try vk_utils.createShaderModule(ctx, &shaders.skybox_vert);
    defer ctx.device.destroyShaderModule(vertex_shader, null);

    const fragment_shader = try vk_utils.createShaderModule(ctx, &shaders.skybox_frag);
    defer ctx.device.destroyShaderModule(fragment_shader, null);

    const builder = pipeline.Builder.init(.{
        .vertex_input_description = mesh.SkyboxVertex.getInputDescription(),
        .render_pass = render_pass,
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
        .layout = pipeline_layout,
        .topology = .triangle_list,
        .cull_mode = .{},
        .polygon_mode = .fill,
        .front_face = .counter_clockwise,
        .color_attachment_format = image_format,
    });

    const skybox_pipeline = try builder.build(ctx);
    try deletion_queue.append(skybox_pipeline);

    const cubemap = try texture.loadCubemap(ctx, staging_buffer, immediate_context, .{
        "assets/sky_right.jpg",
        "assets/sky_left.jpg",
        "assets/sky_top.jpg",
        "assets/sky_bottom.jpg",
        "assets/sky_front.jpg",
        "assets/sky_back.jpg",
    });
    try deletion_queue.appendImage(cubemap);

    const vertex_buffer = try vk_utils.createBuffer(
        ctx,
        @sizeOf(@TypeOf(cube)),
        .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .{ .device_local_bit = true },
    );
    try deletion_queue.appendBuffer(vertex_buffer);

    {
        const data = try ctx.device.mapMemory(staging_buffer.memory, 0, vk.WHOLE_SIZE, .{});
        defer ctx.device.unmapMemory(staging_buffer.memory);

        const ptr: [*]mesh.SkyboxVertex = @ptrCast(@alignCast(data));
        @memcpy(ptr, cube[0..cube.len]);
    }

    try Engine.immediateSubmit(ctx, immediate_context, SkyboxCopy{
        .dst_buffer = vertex_buffer.handle,
        .size = vertex_buffer.size,
        .staging_buffer = staging_buffer.handle,
    });

    const descriptor_set = try descriptor_allocator.alloc(ctx, descriptor_layout);

    return .{
        .pipeline_layout = pipeline_layout,
        .pipeline = skybox_pipeline,
        .cubemap = cubemap,
        .vertex_buffer = vertex_buffer,
        .descriptor_set = descriptor_set,
    };
}

pub fn draw(self: *const @This(), ctx: *const GraphicsContext, cmd: vk.CommandBuffer, uniform_offset: u32) void {
    const cmd_proxy = GraphicsContext.CommandBuffer.init(cmd, ctx.vkd);
    cmd_proxy.bindDescriptorSets(.graphics, self.pipeline_layout, 0, 1, @ptrCast(&self.descriptor_set), 1, @ptrCast(&uniform_offset));
    cmd_proxy.bindVertexBuffers(0, 1, @ptrCast(&self.vertex_buffer), &[_]vk.DeviceSize{0});
    cmd_proxy.draw(36, 1, 0, 0);
}

const cube = [_]mesh.SkyboxVertex{
    .{ .pos = .{ -1, 1, -1 } },
    .{ .pos = .{ -1, -1, -1 } },
    .{ .pos = .{ 1, -1, -1 } },
    .{ .pos = .{ 1, -1, -1 } },
    .{ .pos = .{ 1, 1, -1 } },
    .{ .pos = .{ -1, 1, -1 } },

    .{ .pos = .{ -1, -1, 1 } },
    .{ .pos = .{ -1, -1, -1 } },
    .{ .pos = .{ -1, 1, -1 } },
    .{ .pos = .{ -1, 1, -1 } },
    .{ .pos = .{ -1, 1, 1 } },
    .{ .pos = .{ -1, -1, 1 } },

    .{ .pos = .{ 1, -1, -1 } },
    .{ .pos = .{ 1, -1, 1 } },
    .{ .pos = .{ 1, 1, 1 } },
    .{ .pos = .{ 1, 1, 1 } },
    .{ .pos = .{ 1, 1, -1 } },
    .{ .pos = .{ 1, -1, -1 } },

    .{ .pos = .{ -1, -1, 1 } },
    .{ .pos = .{ -1, 1, 1 } },
    .{ .pos = .{ 1, 1, 1 } },
    .{ .pos = .{ 1, 1, 1 } },
    .{ .pos = .{ 1, -1, 1 } },
    .{ .pos = .{ -1, -1, 1 } },

    .{ .pos = .{ -1, 1, -1 } },
    .{ .pos = .{ 1, 1, -1 } },
    .{ .pos = .{ 1, 1, 1 } },
    .{ .pos = .{ 1, 1, 1 } },
    .{ .pos = .{ -1, 1, 1 } },
    .{ .pos = .{ -1, 1, -1 } },

    .{ .pos = .{ -1, -1, -1 } },
    .{ .pos = .{ -1, -1, 1 } },
    .{ .pos = .{ 1, -1, -1 } },
    .{ .pos = .{ 1, -1, -1 } },
    .{ .pos = .{ -1, -1, 1 } },
    .{ .pos = .{ 1, -1, 1 } },
};

const SkyboxCopy = struct {
    staging_buffer: vk.Buffer,
    dst_buffer: vk.Buffer,
    size: vk.DeviceSize,

    pub fn recordCommands(self: @This(), ctx: *const GraphicsContext, cmd: vk.CommandBuffer) void {
        const copy = vk.BufferCopy{ .size = self.size, .src_offset = 0, .dst_offset = 0 };
        const cmd_proxy = GraphicsContext.CommandBuffer.init(cmd, ctx.vkd);
        cmd_proxy.copyBuffer(self.staging_buffer, self.dst_buffer, 1, @ptrCast(&copy));
    }
};
