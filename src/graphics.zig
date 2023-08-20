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
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .destroySurfaceKHR = true,
    .createDevice = true,
    .createDebugUtilsMessengerEXT = enable_validation,
    .destroyDebugUtilsMessengerEXT = enable_validation,
});

const QueueFamilies = struct {
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
        std.debug.assert(queue_families.isComplete());

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

    allocator: std.mem.Allocator,

    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    physical_device: PhysicalDevice,

    debug_messenger: DebugMessenger,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: *c.GLFWwindow) !Ctx {
        const vkb = try BaseFunctions.load(c.glfwGetInstanceProcAddress);

        const instance = try createInstance(vkb, allocator, app_name);
        const vki = try InstanceFunctions.load(instance, vkb.dispatch.vkGetInstanceProcAddr);
        errdefer vki.destroyInstance(instance, allocation_callbacks);
        vulkanLog("instance created", .{});

        const debug_messenger = try initDebugCallback(instance, vki);
        errdefer deinitDebugCallback(instance, vki, debug_messenger);
        vulkanLog("debug callback initialized", .{});

        const surface = try createWindowSurface(instance, window);
        errdefer vki.destroySurfaceKHR(instance, surface, allocation_callbacks);
        vulkanLog("surface created", .{});

        const physical_device = try pickPhysicalDevice(instance, vki, allocator, surface);
        vulkanLog("selected physical device {s}", .{@as([*:0]const u8, @ptrCast(&physical_device.properties.device_name))});

        return .{
            .vki = vki,
            .allocator = allocator,
            .instance = instance,
            .surface = surface,
            .physical_device = physical_device,
            .debug_messenger = debug_messenger,
        };
    }

    pub fn deinit(self: *Self) void {
        self.vki.destroySurfaceKHR(self.instance, self.surface, allocation_callbacks);
        vulkanLog("surface destroyed", .{});
        deinitDebugCallback(self.instance, self.vki, self.debug_messenger);
        vulkanLog("debug callback destroyed", .{});
        self.vki.destroyInstance(self.instance, allocation_callbacks);
        vulkanLog("instance destroyed", .{});
    }
};

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

fn initDebugCallback(instance: vk.Instance, vki: InstanceFunctions) !DebugMessenger {
    if (!enable_validation) return;

    const create_info = createDebugMessengerCreateInfo();
    return vki.createDebugUtilsMessengerEXT(
        instance,
        &create_info,
        allocation_callbacks,
    );
}

fn deinitDebugCallback(instance: vk.Instance, vki: InstanceFunctions, debug_messenger: DebugMessenger) void {
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

fn pickPhysicalDevice(instance: vk.Instance, vki: InstanceFunctions, allocator: Allocator, surface: vk.SurfaceKHR) !PhysicalDevice {
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

fn listSuitablePhysicalDevices(instance: vk.Instance, vki: InstanceFunctions, allocator: Allocator, surface: vk.SurfaceKHR) ![]vk.PhysicalDevice {
    var device_count: u32 = 0;
    _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);

    const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(devices);

    _ = try vki.enumeratePhysicalDevices(instance, &device_count, devices.ptr);

    var suitables = std.ArrayList(vk.PhysicalDevice).init(allocator);
    errdefer suitables.deinit();

    for (devices) |device| {
        if (try isDeviceSuitable(vki, allocator, device, surface)) {
            try suitables.append(device);
        }
    }

    return suitables.toOwnedSlice();
}

fn isDeviceSuitable(vki: InstanceFunctions, allocator: Allocator, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    if (!try checkDeviceExtensionSupport(vki, allocator, device)) return false;

    const queue_families = try findQueueFamilies(vki, allocator, device, surface);

    const swap_chain_support = try checkSwapChainSupport(vki, device, surface);

    return queue_families.isComplete() and swap_chain_support;
}

fn checkSwapChainSupport(vki: InstanceFunctions, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkDeviceExtensionSupport(vki: InstanceFunctions, allocator: Allocator, device: vk.PhysicalDevice) !bool {
    var extension_count: u32 = 0;
    _ = try vki.enumerateDeviceExtensionProperties(device, null, &extension_count, null);

    const extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
    defer allocator.free(extensions);

    _ = try vki.enumerateDeviceExtensionProperties(device, null, &extension_count, extensions.ptr);

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

fn findQueueFamilies(vki: InstanceFunctions, allocator: Allocator, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !QueueFamilies {
    var queue_families = QueueFamilies{};

    var family_count: u32 = 0;
    vki.getPhysicalDeviceQueueFamilyProperties(device, &family_count, null);

    var families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer allocator.free(families);

    vki.getPhysicalDeviceQueueFamilyProperties(device, &family_count, families.ptr);

    for (families, 0..) |family, i| {
        const idx: u32 = @intCast(i);

        if (queue_families.graphics_family == null and family.queue_count > 0 and family.queue_flags.graphics_bit) {
            queue_families.graphics_family = idx;
        }

        const present_support = try vki.getPhysicalDeviceSurfaceSupportKHR(device, idx, surface) == vk.TRUE;
        if (queue_families.present_family == null and present_support) {
            queue_families.present_family = idx;
        }

        if (queue_families.isComplete()) break;
    }

    return queue_families;
}
