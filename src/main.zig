const std = @import("std");
const Engine = @import("Engine.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

pub fn main() !void {
    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    _ = c.glfwSetErrorCallback(glfwErrorCallback);

    const memory = try std.heap.page_allocator.alloc(u8, 1024 * 1024 * 500);
    defer std.heap.page_allocator.free(memory);

    var fba = std.heap.FixedBufferAllocator.init(memory);
    const allocator = fba.allocator();

    const window = try Window.init(allocator, 1700, 900, "ft_vox");

    var engine = try Engine.init();
    defer engine.deinit();

    try engine.run();

    while (!window.shouldClose()) {
        c.glfwPollEvents();
    }
}

fn glfwErrorCallback(error_code: i32, description: [*c]const u8) callconv(.C) void {
    const glfw_log = std.log.scoped(.glfw);
    glfw_log.err("{d}: {s}\n", .{ error_code, description });
}
