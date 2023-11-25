const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("glfw");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const shader_byte_code_align = 4;
const max_frames_in_flight = 2;

const enable_validation = std.debug.runtime_safety;
const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
const debug_extensions = [_][*:0]const u8{vk.extension_info.ext_debug_utils.name};
const required_device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};
const allocation_callbacks = null;

const DebugMessenger = if (enable_validation) vk.DebugUtilsMessengerEXT else void;

const BaseFunctions = vk.BaseWrapper(.{
    .createInstance = true,
    .getInstanceProcAddr = true,
    .enumerateInstanceLayerProperties = true,
});

const InstanceFunctions = vk.InstanceWrapper(.{
    .destroyInstance = true,
    .getDeviceProcAddr = true,
    .enumeratePhysicalDevices = true,
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceMemoryProperties = true,
    .enumerateDeviceExtensionProperties = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .destroySurfaceKHR = true,
    .createDevice = true,
    .createDebugUtilsMessengerEXT = enable_validation,
    .destroyDebugUtilsMessengerEXT = enable_validation,
});

const DeviceFunctions = vk.DeviceWrapper(.{
    .destroyDevice = true,
    .getDeviceQueue = true,
    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .getSwapchainImagesKHR = true,
    .createImageView = true,
    .destroyImageView = true,
    .createShaderModule = true,
    .destroyShaderModule = true,
    .createRenderPass = true,
    .destroyRenderPass = true,
    .createPipelineLayout = true,
    .destroyPipelineLayout = true,
    .createGraphicsPipelines = true,
    .destroyPipeline = true,
    .createFramebuffer = true,
    .destroyFramebuffer = true,
    .createCommandPool = true,
    .destroyCommandPool = true,
    .allocateCommandBuffers = true,
    .beginCommandBuffer = true,
    .endCommandBuffer = true,
    .cmdBeginRenderPass = true,
    .cmdEndRenderPass = true,
    .cmdBindPipeline = true,
    .cmdSetViewport = true,
    .cmdSetScissor = true,
    .cmdDraw = true,
    .createSemaphore = true,
    .destroySemaphore = true,
    .createFence = true,
    .destroyFence = true,
    .waitForFences = true,
    .resetFences = true,
    .acquireNextImageKHR = true,
    .resetCommandBuffer = true,
    .queueSubmit = true,
    .queuePresentKHR = true,
    .deviceWaitIdle = true,
});

const QueueFamiliesIndices = struct {
    const Self = @This();

    graphics_family: ?u32 = null,
    present_family: ?u32 = null,
    compute_family: ?u32 = null,
    transfer_family: ?u32 = null,

    fn isComplete(self: Self) bool {
        return self.graphics_family != null and
            self.present_family != null and
            self.compute_family != null and
            self.transfer_family != null;
    }
};

const PhysicalDevice = struct {
    const Self = @This();

    handle: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    graphics_family: u32,
    present_family: u32,
    compute_family: u32,
    transfer_family: u32,

    fn init(vki: InstanceFunctions, allocator: Allocator, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !Self {
        const queue_families = try findQueueFamilies(vki, allocator, device, surface);

        if (!queue_families.isComplete()) {
            return error.QueueFamiliesIncomplete;
        }

        return .{
            .handle = device,
            .properties = vki.getPhysicalDeviceProperties(device),
            .memory_properties = vki.getPhysicalDeviceMemoryProperties(device),
            .graphics_family = queue_families.graphics_family.?,
            .present_family = queue_families.present_family.?,
            .compute_family = queue_families.compute_family.?,
            .transfer_family = queue_families.transfer_family.?,
        };
    }
};

const Swapchain = struct {
    const Self = @This();

    vki: InstanceFunctions,
    vkd: DeviceFunctions,
    allocator: Allocator,
    physical_device: PhysicalDevice,
    surface: vk.SurfaceKHR,
    window: glfw.Window,

    handle: vk.SwapchainKHR,
    device: vk.Device,
    surface_format: vk.SurfaceFormatKHR,
    color_space: vk.ColorSpaceKHR,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    images: []vk.Image,
    image_views: []vk.ImageView,

    fn init(
        vki: InstanceFunctions,
        vkd: DeviceFunctions,
        allocator: Allocator,
        physical_device: PhysicalDevice,
        device: vk.Device,
        surface: vk.SurfaceKHR,
        window: glfw.Window,
    ) !Self {
        const surface_format = try pickSwapSurfaceFormat(vki, allocator, physical_device.handle, surface);
        const present_mode = try pickSwapPresentMode(vki, allocator, physical_device.handle, surface);
        const surface_capabilities = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device.handle, surface);
        const extent = try pickSwapExtent(surface_capabilities, window);

        const swapchain = try createSwapchain(
            vkd,
            physical_device,
            device,
            surface,
            surface_format,
            present_mode,
            surface_capabilities,
            extent,
        );
        errdefer vkd.destroySwapchainKHR(device, swapchain, allocation_callbacks);

        const swapchain_images = try fetchSwapchainImages(vkd, allocator, device, swapchain);
        errdefer allocator.free(swapchain_images);

        const swapchain_image_views = try createImageViews(vkd, allocator, device, swapchain_images, surface_format.format);
        errdefer allocator.free(swapchain_image_views);

        return .{
            .vki = vki,
            .vkd = vkd,
            .allocator = allocator,
            .physical_device = physical_device,
            .surface = surface,
            .window = window,
            .handle = swapchain,
            .device = device,
            .surface_format = surface_format,
            .color_space = surface_format.color_space,
            .present_mode = present_mode,
            .extent = extent,
            .images = swapchain_images,
            .image_views = swapchain_image_views,
        };
    }

    fn recreate(self: *Self) !void {
        const surface_capabilities = try self.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device.handle, self.surface);
        self.extent = try pickSwapExtent(surface_capabilities, self.window);

        self.destroySwapchainAndViews();

        self.handle = try createSwapchain(
            self.vkd,
            self.physical_device,
            self.device,
            self.surface,
            self.surface_format,
            self.present_mode,
            surface_capabilities,
            self.extent,
        );
        errdefer self.vkd.destroySwapchainKHR(self.device, self.handle, allocation_callbacks);

        self.allocator.free(self.images);
        self.allocator.free(self.image_views);

        self.images = try fetchSwapchainImages(self.vkd, self.allocator, self.device, self.handle);
        errdefer self.allocator.free(self.images);

        self.image_views = try createImageViews(
            self.vkd,
            self.allocator,
            self.device,
            self.images,
            self.surface_format.format,
        );
        errdefer self.allocator.free(self.image_views);
    }

    fn destroySwapchainAndViews(self: *Self) void {
        for (self.image_views) |view| {
            self.vkd.destroyImageView(self.device, view, allocation_callbacks);
        }

        self.vkd.destroySwapchainKHR(self.device, self.handle, allocation_callbacks);
    }

    fn deinit(self: *Self) void {
        self.destroySwapchainAndViews();
        self.allocator.free(self.image_views);
        self.allocator.free(self.images);
    }
};

