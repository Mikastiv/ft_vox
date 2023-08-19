const std = @import("std");
const vk = @import("vulkan");
const c = @import("c.zig");
const glfw = @import("glfw.zig");

const Allocator = std.mem.Allocator;

const enable_validation = std.debug.runtime_safety;
const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
const debug_extensions = [_][*:0]const u8{vk.extension_info.ext_debug_utils.name};
const device_extensions = [_][*:0]const u8{vk.extension_info.khr_swapchain.name};
const allocation_callbacks = null;

const DebugMessenger = if (enable_validation) vk.DebugUtilsMessengerEXT else void;

const BaseFunctions = vk.BaseWrapper(.{
    .createInstance = true,
    .getInstanceProcAddr = true,
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

pub const Ctx = struct {
    const Self = @This();

    vki: InstanceFunctions,

    allocator: std.mem.Allocator,
    instance: vk.Instance,
    surface: vk.SurfaceKHR,

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

        const surface = try glfw.createWindowSurface(instance, window);
        errdefer vki.destroySurfaceKHR(instance, surface, allocation_callbacks);
        vulkanLog("surface created", .{});

        return .{
            .vki = vki,
            .allocator = allocator,
            .instance = instance,
            .surface = surface,
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
    const app_info = vk.ApplicationInfo{
        .p_application_name = app_name,
        .application_version = vk.makeApiVersion(0, 1, 0, 0),
        .p_engine_name = app_name,
        .engine_version = vk.makeApiVersion(0, 1, 0, 0),
        .api_version = vk.API_VERSION_1_3,
    };

    const extensions = try getRequiredExtensions(allocator);
    defer allocator.free(extensions);

    return try vkb.createInstance(
        &.{
            .p_application_info = &app_info,
            .enabled_extension_count = @as(u32, @intCast(extensions.len)),
            .pp_enabled_extension_names = extensions.ptr,
            .enabled_layer_count = if (enable_validation) @as(u32, @intCast(validation_layers.len)) else 0,
            .pp_enabled_layer_names = if (enable_validation) &validation_layers else null,
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

fn initDebugCallback(instance: vk.Instance, vki: InstanceFunctions) !DebugMessenger {
    if (!enable_validation) return;

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

    return vki.createDebugUtilsMessengerEXT(
        instance,
        &.{
            .message_severity = msg_severity,
            .message_type = msg_types,
            .pfn_user_callback = debugMessageCallback,
        },
        allocation_callbacks,
    );
}

fn deinitDebugCallback(instance: vk.Instance, vki: InstanceFunctions, debug_messenger: DebugMessenger) void {
    if (!enable_validation) return;

    vki.destroyDebugUtilsMessengerEXT(instance, debug_messenger, allocation_callbacks);
}

fn debugMessageCallback(
    _: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    if (p_callback_data) |data| {
        std.log.warn("{s}", .{std.mem.sliceTo(data.p_message, 0)});
    }
    return vk.FALSE;
}

fn vulkanLog(comptime format: []const u8, args: anytype) void {
    std.log.info("vulkan: " ++ format, args);
}
