const c = @import("c.zig");
const std = @import("std");

fn errorCallback(code: c_int, description: [*c]const u8) callconv(.C) void {
    std.log.err("{d} - {s}\n", .{ code, description });
}

pub fn init() !void {
    if (c.glfwInit() != c.GLFW_TRUE) return error.InitFailed;

    _ = c.glfwSetErrorCallback(&errorCallback);
}

pub fn terminate() void {
    c.glfwTerminate();
}

pub fn createWindow(width: i32, height: i32, title: [:0]const u8) !*c.GLFWwindow {
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(width, height, title, null, null) orelse return error.WindowInitFailed;
    return window;
}

pub fn destroyWindow(window: *c.GLFWwindow) void {
    c.glfwDestroyWindow(window);
}

pub fn windowShouldClose(window: *c.GLFWwindow) bool {
    return c.glfwWindowShouldClose(window) == c.GLFW_TRUE;
}

pub fn pollEvents() void {
    c.glfwPollEvents();
}
