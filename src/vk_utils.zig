const std = @import("std");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const Engine = @import("Engine.zig");

const vkd = vkk.dispatch.vkd;

pub const HandleType = enum {
    image,
    image_view,
    fence,
    command_pool,
    memory,
    render_pass,
};

pub const DeletionEntry = struct {
    handle: usize,
    type: HandleType,
};

pub const DeletionQueue = struct {
    entries: std.ArrayList(DeletionEntry),

    pub fn init(allocator: std.mem.Allocator, initial_size: usize) !@This() {
        return .{
            .entries = try std.ArrayList(DeletionEntry).initCapacity(allocator, initial_size),
        };
    }

    pub fn append(self: *@This(), handle: anytype) !void {
        const T = @TypeOf(handle);
        const handle_type: HandleType = switch (T) {
            vk.Image => .image,
            vk.ImageView => .image_view,
            vk.Fence => .fence,
            vk.CommandPool => .command_pool,
            vk.DeviceMemory => .memory,
            vk.RenderPass => .render_pass,
            else => @compileError("unsupported type: " ++ @typeName(T)),
        };
        const handle_raw: usize = @intFromEnum(handle);

        try self.entries.append(.{ .handle = handle_raw, .type = handle_type });
    }

    pub fn appendImage(self: *@This(), image: Engine.AllocatedImage) !void {
        try self.append(image.handle);
        try self.append(image.memory);
        try self.append(image.view);
    }

    pub fn flush(self: *@This(), device: vk.Device) void {
        var it = std.mem.reverseIterator(self.entries.items);
        while (it.next()) |entry| {
            switch (entry.type) {
                .image => vkd().destroyImage(device, @enumFromInt(entry.handle), null),
                .image_view => vkd().destroyImageView(device, @enumFromInt(entry.handle), null),
                .fence => vkd().destroyFence(device, @enumFromInt(entry.handle), null),
                .command_pool => vkd().destroyCommandPool(device, @enumFromInt(entry.handle), null),
                .memory => vkd().freeMemory(device, @enumFromInt(entry.handle), null),
                .render_pass => vkd().destroyRenderPass(device, @enumFromInt(entry.handle), null),
            }
        }
        self.entries.clearRetainingCapacity();
    }
};