const GraphicsPipeline = struct {
    const Self = @This();

    vkd: DeviceFunctions,
    device: vk.Device,

    handle: vk.Pipeline,
    layout: vk.PipelineLayout,

    fn init(
        vkd: DeviceFunctions,
        device: vk.Device,
        vertex_shader: vk.ShaderModule,
        fragment_shader: vk.ShaderModule,
        render_pass: vk.RenderPass,
    ) !Self {
        const vert_shader_stage_create_info = vk.PipelineShaderStageCreateInfo{
            .stage = .{ .vertex_bit = true },
            .module = vertex_shader,
            .p_name = "main",
        };
        const frag_shader_stage_create_info = vk.PipelineShaderStageCreateInfo{
            .stage = .{ .fragment_bit = true },
            .module = fragment_shader,
            .p_name = "main",
        };
        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{ vert_shader_stage_create_info, frag_shader_stage_create_info };

        const dynamic_states = [_]vk.DynamicState{
            .viewport,
            .scissor,
        };
        const dynamic_state_create_info = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };

        const vertex_input_create_info = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 0,
            .p_vertex_binding_descriptions = null,
            .vertex_attribute_description_count = 0,
            .p_vertex_attribute_descriptions = null,
        };

        const input_assembly_create_info = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = .triangle_list,
            .primitive_restart_enable = vk.FALSE,
        };

        const viewport_state_create_info = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .scissor_count = 1,
        };

        const rasterizer_create_info = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = vk.FALSE,
            .rasterizer_discard_enable = vk.FALSE,
            .polygon_mode = .fill,
            .line_width = 1,
            .cull_mode = .{ .back_bit = true },
            .front_face = .clockwise,
            .depth_bias_enable = vk.FALSE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
        };

        const multisampling_create_info = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = vk.FALSE,
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = vk.FALSE,
            .alpha_to_one_enable = vk.FALSE,
        };

        const color_blend_attachment_states = [_]vk.PipelineColorBlendAttachmentState{
            .{
                .blend_enable = vk.FALSE,
                .src_color_blend_factor = .one,
                .dst_color_blend_factor = .zero,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            },
        };

        const color_blending_create_info = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = vk.FALSE,
            .logic_op = .copy,
            .attachment_count = color_blend_attachment_states.len,
            .p_attachments = &color_blend_attachment_states,
            .blend_constants = .{ 0, 0, 0, 0 },
        };

        const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = 0,
            .p_set_layouts = null,
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        };

        const pipeline_layout = try vkd.createPipelineLayout(device, &pipeline_layout_create_info, allocation_callbacks);
        errdefer vkd.destroyPipelineLayout(device, pipeline_layout, allocation_callbacks);

        const pipeline_create_infos = [_]vk.GraphicsPipelineCreateInfo{
            .{
                .stage_count = shader_stages.len,
                .p_stages = &shader_stages,
                .p_vertex_input_state = &vertex_input_create_info,
                .p_input_assembly_state = &input_assembly_create_info,
                .p_viewport_state = &viewport_state_create_info,
                .p_rasterization_state = &rasterizer_create_info,
                .p_multisample_state = &multisampling_create_info,
                .p_depth_stencil_state = null,
                .p_color_blend_state = &color_blending_create_info,
                .p_dynamic_state = &dynamic_state_create_info,
                .layout = pipeline_layout,
                .render_pass = render_pass,
                .subpass = 0,
                .base_pipeline_handle = .null_handle,
                .base_pipeline_index = -1,
            },
        };

        var graphics_pipelines = [_]vk.Pipeline{.null_handle} ** pipeline_create_infos.len;
        _ = try vkd.createGraphicsPipelines(
            device,
            .null_handle,
            pipeline_create_infos.len,
            &pipeline_create_infos,
            allocation_callbacks,
            &graphics_pipelines,
        );
        errdefer vkd.destroyPipeline(device, graphics_pipelines[0]);

        return .{
            .vkd = vkd,
            .device = device,
            .handle = graphics_pipelines[0],
            .layout = pipeline_layout,
        };
    }

    fn deinit(self: *Self) void {
        self.vkd.destroyPipeline(self.device, self.handle, allocation_callbacks);
        self.vkd.destroyPipelineLayout(self.device, self.layout, allocation_callbacks);
    }
};

