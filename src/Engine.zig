const std = @import("std");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const c = @import("c.zig");

pub fn init() !@This() {
    return .{};
}

pub fn deinit(self: *@This()) void {
    _ = self;
}

pub fn run(self: *@This()) !void {
    _ = self;
}
