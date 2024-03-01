const std = @import("std");
const c = @import("c.zig");
const vk = @import("vulkan-zig");
const math = @import("math.zig");

const assert = std.debug.assert;

pub const Button = struct {
    down: bool,
};

pub const Keyboard = struct {
    keys: [c.GLFW_KEY_LAST]Button = std.mem.zeroes([c.GLFW_KEY_LAST]Button),
};

pub const Mouse = struct {
    buttons: [c.GLFW_MOUSE_BUTTON_LAST]Button = std.mem.zeroes([c.GLFW_MOUSE_BUTTON_LAST]Button),
    pos: math.Vec2 = .{ 0, 0 },
    delta: math.Vec2 = .{ 0, 0 },
};

width: u32,
height: u32,
title: []const u8,
handle: *c.GLFWwindow,

keyboard: Keyboard = .{},
mouse: Mouse = .{},
framebuffer_resized: bool = false,
minimized: bool = false,

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
    _ = c.glfwSetFramebufferSizeCallback(handle, framebufferResizeCallback);
    _ = c.glfwSetKeyCallback(handle, keyCallback);
    _ = c.glfwSetMouseButtonCallback(handle, mouseCallback);
    _ = c.glfwSetCursorPosCallback(handle, cursorCallback);
    _ = c.glfwSetWindowIconifyCallback(handle, minimizedCallback);

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

fn keyCallback(window: ?*c.GLFWwindow, key: c_int, _: c_int, action: c_int, _: c_int) callconv(.C) void {
    assert(key >= 0);
    if (action == c.GLFW_REPEAT) return;

    const self = getUserPointer(window);
    switch (action) {
        c.GLFW_PRESS => self.keyboard.keys[@intCast(key)].down = true,
        c.GLFW_RELEASE => self.keyboard.keys[@intCast(key)].down = false,
        else => assert(false),
    }
}

fn mouseCallback(window: ?*c.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.C) void {
    assert(button >= 0);
    if (action == c.GLFW_REPEAT) return;

    const self = getUserPointer(window);
    switch (action) {
        c.GLFW_PRESS => self.mouse.buttons[@intCast(button)].down = true,
        c.GLFW_RELEASE => self.mouse.buttons[@intCast(button)].down = false,
        else => assert(false),
    }
}

fn cursorCallback(window: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.C) void {
    const self = getUserPointer(window);

    const pos: math.Vec2 = .{ @floatCast(xpos), @floatCast(ypos) };
    self.mouse.delta = math.vec.sub(pos, self.mouse.pos);
    self.mouse.delta[0] = std.math.clamp(self.mouse.delta[0], -100, 100);
    self.mouse.delta[1] = std.math.clamp(self.mouse.delta[1], -100, 100);
    self.mouse.pos = pos;
}

fn framebufferResizeCallback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
    const self = getUserPointer(window);
    self.framebuffer_resized = true;
    self.width = @intCast(width);
    self.height = @intCast(height);
}

fn minimizedCallback(window: ?*c.GLFWwindow, minimized: c_int) callconv(.C) void {
    const self = getUserPointer(window);
    self.minimized = if (minimized == c.GLFW_TRUE) true else false;
}

fn getUserPointer(window: ?*c.GLFWwindow) *@This() {
    const ptr = c.glfwGetWindowUserPointer(window);
    assert(ptr != null);

    return @ptrCast(@alignCast(ptr.?));
}