const Framebuffers = struct {
    const Self = @This();

    vkd: DeviceFunctions,
    allocator: Allocator,
    device: vk.Device,

    handles: []vk.Framebuffer,

    fn init(
        vkd: DeviceFunctions,
        allocator: Allocator,
        device: vk.Device,
        swapchain: *const Swapchain,
        render_pass: vk.RenderPass,
    ) !Self {
        const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.image_views.len);
        errdefer allocator.free(framebuffers);

        for (swapchain.image_views, 0..) |image_view, i| {
            const attachments = [_]vk.ImageView{image_view};
            const framebuffer_create_info = vk.FramebufferCreateInfo{
                .render_pass = render_pass,
                .attachment_count = attachments.len,
                .p_attachments = &attachments,
                .width = swapchain.extent.width,
                .height = swapchain.extent.height,
                .layers = 1,
            };
            framebuffers[i] = try vkd.createFramebuffer(device, &framebuffer_create_info, allocation_callbacks);
            errdefer vkd.destroyFramebuffer(device, framebuffers[i], allocation_callbacks);
        }

        return .{
            .vkd = vkd,
            .allocator = allocator,
            .device = device,
            .handles = framebuffers,
        };
    }

    fn recreate(self: *Self, swapchain: *const Swapchain, render_pass: vk.RenderPass) !void {
        self.destroyFramebuffers();

        createHandles(self.vkd, self.device, swapchain, render_pass, self.handles) catch |e| {
            self.allocator.free(self.handles);
            return e;
        };
    }

    fn createHandles(
        vkd: DeviceFunctions,
        device: vk.Device,
        swapchain: *const Swapchain,
        render_pass: vk.RenderPass,
        dst: []vk.Framebuffer,
    ) !void {
        for (swapchain.image_views, 0..) |image_view, i| {
            const attachments = [_]vk.ImageView{image_view};
            const framebuffer_create_info = vk.FramebufferCreateInfo{
                .render_pass = render_pass,
                .attachment_count = attachments.len,
                .p_attachments = &attachments,
                .width = swapchain.extent.width,
                .height = swapchain.extent.height,
                .layers = 1,
            };
            dst[i] = try vkd.createFramebuffer(device, &framebuffer_create_info, allocation_callbacks);
            errdefer vkd.destroyFramebuffer(device, dst[i], allocation_callbacks);
        }
    }

    fn destroyFramebuffers(self: *Self) void {
        for (self.handles) |handle| {
            self.vkd.destroyFramebuffer(self.device, handle, allocation_callbacks);
        }
    }

    fn deinit(self: *Self) void {
        self.destroyFramebuffers();
        self.allocator.free(self.handles);
    }
};

const Sync = struct {
    const Self = @This();

    vkd: DeviceFunctions,
    device: vk.Device,

    image_available_semaphores: [max_frames_in_flight]vk.Semaphore,
    render_finished_semaphores: [max_frames_in_flight]vk.Semaphore,
    in_flight_fences: [max_frames_in_flight]vk.Fence,

    fn init(vkd: DeviceFunctions, device: vk.Device) !Self {
        const semaphore_create_info = vk.SemaphoreCreateInfo{};
        const fence_create_info = vk.FenceCreateInfo{
            .flags = .{ .signaled_bit = true },
        };

        var image_available_semaphores = [_]vk.Semaphore{.null_handle} ** max_frames_in_flight;
        var render_finished_semaphores = [_]vk.Semaphore{.null_handle} ** max_frames_in_flight;
        var in_flight_fences = [_]vk.Fence{.null_handle} ** max_frames_in_flight;
        for (0..max_frames_in_flight) |i| {
            image_available_semaphores[i] = try vkd.createSemaphore(device, &semaphore_create_info, allocation_callbacks);
            render_finished_semaphores[i] = try vkd.createSemaphore(device, &semaphore_create_info, allocation_callbacks);
            in_flight_fences[i] = try vkd.createFence(device, &fence_create_info, allocation_callbacks);
        }

        return .{
            .vkd = vkd,
            .device = device,
            .image_available_semaphores = image_available_semaphores,
            .render_finished_semaphores = render_finished_semaphores,
            .in_flight_fences = in_flight_fences,
        };
    }

    fn deinit(self: *Self) void {
        for (0..max_frames_in_flight) |i| {
            self.vkd.destroySemaphore(self.device, self.image_available_semaphores[i], allocation_callbacks);
            self.vkd.destroySemaphore(self.device, self.render_finished_semaphores[i], allocation_callbacks);
            self.vkd.destroyFence(self.device, self.in_flight_fences[i], allocation_callbacks);
        }
    }
};

