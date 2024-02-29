const std = @import("std");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const mesh = @import("mesh.zig");

const assert = std.debug.assert;

const vkd = vkk.dispatch.vkd;

pub const Builder = struct {
    pub const BlendMode = enum { none, additive, alpha_blend };

    pub const Config = struct {
        layout: vk.PipelineLayout,
        vertex_input_description: mesh.VertexInputDescription,
        render_pass: vk.RenderPass,
        vertex_shader: vk.ShaderModule,
        fragment_shader: vk.ShaderModule,
        topology: vk.PrimitiveTopology,
        polygon_mode: vk.PolygonMode,
        cull_mode: vk.CullModeFlags,
        front_face: vk.FrontFace,
        color_attachment_format: vk.Format,
        depth_attachment_format: vk.Format,
        enable_depth: bool = false,
        depth_compare_op: vk.CompareOp = .never,
        blend_mode: BlendMode = .none,
    };

    layout: vk.PipelineLayout,
    vertex_input_description: mesh.VertexInputDescription,
    render_pass: vk.RenderPass,
    shader_stages: [2]vk.PipelineShaderStageCreateInfo,
    input_assembly: vk.PipelineInputAssemblyStateCreateInfo,
    rasterizer: vk.PipelineRasterizationStateCreateInfo,
    color_blend_attachment: vk.PipelineColorBlendAttachmentState,
    multisampling: vk.PipelineMultisampleStateCreateInfo,
    depth_stencil: vk.PipelineDepthStencilStateCreateInfo,
    color_attachment_format: vk.Format,
    depth_attachment_format: vk.Format,

    pub fn init(config: Config) @This() {
        assert(config.render_pass != .null_handle);
        assert(config.layout != .null_handle);
        assert(config.vertex_shader != .null_handle);
        assert(config.fragment_shader != .null_handle);
        assert(config.color_attachment_format != .undefined);
        if (config.enable_depth) assert(config.depth_attachment_format != .undefined);

        return .{
            .vertex_input_description = config.vertex_input_description,
            .render_pass = config.render_pass,
            .layout = config.layout,
            .color_attachment_format = config.color_attachment_format,
            .depth_attachment_format = config.depth_attachment_format,
            .shader_stages = .{
                .{
                    .stage = .{ .vertex_bit = true },
                    .module = config.vertex_shader,
                    .p_name = "main",
                },
                .{
                    .stage = .{ .fragment_bit = true },
                    .module = config.fragment_shader,
                    .p_name = "main",
                },
            },
            .input_assembly = .{
                .topology = config.topology,
                .primitive_restart_enable = vk.FALSE,
            },
            .rasterizer = .{
                .depth_clamp_enable = vk.FALSE,
                .rasterizer_discard_enable = vk.FALSE,
                .polygon_mode = config.polygon_mode,
                .line_width = 1,
                .front_face = config.front_face,
                .cull_mode = config.cull_mode,
                .depth_bias_enable = vk.FALSE,
                .depth_bias_constant_factor = 0,
                .depth_bias_clamp = 0,
                .depth_bias_slope_factor = 0,
            },
            .color_blend_attachment = .{
                .blend_enable = if (config.blend_mode == .none) vk.FALSE else vk.TRUE,
                .src_color_blend_factor = switch (config.blend_mode) {
                    .none, .additive => .one,
                    .alpha_blend => .one_minus_dst_alpha,
                },
                .dst_color_blend_factor = .dst_alpha,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            },
            .multisampling = .{
                .rasterization_samples = .{ .@"1_bit" = true },
                .sample_shading_enable = vk.FALSE,
                .min_sample_shading = 1,
                .alpha_to_coverage_enable = vk.FALSE,
                .alpha_to_one_enable = vk.FALSE,
            },
            .depth_stencil = .{
                .depth_test_enable = if (config.enable_depth) vk.TRUE else vk.FALSE,
                .depth_write_enable = if (config.enable_depth) vk.TRUE else vk.FALSE,
                .depth_compare_op = config.depth_compare_op,
                .depth_bounds_test_enable = vk.FALSE,
                .min_depth_bounds = 0,
                .max_depth_bounds = 1,
                .stencil_test_enable = vk.FALSE,
                .front = .{
                    .fail_op = .keep,
                    .pass_op = .keep,
                    .depth_fail_op = .keep,
                    .compare_op = .never,
                    .compare_mask = 0,
                    .write_mask = 0,
                    .reference = 0,
                },
                .back = .{
                    .fail_op = .keep,
                    .pass_op = .keep,
                    .depth_fail_op = .keep,
                    .compare_op = .never,
                    .compare_mask = 0,
                    .write_mask = 0,
                    .reference = 0,
                },
            },
        };
    }

    pub fn build(self: *const @This(), device: vk.Device) !vk.Pipeline {
        assert(device != .null_handle);
        assert(self.render_pass != .null_handle);
        assert(self.layout != .null_handle);
        assert(self.shader_stages[0].module != .null_handle);
        assert(self.shader_stages[1].module != .null_handle);
        assert(self.color_attachment_format != .undefined);
        if (self.depth_stencil.depth_test_enable == vk.TRUE) assert(self.depth_attachment_format != .undefined);

        const viewport_state: vk.PipelineViewportStateCreateInfo = .{
            .scissor_count = 1,
            .viewport_count = 1,
        };

        const color_blending: vk.PipelineColorBlendStateCreateInfo = .{
            .logic_op_enable = vk.FALSE,
            .logic_op = .copy,
            .blend_constants = .{ 0, 0, 0, 0 },
            .attachment_count = 1,
            .p_attachments = @ptrCast(&self.color_blend_attachment),
        };

        const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
            .vertex_binding_description_count = self.vertex_input_description.bindings.len,
            .p_vertex_binding_descriptions = &self.vertex_input_description.bindings,
            .vertex_attribute_description_count = self.vertex_input_description.attributes.len,
            .p_vertex_attribute_descriptions = &self.vertex_input_description.attributes,
        };

        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const dynamic_info: vk.PipelineDynamicStateCreateInfo = .{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };

        const pipeline_info: vk.GraphicsPipelineCreateInfo = .{
            .stage_count = self.shader_stages.len,
            .p_stages = &self.shader_stages,
            .p_vertex_input_state = &vertex_input_info,
            .p_input_assembly_state = &self.input_assembly,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &self.rasterizer,
            .p_multisample_state = &self.multisampling,
            .p_color_blend_state = &color_blending,
            .p_depth_stencil_state = &self.depth_stencil,
            .p_dynamic_state = &dynamic_info,
            .layout = self.layout,
            .render_pass = self.render_pass,
            .subpass = 0,
            .base_pipeline_index = -1,
        };

        var pipeline: vk.Pipeline = undefined;
        const result = try vkd().createGraphicsPipelines(device, .null_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&pipeline));
        if (result != .success) return error.PipelineCreateFailed;
        return pipeline;
    }
};
