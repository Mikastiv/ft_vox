const std = @import("std");
const glfw = @import("glfw.zig");
const c = @import("c.zig");
const gfx = @import("graphics.zig");

pub fn main() !void {
    try glfw.init();
    defer glfw.terminate();

    const window = try glfw.createWindow(800, 600, "test");
    defer glfw.destroyWindow(window);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var ctx = try gfx.Ctx.init(alloc, "scop", window);
    defer ctx.deinit();

    while (!glfw.windowShouldClose(window)) {
        glfw.pollEvents();
    }
}