pub const Ctx = struct {
    const Self = @This();

    vki: InstanceFunctions,
    vkd: DeviceFunctions,

    allocator: std.mem.Allocator,

    window: glfw.Window,
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    physical_device: PhysicalDevice,
    device: vk.Device,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    compute_queue: vk.Queue,
    transfer_queue: vk.Queue,
    swapchain: Swapchain,
    vertex_shader: vk.ShaderModule,
    fragment_shader: vk.ShaderModule,
    render_pass: vk.RenderPass,
    graphics_pipeline: GraphicsPipeline,
    framebuffers: Framebuffers,
    command_pool: vk.CommandPool,
    command_buffers: [max_frames_in_flight]vk.CommandBuffer,
    sync: Sync,
    current_frame: u32 = 0,
    framebuffer_resized: bool = false,

    debug_messenger: DebugMessenger,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: glfw.Window) !Ctx {
        window.setFramebufferSizeCallback(framebufferSizeCallback);

        const vkb = try BaseFunctions.load(@as(vk.PfnGetInstanceProcAddr, @ptrCast(&glfw.getInstanceProcAddress)));

        const instance = try createInstance(vkb, allocator, app_name);
        const vki = try InstanceFunctions.load(instance, @as(vk.PfnGetInstanceProcAddr, @ptrCast(&glfw.getInstanceProcAddress)));
        errdefer vki.destroyInstance(instance, allocation_callbacks);
        vulkanLog("instance created", .{});

        const debug_messenger = try initDebugMessenger(instance, vki);
        errdefer deinitDebugMessenger(instance, vki, debug_messenger);
        vulkanLog("debug callback initialized", .{});

        const surface = try createWindowSurface(instance, window);
        errdefer vki.destroySurfaceKHR(instance, surface, allocation_callbacks);
        vulkanLog("surface created", .{});

        const physical_device = try pickPhysicalDevice(instance, vki, allocator, surface);
        vulkanLog("selected physical device {s}", .{@as([*:0]const u8, @ptrCast(&physical_device.properties.device_name))});

        const device = try createLogicalDevice(vki, allocator, physical_device);
        const vkd = try DeviceFunctions.load(device, vki.dispatch.vkGetDeviceProcAddr);
        errdefer vkd.destroyDevice(device, allocation_callbacks);
        vulkanLog("device created", .{});

        const graphics_queue = vkd.getDeviceQueue(device, physical_device.graphics_family, 0);
        vulkanLog("graphics family index {d}", .{physical_device.graphics_family});
        const present_queue = vkd.getDeviceQueue(device, physical_device.present_family, 0);
        vulkanLog("present family index {d}", .{physical_device.present_family});
        const compute_queue = vkd.getDeviceQueue(device, physical_device.compute_family, 0);
        vulkanLog("compute family index {d}", .{physical_device.compute_family});
        const transfer_queue = vkd.getDeviceQueue(device, physical_device.transfer_family, 0);
        vulkanLog("transfer family index {d}", .{physical_device.transfer_family});

        var swapchain = try Swapchain.init(vki, vkd, allocator, physical_device, device, surface, window);
        errdefer swapchain.deinit();
        vulkanLog("swapchain created", .{});
        vulkanLog("selected swapchain image format {s}", .{@tagName(swapchain.surface_format.format)});
        vulkanLog("selected swapchain image color space {s}", .{@tagName(swapchain.color_space)});
        vulkanLog("selected present mode {s}", .{@tagName(swapchain.present_mode)});
        vulkanLog("selected extent {d}x{d}", .{ swapchain.extent.width, swapchain.extent.height });
        vulkanLog("framebuffer count {d}", .{swapchain.images.len});

        const vertex_shader = try createShaderModule(vkd, allocator, device, "vert.spv");
        errdefer vkd.destroyShaderModule(device, vertex_shader, allocation_callbacks);
        vulkanLog("loaded vertex shader", .{});

        const fragment_shader = try createShaderModule(vkd, allocator, device, "frag.spv");
        errdefer vkd.destroyShaderModule(device, fragment_shader, allocation_callbacks);
        vulkanLog("loaded fragment shader", .{});

        const render_pass = try createRenderPass(vkd, device, swapchain.surface_format.format);
        errdefer vkd.destroyRenderPass(device, render_pass, allocation_callbacks);
        vulkanLog("render pass created", .{});

        var graphics_pipeline = try GraphicsPipeline.init(
            vkd,
            device,
            vertex_shader,
            fragment_shader,
            render_pass,
        );
        errdefer graphics_pipeline.deinit();
        vulkanLog("graphics pipeline created", .{});

        var framebuffers = try Framebuffers.init(vkd, allocator, device, &swapchain, render_pass);
        errdefer framebuffers.deinit();
        vulkanLog("framebuffers created", .{});

        const command_pool = try createCommandPool(vkd, device, physical_device.graphics_family);
        errdefer vkd.destroyCommandPool(device, command_pool, allocation_callbacks);
        vulkanLog("command pool created", .{});

        const command_buffers = try createCommandBuffers(vkd, device, command_pool);
        vulkanLog("command buffer created", .{});

        const sync = try Sync.init(vkd, device);
        errdefer sync.deinit();
        vulkanLog("sync objects created", .{});

        return .{
            .vki = vki,
            .vkd = vkd,
            .allocator = allocator,
            .window = window,
            .instance = instance,
            .surface = surface,
            .physical_device = physical_device,
            .device = device,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .compute_queue = compute_queue,
            .transfer_queue = transfer_queue,
            .swapchain = swapchain,
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .render_pass = render_pass,
            .graphics_pipeline = graphics_pipeline,
            .framebuffers = framebuffers,
            .command_pool = command_pool,
            .command_buffers = command_buffers,
            .sync = sync,
            .debug_messenger = debug_messenger,
        };
    }

    pub fn deinit(self: *Self) void {
        self.sync.deinit();
        vulkanLog("sync objects destroyed", .{});

        self.vkd.destroyCommandPool(self.device, self.command_pool, allocation_callbacks);
        vulkanLog("command pool destroyed", .{});

        self.framebuffers.deinit();
        vulkanLog("framebuffers destroyed", .{});

        self.graphics_pipeline.deinit();
        vulkanLog("graphics pipeline destroyed", .{});

        self.vkd.destroyRenderPass(self.device, self.render_pass, allocation_callbacks);
        vulkanLog("render pass destroyed", .{});

        self.vkd.destroyShaderModule(self.device, self.fragment_shader, allocation_callbacks);
        vulkanLog("fragment shader destroyed", .{});

        self.vkd.destroyShaderModule(self.device, self.vertex_shader, allocation_callbacks);
        vulkanLog("vertex shader destroyed", .{});

        self.swapchain.deinit();
        vulkanLog("swapchain destroyed", .{});

        self.vkd.destroyDevice(self.device, allocation_callbacks);
        vulkanLog("device destroyed", .{});

        self.vki.destroySurfaceKHR(self.instance, self.surface, allocation_callbacks);
        vulkanLog("surface destroyed", .{});

        deinitDebugMessenger(self.instance, self.vki, self.debug_messenger);
        vulkanLog("debug messenger destroyed", .{});

        self.vki.destroyInstance(self.instance, allocation_callbacks);
        vulkanLog("instance destroyed", .{});
    }

    pub fn drawFrame(self: *Self) !void {
        const fences = [_]vk.Fence{self.sync.in_flight_fences[self.current_frame]};
        _ = try self.vkd.waitForFences(self.device, fences.len, &fences, vk.TRUE, std.math.maxInt(u64));

        const next_image_result = self.vkd.acquireNextImageKHR(
            self.device,
            self.swapchain.handle,
            std.math.maxInt(u64),
            self.sync.image_available_semaphores[self.current_frame],
            .null_handle,
        ) catch |err| {
            if (err == error.OutOfDateKHR) {
                try self.recreateSwapchain();
                return;
            }
            return err;
        };
        const index = next_image_result.image_index;

        try self.vkd.resetFences(self.device, fences.len, &fences);

        try self.vkd.resetCommandBuffer(self.command_buffers[self.current_frame], .{});
        try recordCommandBuffer(
            self.vkd,
            self.command_buffers[self.current_frame],
            self.render_pass,
            self.framebuffers.handles[index],
            self.swapchain.extent,
            self.graphics_pipeline.handle,
        );

        const wait_semaphores = [_]vk.Semaphore{self.sync.image_available_semaphores[self.current_frame]};
        const wait_stages = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
        const command_buffers = [_]vk.CommandBuffer{self.command_buffers[self.current_frame]};
        const signal_semaphores = [_]vk.Semaphore{self.sync.render_finished_semaphores[self.current_frame]};
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = wait_semaphores.len,
            .p_wait_semaphores = &wait_semaphores,
            .p_wait_dst_stage_mask = &wait_stages,
            .command_buffer_count = command_buffers.len,
            .p_command_buffers = &command_buffers,
            .signal_semaphore_count = signal_semaphores.len,
            .p_signal_semaphores = &signal_semaphores,
        };
        const submits = [_]vk.SubmitInfo{submit_info};

        try self.vkd.queueSubmit(self.graphics_queue, submits.len, &submits, self.sync.in_flight_fences[self.current_frame]);

        const swapchains = [_]vk.SwapchainKHR{self.swapchain.handle};
        const indices = [_]u32{index};
        const present_info = vk.PresentInfoKHR{
            .wait_semaphore_count = signal_semaphores.len,
            .p_wait_semaphores = &signal_semaphores,
            .swapchain_count = swapchains.len,
            .p_swapchains = &swapchains,
            .p_image_indices = &indices,
        };

        const present_result = self.vkd.queuePresentKHR(self.present_queue, &present_info) catch |err| {
            if (err == error.OutOfDateKHR) {
                try self.recreateSwapchain();
                return;
            }
            return err;
        };

        if (present_result == vk.Result.suboptimal_khr or self.framebuffer_resized) {
            self.framebuffer_resized = false;
            try self.recreateSwapchain();
        }

        self.current_frame = (self.current_frame + 1) % max_frames_in_flight;
    }

    pub fn waitForIdle(self: *const Self) !void {
        try self.vkd.deviceWaitIdle(self.device);
    }

    pub fn recreateSwapchain(self: *Self) !void {
        var size = self.window.getFramebufferSize();
        while (size.width == 0 or size.height == 0) {
            size = self.window.getFramebufferSize();
            glfw.waitEvents();
        }
        try self.waitForIdle();
        try self.swapchain.recreate();
        try self.framebuffers.recreate(&self.swapchain, self.render_pass);
    }
};

