const std = @import("std");
const c = @import("c.zig");
const vk = @import("vulkan-zig");
const assert = std.debug.assert;

width: u32,
height: u32,
title: []const u8,
handle: *c.GLFWwindow,

pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, title: [*:0]const u8) !*@This() {
    assert(width >= 256);
    assert(height >= 144);

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
    const handle = c.glfwCreateWindow(
        @intCast(width),
        @intCast(height),
        title,
        null,
        null,
    ) orelse return error.WindowCreationFailed;

    const self = try allocator.create(@This());

    c.glfwSetWindowUserPointer(handle, self);

    self.* = .{
        .width = width,
        .height = height,
        .title = std.mem.span(title),
        .handle = handle,
    };

    return self;
}

pub fn deinit(self: *@This()) void {
    c.glfwDestroyWindow(self.handle);
}

pub fn shouldClose(self: *const @This()) bool {
    return c.glfwWindowShouldClose(self.handle) == c.GLFW_TRUE;
}

pub fn extent(self: *const @This()) vk.Extent2D {
    return .{
        .width = self.width,
        .height = self.height,
    };
}

pub fn aspectRatio(self: *const @This()) f32 {
    const w: f32 = @floatFromInt(self.width);
    const h: f32 = @floatFromInt(self.height);
    return w / h;
}

pub fn createSurface(self: *const @This(), instance: vk.Instance) !vk.SurfaceKHR {
    assert(instance != .null_handle);

    var surface: vk.SurfaceKHR = undefined;
    const result = c.glfwCreateWindowSurface(instance, self.handle, null, &surface);
    if (result != .success) return error.VulkanSurfaceCreationFailed;

    return surface;
}

fn getUserPointer(window: ?*c.GLFWwindow) *@This() {
    const ptr = c.glfwGetWindowUserPointer(window);
    assert(ptr != null);

    return @ptrCast(@alignCast(ptr.?));
}
