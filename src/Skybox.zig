const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const Engine = @import("Engine.zig");
const vk_utils = @import("vk_utils.zig");
const shaders = @import("shaders");
const pipeline = @import("pipeline.zig");
const mesh = @import("mesh.zig");
const texture = @import("texture.zig");
const descriptor = @import("descriptor.zig");

const vkd = vkk.dispatch.vkd;

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,
cubemap: Engine.AllocatedImage,
vertex_buffer: Engine.AllocatedBuffer,
descriptor_set: vk.DescriptorSet,

pub fn init(
    device: *const vkk.Device,
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
    const pipeline_layout = try vkd().createPipelineLayout(device.handle, &pipeline_layout_info, null);
    try deletion_queue.append(pipeline_layout);

    const vertex_shader = try vk_utils.createShaderModule(device.handle, &shaders.skybox_vert);
    defer vkd().destroyShaderModule(device.handle, vertex_shader, null);

    const fragment_shader = try vk_utils.createShaderModule(device.handle, &shaders.skybox_frag);
    defer vkd().destroyShaderModule(device.handle, fragment_shader, null);

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

    const skybox_pipeline = try builder.build(device.handle);
    try deletion_queue.append(skybox_pipeline);

    const cubemap = try texture.loadCubemap(device, staging_buffer, immediate_context, .{
        "assets/sky_right.jpg",
        "assets/sky_left.jpg",
        "assets/sky_top.jpg",
        "assets/sky_bottom.jpg",
        "assets/sky_front.jpg",
        "assets/sky_back.jpg",
    });
    try deletion_queue.appendImage(cubemap);

    const vertex_buffer = try vk_utils.createBuffer(
        device.handle,
        device.physical_device,
        @sizeOf(@TypeOf(cube)),
        .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .{ .device_local_bit = true },
    );
    try deletion_queue.appendBuffer(vertex_buffer);

    {
        const data = try vkd().mapMemory(device.handle, staging_buffer.memory, 0, vk.WHOLE_SIZE, .{});
        defer vkd().unmapMemory(device.handle, staging_buffer.memory);

        const ptr: [*]mesh.SkyboxVertex = @ptrCast(@alignCast(data));
        @memcpy(ptr, cube[0..cube.len]);
    }

    try Engine.immediateSubmit(device.handle, device.graphics_queue, immediate_context, SkyboxCopy{
        .dst_buffer = vertex_buffer.handle,
        .size = vertex_buffer.size,
        .staging_buffer = staging_buffer.handle,
    });

    const descriptor_set = try descriptor_allocator.alloc(device.handle, descriptor_layout);

    return .{
        .pipeline_layout = pipeline_layout,
        .pipeline = skybox_pipeline,
        .cubemap = cubemap,
        .vertex_buffer = vertex_buffer,
        .descriptor_set = descriptor_set,
    };
}

pub fn draw(self: *const @This(), cmd: vk.CommandBuffer, uniform_offset: u32) void {
    vkd().cmdBindDescriptorSets(cmd, .graphics, self.pipeline_layout, 0, 1, @ptrCast(&self.descriptor_set), 1, @ptrCast(&uniform_offset));
    vkd().cmdBindVertexBuffers(cmd, 0, 1, @ptrCast(&self.vertex_buffer), &[_]vk.DeviceSize{0});
    vkd().cmdDraw(cmd, 36, 1, 0, 0);
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

    pub fn recordCommands(ctx: @This(), cmd: vk.CommandBuffer) void {
        const copy = vk.BufferCopy{ .size = ctx.size, .src_offset = 0, .dst_offset = 0 };
        vkd().cmdCopyBuffer(cmd, ctx.staging_buffer, ctx.dst_buffer, 1, @ptrCast(&copy));
    }
};