fn framebufferSizeCallback(window: glfw.Window, _: u32, _: u32) void {
    var ctx = window.getUserPointer(Ctx);
    if (ctx == null) {
        std.log.warn("glfw: resize callback user pointer null", .{});
        return;
    }

    ctx.?.framebuffer_resized = true;
}

fn recordCommandBuffer(
    vkd: DeviceFunctions,
    command_buffer: vk.CommandBuffer,
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
    extent: vk.Extent2D,
    graphics_pipeline: vk.Pipeline,
) !void {
    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{},
        .p_inheritance_info = null,
    };

    try vkd.beginCommandBuffer(command_buffer, &begin_info);

    const clear_colors = [_]vk.ClearValue{
        .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } },
    };
    const render_pass_begin_info = vk.RenderPassBeginInfo{
        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        },
        .clear_value_count = clear_colors.len,
        .p_clear_values = &clear_colors,
    };

    vkd.cmdBeginRenderPass(command_buffer, &render_pass_begin_info, .@"inline");
    vkd.cmdBindPipeline(command_buffer, .graphics, graphics_pipeline);

    const viewports = [_]vk.Viewport{
        .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(extent.width),
            .height = @floatFromInt(extent.height),
            .min_depth = 0,
            .max_depth = 1,
        },
    };
    vkd.cmdSetViewport(command_buffer, 0, viewports.len, &viewports);

    const scissors = [_]vk.Rect2D{
        .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        },
    };
    vkd.cmdSetScissor(command_buffer, 0, scissors.len, &scissors);

    vkd.cmdDraw(command_buffer, 3, 1, 0, 0);
    vkd.cmdEndRenderPass(command_buffer);

    try vkd.endCommandBuffer(command_buffer);
}

fn createCommandBuffers(
    vkd: DeviceFunctions,
    device: vk.Device,
    command_pool: vk.CommandPool,
) ![max_frames_in_flight]vk.CommandBuffer {
    const command_buffer_create_info = vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = max_frames_in_flight,
    };

    var command_buffers = [_]vk.CommandBuffer{.null_handle} ** max_frames_in_flight;
    try vkd.allocateCommandBuffers(device, &command_buffer_create_info, &command_buffers);
    return command_buffers;
}

fn createCommandPool(vkd: DeviceFunctions, device: vk.Device, queue_family: u32) !vk.CommandPool {
    const command_pool_create_info = vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = queue_family,
    };
    return vkd.createCommandPool(device, &command_pool_create_info, allocation_callbacks);
}

fn createRenderPass(vkd: DeviceFunctions, device: vk.Device, format: vk.Format) !vk.RenderPass {
    const color_attachments = [_]vk.AttachmentDescription{
        .{
            .format = format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        },
    };

    const color_attachment_refs = [_]vk.AttachmentReference{
        .{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        },
    };

    const subpasses = [_]vk.SubpassDescription{
        .{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = color_attachment_refs.len,
            .p_color_attachments = &color_attachment_refs,
        },
    };

    const dependencies = [_]vk.SubpassDependency{
        .{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{},
            .dst_access_mask = .{ .color_attachment_write_bit = true },
        },
    };

    const render_pass_create_info = vk.RenderPassCreateInfo{
        .attachment_count = color_attachments.len,
        .p_attachments = &color_attachments,
        .subpass_count = subpasses.len,
        .p_subpasses = &subpasses,
        .dependency_count = dependencies.len,
        .p_dependencies = &dependencies,
    };

    return vkd.createRenderPass(device, &render_pass_create_info, allocation_callbacks);
}

