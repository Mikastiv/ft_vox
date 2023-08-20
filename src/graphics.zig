const std = @import("std");
const vk = @import("vulkan");
const c = @import("c.zig");

const Allocator = std.mem.Allocator;

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
});

const QueueFamiliesIndices = struct {
    const Self = @This();

    graphics_family: ?u32 = null,
    present_family: ?u32 = null,

    fn isComplete(self: Self) bool {
        return self.graphics_family != null and self.present_family != null;
    }
};

const PhysicalDevice = struct {
    const Self = @This();

    handle: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    graphics_family: u32,
    present_family: u32,

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
        };
    }
};

pub const Ctx = struct {
    const Self = @This();

    vki: InstanceFunctions,
    vkd: DeviceFunctions,

    allocator: std.mem.Allocator,

    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    physical_device: PhysicalDevice,
    device: vk.Device,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    swapchain_image_format: vk.Format,
    swapchain_extent: vk.Extent2D,
    swapchain: vk.SwapchainKHR,
    swapchain_images: []vk.Image,
    swapchain_image_views: []vk.ImageView,

    debug_messenger: DebugMessenger,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: *c.GLFWwindow) !Ctx {
        const vkb = try BaseFunctions.load(c.glfwGetInstanceProcAddress);

        const instance = try createInstance(vkb, allocator, app_name);
        const vki = try InstanceFunctions.load(instance, vkb.dispatch.vkGetInstanceProcAddr);
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

        const surface_format = try pickSwapSurfaceFormat(vki, allocator, physical_device.handle, surface);
        vulkanLog("selected swapchain image format {s}", .{@tagName(surface_format.format)});
        vulkanLog("selected swapchain image color space {s}", .{@tagName(surface_format.color_space)});

        const present_mode = try pickSwapPresentMode(vki, allocator, physical_device.handle, surface);
        vulkanLog("selected present mode {s}", .{@tagName(present_mode)});

        const surface_capabilities = try vki.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device.handle, surface);
        const extent = try pickSwapExtent(surface_capabilities, window);
        vulkanLog("selected extent {d}x{d}", .{ extent.width, extent.height });

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
        vulkanLog("swapchain created", .{});

        const swapchain_images = try fetchSwapchainImages(vkd, allocator, device, swapchain);
        errdefer allocator.free(swapchain_images);

        const swapchain_image_views = try createImageViews(vkd, allocator, device, swapchain_images, surface_format.format);
        errdefer allocator.free(swapchain_image_views);
        vulkanLog("swapchain image views created", .{});

        return .{
            .vki = vki,
            .vkd = vkd,
            .allocator = allocator,
            .instance = instance,
            .surface = surface,
            .physical_device = physical_device,
            .device = device,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .swapchain_image_format = surface_format.format,
            .swapchain_extent = extent,
            .swapchain = swapchain,
            .swapchain_images = swapchain_images,
            .swapchain_image_views = swapchain_image_views,
            .debug_messenger = debug_messenger,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.swapchain_image_views) |view| {
            self.vkd.destroyImageView(self.device, view, allocation_callbacks);
        }
        vulkanLog("swapchain image views destroyed", .{});
        self.allocator.free(self.swapchain_image_views);

        self.allocator.free(self.swapchain_images);

        self.vkd.destroySwapchainKHR(self.device, self.swapchain, allocation_callbacks);
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
};

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
    if (surface_capabilities.min_image_count > 0 and image_count > surface_capabilities.max_image_count) {
        image_count = surface_capabilities.max_image_count;
    }
    vulkanLog("backbuffer count {d}", .{image_count});

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
    window: *c.GLFWwindow,
) !vk.Extent2D {
    if (surface_capabilities.current_extent.width != std.math.maxInt(u32)) {
        return surface_capabilities.current_extent;
    }

    var width: i32 = 0;
    var height: i32 = 0;
    c.glfwGetFramebufferSize(window, &width, &height);

    if (width != 0 or height != 0) {
        return error.FailedToGetFramebufferSize;
    }

    var actual_extent = vk.Extent2D{
        .width = @intCast(width),
        .height = @intCast(height),
    };

    actual_extent.width = std.math.clamp(
        actual_extent.width,
        surface_capabilities.min_image_extent.width,
        surface_capabilities.max_image_extent.width,
    );
    actual_extent.height = std.math.clamp(
        actual_extent.height,
        surface_capabilities.min_image_extent.height,
        surface_capabilities.max_image_extent.width,
    );

    return actual_extent;
}

fn createLogicalDevice(vki: InstanceFunctions, allocator: Allocator, physical_device: PhysicalDevice) !vk.Device {
    var unique_queues_families = std.AutoHashMap(u32, void).init(allocator);
    defer unique_queues_families.deinit();

    try unique_queues_families.put(physical_device.graphics_family, {});
    try unique_queues_families.put(physical_device.present_family, {});

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

    const device_create_info = vk.DeviceCreateInfo{
        .queue_create_info_count = @as(u32, @intCast(queue_create_infos.items.len)),
        .p_queue_create_infos = queue_create_infos.items.ptr,
        .p_enabled_features = &physical_device_features,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @as([*]const [*:0]const u8, @ptrCast(&required_device_extensions)),
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
        .api_version = vk.API_VERSION_1_3,
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
    var glfwExtensionCount: u32 = 0;
    const glfwExtensions: [*]const [*:0]const u8 = @ptrCast(c.glfwGetRequiredInstanceExtensions(&glfwExtensionCount));

    var extensions = std.ArrayList([*:0]const u8).init(allocator);
    errdefer extensions.deinit();

    try extensions.appendSlice(glfwExtensions[0..glfwExtensionCount]);

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

fn createWindowSurface(instance: vk.Instance, window: *c.GLFWwindow) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    if (c.glfwCreateWindowSurface(instance, window, null, &surface) != .success) {
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

    return true;
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

    const swap_chain_support = try checkSwapChainSupport(vki, physical_device, surface);

    return queue_families.isComplete() and swap_chain_support;
}

fn checkSwapChainSupport(
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

        if (queue_families_indices.isComplete()) break;
    }

    return queue_families_indices;
}
