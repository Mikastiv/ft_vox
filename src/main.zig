const std = @import("std");
const Engine = @import("Engine.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");
const dispatch = @import("vk_dispatch.zig");
const noise = @import("noise.zig");

pub const vulkan_dispatch = struct {
    pub const device = dispatch.device;
};

const memory_size = 1024 * 1024 * 100;

pub fn main() !void {
    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    _ = c.glfwSetErrorCallback(glfwErrorCallback);

    const memory = try std.heap.page_allocator.alloc(u8, memory_size);
    defer std.heap.page_allocator.free(memory);

    var fba = std.heap.FixedBufferAllocator.init(memory);
    const allocator = fba.allocator();

    const window = try Window.init(allocator, 1920, 1080, "ft_vox");

    var engine = try Engine.init(allocator, window);
    defer engine.deinit();

    try engine.run();

    std.log.info("memory usage: {:.2}", .{std.fmt.fmtIntSizeBin(fba.end_index)});
}

fn glfwErrorCallback(error_code: i32, description: [*c]const u8) callconv(.C) void {
    const glfw_log = std.log.scoped(.glfw);
    glfw_log.err("{d}: {s}\n", .{ error_code, description });
}