fn createImageViews(
    vkd: DeviceFunctions,
    allocator: Allocator,
    device: vk.Device,
    images: []vk.Image,
    format: vk.Format,
) ![]vk.ImageView {
    const image_views = try allocator.alloc(vk.ImageView, images.len);
    errdefer allocator.free(image_views);

    for (images, image_views) |image, *view| {
        const create_info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        view.* = try vkd.createImageView(device, &create_info, allocation_callbacks);
    }

    return image_views;
}

fn fetchSwapchainImages(
    vkd: DeviceFunctions,
    allocator: Allocator,
    device: vk.Device,
    swapchain: vk.SwapchainKHR,
) ![]vk.Image {
    var image_count: u32 = 0;
    _ = try vkd.getSwapchainImagesKHR(device, swapchain, &image_count, null);

    const swapchain_images = try allocator.alloc(vk.Image, image_count);
    errdefer allocator.free(swapchain_images);

    _ = try vkd.getSwapchainImagesKHR(device, swapchain, &image_count, swapchain_images.ptr);

    return swapchain_images;
}

fn createSwapchain(
    vkd: DeviceFunctions,
    physical_device: PhysicalDevice,
    device: vk.Device,
    surface: vk.SurfaceKHR,
    surface_format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    surface_capabilities: vk.SurfaceCapabilitiesKHR,
    extent: vk.Extent2D,
) !vk.SwapchainKHR {
    var image_count = surface_capabilities.min_image_count + 1;
    if (surface_capabilities.max_image_count > 0 and image_count > surface_capabilities.max_image_count) {
        image_count = surface_capabilities.max_image_count;
    }

    const same_family = physical_device.graphics_family == physical_device.present_family;
    const queue_family_indices = [_]u32{ physical_device.graphics_family, physical_device.present_family };
    const swapchain_create_info = vk.SwapchainCreateInfoKHR{
        .surface = surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = if (same_family) .exclusive else .concurrent,
        .queue_family_index_count = if (same_family) 0 else 2,
        .p_queue_family_indices = if (same_family) null else &queue_family_indices,
        .pre_transform = surface_capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
    };

    return vkd.createSwapchainKHR(device, &swapchain_create_info, allocation_callbacks);
}

fn pickSwapSurfaceFormat(
    vki: InstanceFunctions,
    allocator: Allocator,
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !vk.SurfaceFormatKHR {
    var format_count: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null);

    var surface_formats = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
    defer allocator.free(surface_formats);

    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, surface_formats.ptr);

    for (surface_formats) |surface_format| {
        if (surface_format.format == .b8g8r8a8_srgb and surface_format.color_space == .srgb_nonlinear_khr) {
            return surface_format;
        }
    }

    return surface_formats[0];
}

fn pickSwapPresentMode(
    vki: InstanceFunctions,
    allocator: Allocator,
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !vk.PresentModeKHR {
    var present_mode_count: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, null);

    var present_modes = try allocator.alloc(vk.PresentModeKHR, present_mode_count);
    defer allocator.free(present_modes);

    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, present_modes.ptr);

    for (present_modes) |present_mode| {
        if (present_mode == .mailbox_khr) {
            return present_mode;
        }
    }

    return .fifo_khr; // This mode is guaranteed to be present
}

fn pickSwapExtent(
    surface_capabilities: vk.SurfaceCapabilitiesKHR,
    window: glfw.Window,
) !vk.Extent2D {
    if (surface_capabilities.current_extent.width != std.math.maxInt(u32)) {
        return surface_capabilities.current_extent;
    }

    const size = window.getFramebufferSize();

    if (size.width == 0 or size.height == 0) {
        return error.FailedToGetFramebufferSize;
    }

    var actual_extent = vk.Extent2D{
        .width = size.width,
        .height = size.height,
    };

    actual_extent.width = std.math.clamp(
        actual_extent.width,
        actual_extent.width,
        surface_capabilities.min_image_extent.width,
    );

    actual_extent.height = std.math.clamp(
        actual_extent.height,
        actual_extent.height,
        surface_capabilities.min_image_extent.height,
    );

    return actual_extent;
}

fn physicalDeviceHasPortabilitySubsetExtension(
    vki: InstanceFunctions,
    allocator: Allocator,
    physical_device: PhysicalDevice,
) !bool {
    var extension_count: u32 = 0;
    _ = try vki.enumerateDeviceExtensionProperties(physical_device.handle, null, &extension_count, null);

    const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
    defer allocator.free(extensions);

    _ = try vki.enumerateDeviceExtensionProperties(physical_device.handle, null, &extension_count, extensions.ptr);

    for (extensions) |extension| {
        if (std.mem.orderZ(u8, @as([*:0]const u8, @ptrCast(&extension.extension_name)), vk.extension_info.khr_portability_subset.name) == .eq) {
            return true;
        }
    }

    return false;
}

fn createLogicalDevice(vki: InstanceFunctions, allocator: Allocator, physical_device: PhysicalDevice) !vk.Device {
    var unique_queues_families = std.AutoHashMap(u32, void).init(allocator);
    defer unique_queues_families.deinit();

    try unique_queues_families.put(physical_device.graphics_family, {});
    try unique_queues_families.put(physical_device.present_family, {});
    try unique_queues_families.put(physical_device.compute_family, {});
    try unique_queues_families.put(physical_device.transfer_family, {});

    var queue_create_infos = std.ArrayList(vk.DeviceQueueCreateInfo).init(allocator);
    defer queue_create_infos.deinit();

    const queue_priority = [_]f32{1};

    var it = unique_queues_families.iterator();
    while (it.next()) |queue_family| {
        const queue_create_info = vk.DeviceQueueCreateInfo{
            .queue_family_index = queue_family.key_ptr.*,
            .queue_count = 1,
            .p_queue_priorities = &queue_priority,
        };
        try queue_create_infos.append(queue_create_info);
    }

    const physical_device_features = vk.PhysicalDeviceFeatures{};

    var extensions = std.ArrayList([*:0]const u8).init(allocator);
    defer extensions.deinit();

    for (required_device_extensions) |e| {
        try extensions.append(e);
    }

    if (try physicalDeviceHasPortabilitySubsetExtension(vki, allocator, physical_device)) {
        try extensions.append(vk.extension_info.khr_portability_subset.name);
    }

    const device_create_info = vk.DeviceCreateInfo{
        .queue_create_info_count = @as(u32, @intCast(queue_create_infos.items.len)),
        .p_queue_create_infos = queue_create_infos.items.ptr,
        .p_enabled_features = &physical_device_features,
        .enabled_extension_count = @intCast(extensions.items.len),
        .pp_enabled_extension_names = @as([*]const [*:0]const u8, @ptrCast(extensions.items)),
        .enabled_layer_count = if (enable_validation) @as(u32, @intCast(validation_layers.len)) else 0,
        .pp_enabled_layer_names = if (enable_validation) &validation_layers else null,
    };

    return vki.createDevice(physical_device.handle, &device_create_info, allocation_callbacks);
}

