const std = @import("std");
const glfw = @import("glfw.zig");
const c = @import("c.zig");
const gfx = @import("graphics.zig");

const window_width = 800;
const window_height = 600;
const app_name = "scop";

pub fn main() !void {
    try glfw.init();
    defer glfw.terminate();

    const window = try glfw.createWindow(window_width, window_height, app_name);
    defer glfw.destroyWindow(window);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var ctx = try gfx.Ctx.init(alloc, app_name, window);
    defer ctx.deinit();

    while (!glfw.windowShouldClose(window)) {
        glfw.pollEvents();
    }
}
