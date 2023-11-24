const std = @import("std");
const glfw = @import("glfw");
const gfx = @import("graphics.zig");

const window_width = 800;
const window_height = 600;
const app_name = "ft_vox";

fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

pub fn main() !void {
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        return error.GlfwInitFailed;
    }
    defer glfw.terminate();

    const window_hints = glfw.Window.Hints{
        .client_api = .no_api,
    };
    const window = glfw.Window.create(window_width, window_height, app_name, null, null, window_hints) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        return error.GlfwWindowCreationFailed;
    };

    glfw.setErrorCallback(errorCallback);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var ctx = try gfx.Ctx.init(alloc, app_name, window);
    defer ctx.deinit();

    window.setUserPointer(&ctx);

    while (!window.shouldClose()) {
        glfw.pollEvents();
        try ctx.drawFrame();
    }

    try ctx.waitForIdle();
}