fn createInstance(vkb: BaseFunctions, allocator: Allocator, app_name: [*:0]const u8) !vk.Instance {
    if (enable_validation and !try checkValidationLayerSupport(vkb, allocator)) {
        return error.ValidationLayerRequestedButNotAvailable;
    }

    const app_info = vk.ApplicationInfo{
        .p_application_name = app_name,
        .application_version = vk.makeApiVersion(0, 1, 0, 0),
        .p_engine_name = app_name,
        .engine_version = vk.makeApiVersion(0, 1, 0, 0),
        .api_version = vk.API_VERSION_1_2,
    };

    const extensions = try getRequiredExtensions(allocator);
    defer allocator.free(extensions);

    const debug_messenger_create_info = createDebugMessengerCreateInfo();
    return try vkb.createInstance(
        &.{
            .p_application_info = &app_info,
            .enabled_extension_count = @as(u32, @intCast(extensions.len)),
            .pp_enabled_extension_names = extensions.ptr,
            .enabled_layer_count = if (enable_validation) @as(u32, @intCast(validation_layers.len)) else 0,
            .pp_enabled_layer_names = if (enable_validation) &validation_layers else null,
            .p_next = if (enable_validation) &debug_messenger_create_info else null,
        },
        allocation_callbacks,
    );
}

fn getRequiredExtensions(allocator: Allocator) ![][*:0]const u8 {
    const glfw_extensions = glfw.getRequiredInstanceExtensions() orelse return error.FailedToFetchGlfwRequiredExtensions;

    var extensions = std.ArrayList([*:0]const u8).init(allocator);
    errdefer extensions.deinit();

    for (glfw_extensions) |ext| {
        try extensions.append(ext);
    }

    if (enable_validation) {
        try extensions.appendSlice(&debug_extensions);
    }

    return extensions.toOwnedSlice();
}

fn checkValidationLayerSupport(vkb: BaseFunctions, allocator: Allocator) !bool {
    var layer_count: u32 = 0;
    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, null);

    var layer_properties = try allocator.alloc(vk.LayerProperties, layer_count);
    defer allocator.free(layer_properties);

    _ = try vkb.enumerateInstanceLayerProperties(&layer_count, layer_properties.ptr);

    for (validation_layers) |layer_name| {
        var layer_found = false;

        for (layer_properties) |layer| {
            if (std.mem.orderZ(u8, @as([*:0]const u8, @ptrCast(&layer.layer_name)), layer_name) == .eq) {
                layer_found = true;
                break;
            }
        }

        if (!layer_found) return false;
    }

    return true;
}

fn createDebugMessengerCreateInfo() vk.DebugUtilsMessengerCreateInfoEXT {
    const msg_severity = vk.DebugUtilsMessageSeverityFlagsEXT{
        .verbose_bit_ext = true,
        .info_bit_ext = true,
        .warning_bit_ext = true,
        .error_bit_ext = true,
    };

    const msg_types = vk.DebugUtilsMessageTypeFlagsEXT{
        .general_bit_ext = true,
        .validation_bit_ext = true,
        .performance_bit_ext = true,
    };

    return .{
        .message_severity = msg_severity,
        .message_type = msg_types,
        .pfn_user_callback = debugMessageCallback,
    };
}

fn initDebugMessenger(instance: vk.Instance, vki: InstanceFunctions) !DebugMessenger {
    if (!enable_validation) return;

    const create_info = createDebugMessengerCreateInfo();
    return vki.createDebugUtilsMessengerEXT(
        instance,
        &create_info,
        allocation_callbacks,
    );
}

fn deinitDebugMessenger(instance: vk.Instance, vki: InstanceFunctions, debug_messenger: DebugMessenger) void {
    if (!enable_validation) return;

    vki.destroyDebugUtilsMessengerEXT(instance, debug_messenger, allocation_callbacks);
}

fn debugMessageCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    if (p_callback_data) |data| {
        const format = "vulkan validation: {s}";
        const msg = std.mem.sliceTo(data.p_message, 0);

        if (severity.error_bit_ext) {
            std.log.err(format, .{msg});
        } else if (severity.warning_bit_ext) {
            std.log.warn(format, .{msg});
        } else if (severity.info_bit_ext) {
            // std.log.info(format, .{msg});
        } else {
            // std.log.debug(format, .{msg});
        }
    }
    return vk.FALSE;
}

fn vulkanLog(comptime format: []const u8, args: anytype) void {
    std.log.info("vulkan: " ++ format, args);
}

fn createWindowSurface(instance: vk.Instance, window: glfw.Window) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    if (glfw.createWindowSurface(instance, window, allocation_callbacks, &surface) != @intFromEnum(vk.Result.success)) {
        return error.SurfaceCreationFailed;
    }

    return surface;
}

fn pickPhysicalDevice(
    instance: vk.Instance,
    vki: InstanceFunctions,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !PhysicalDevice {
    const physical_device_handles = try listSuitablePhysicalDevices(instance, vki, allocator, surface);
    defer allocator.free(physical_device_handles);

    const physical_devices = try allocator.alloc(PhysicalDevice, physical_device_handles.len);
    defer allocator.free(physical_devices);

    for (physical_devices, physical_device_handles) |*device, handle| {
        device.* = try PhysicalDevice.init(vki, allocator, handle, surface);
    }

    std.sort.insertion(PhysicalDevice, physical_devices, {}, comparePhysicalDevices);

    return physical_devices[0];
}

fn comparePhysicalDevices(_: void, a: PhysicalDevice, b: PhysicalDevice) bool {
    const a_is_discrete = a.properties.device_type == .discrete_gpu;
    const b_is_discrete = b.properties.device_type == .discrete_gpu;
    if (a_is_discrete != b_is_discrete) {
        return a_is_discrete;
    }

    const a_local_vram = getLocalMemorySize(&a);
    const b_local_vram = getLocalMemorySize(&b);
    if (a_local_vram != b_local_vram) {
        return a_local_vram > b_local_vram;
    }

    return true;
}

fn getLocalMemorySize(physical_device: *const PhysicalDevice) vk.DeviceSize {
    const count = physical_device.memory_properties.memory_heap_count;
    for (physical_device.memory_properties.memory_heaps[0..count]) |heap| {
        if (heap.flags.device_local_bit) {
            return heap.size;
        }
    } else {
        return 0;
    }
}

fn listSuitablePhysicalDevices(
    instance: vk.Instance,
    vki: InstanceFunctions,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) ![]vk.PhysicalDevice {
    var device_count: u32 = 0;
    _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);

    const physical_devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(physical_devices);

    _ = try vki.enumeratePhysicalDevices(instance, &device_count, physical_devices.ptr);

    var suitables = std.ArrayList(vk.PhysicalDevice).init(allocator);
    errdefer suitables.deinit();

    for (physical_devices) |device| {
        if (try isDeviceSuitable(vki, allocator, device, surface)) {
            try suitables.append(device);
        }
    }

    return suitables.toOwnedSlice();
}

fn isDeviceSuitable(
    vki: InstanceFunctions,
    allocator: Allocator,
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !bool {
    if (!try checkDeviceExtensionSupport(vki, allocator, physical_device)) return false;

    const queue_families = try findQueueFamilies(vki, allocator, physical_device, surface);

    const swap_chain_support = try checkSwapchainSupport(vki, physical_device, surface);

    return queue_families.isComplete() and swap_chain_support;
}

fn checkSwapchainSupport(
    vki: InstanceFunctions,
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !bool {
    var format_count: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null);

    var present_mode_count: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkDeviceExtensionSupport(
    vki: InstanceFunctions,
    allocator: Allocator,
    physical_device: vk.PhysicalDevice,
) !bool {
    var extension_count: u32 = 0;
    _ = try vki.enumerateDeviceExtensionProperties(physical_device, null, &extension_count, null);

    const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
    defer allocator.free(extensions);

    _ = try vki.enumerateDeviceExtensionProperties(physical_device, null, &extension_count, extensions.ptr);

    for (required_device_extensions) |extension_name| {
        var extension_found = false;

        for (extensions) |extension| {
            if (std.mem.orderZ(u8, @as([*:0]const u8, @ptrCast(&extension.extension_name)), extension_name) == .eq) {
                extension_found = true;
                break;
            }
        }

        if (!extension_found) return false;
    }

    return true;
}

fn findQueueFamilies(
    vki: InstanceFunctions,
    allocator: Allocator,
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !QueueFamiliesIndices {
    var queue_families_indices = QueueFamiliesIndices{};

    var family_count: u32 = 0;
    vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, null);

    var families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer allocator.free(families);

    vki.getPhysicalDeviceQueueFamilyProperties(physical_device, &family_count, families.ptr);

    for (families, 0..) |family, i| {
        const idx: u32 = @intCast(i);

        if (queue_families_indices.graphics_family == null and family.queue_flags.graphics_bit) {
            queue_families_indices.graphics_family = idx;
        }

        const present_support = try vki.getPhysicalDeviceSurfaceSupportKHR(physical_device, idx, surface) == vk.TRUE;
        if (queue_families_indices.present_family == null and present_support) {
            queue_families_indices.present_family = idx;
        }

        if (queue_families_indices.compute_family == null and family.queue_flags.compute_bit) {
            queue_families_indices.compute_family = idx;
        } else if (queue_families_indices.compute_family != null and family.queue_flags.compute_bit and !family.queue_flags.graphics_bit) {
            queue_families_indices.compute_family = idx;
        }

        if (queue_families_indices.transfer_family == null and family.queue_flags.transfer_bit) {
            queue_families_indices.transfer_family = idx;
        } else if (queue_families_indices.transfer_family != null and family.queue_flags.transfer_bit and !family.queue_flags.compute_bit) {
            queue_families_indices.transfer_family = idx;
        }
    }

    return queue_families_indices;
}

fn loadShaderByteCode(allocator: Allocator, comptime file: []const u8) ![]align(shader_byte_code_align) const u8 {
    const shader_dir = "shaders/";
    const shader = try std.fs.cwd().openFile(shader_dir ++ file, .{});

    const size = try shader.getEndPos();
    if (!std.mem.isAligned(size, shader_byte_code_align)) {
        return error.WrongShaderByteCodeAlignement;
    }

    var byte_code = try allocator.alignedAlloc(u8, shader_byte_code_align, size);
    errdefer allocator.free(byte_code);

    _ = try shader.readAll(byte_code);

    return byte_code;
}

fn createShaderModule(vkd: DeviceFunctions, allocator: Allocator, device: vk.Device, comptime file: []const u8) !vk.ShaderModule {
    const byte_code = try loadShaderByteCode(allocator, file);
    defer allocator.free(byte_code);

    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = byte_code.len,
        .p_code = std.mem.bytesAsSlice(u32, byte_code).ptr,
    };

    return vkd.createShaderModule(device, &create_info, allocation_callbacks);
}
