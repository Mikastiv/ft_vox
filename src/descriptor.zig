const std = @import("std");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const vk_utils = @import("vk_utils.zig");

const assert = std.debug.assert;

const vkd = vkk.dispatch.vkd;

pub const LayoutBuilder = struct {
    bindings: std.ArrayList(vk.DescriptorSetLayoutBinding),

    pub fn init(allocator: std.mem.Allocator, initial_size: usize) !@This() {
        return .{
            .bindings = try std.ArrayList(vk.DescriptorSetLayoutBinding).initCapacity(allocator, initial_size),
        };
    }

    pub fn deinit(self: @This()) void {
        self.bindings.deinit();
    }

    pub fn clear(self: *@This()) void {
        self.bindings.clearRetainingCapacity();
    }

    pub fn addBinding(self: *@This(), binding: u32, descriptor_type: vk.DescriptorType) !void {
        const new_binding: vk.DescriptorSetLayoutBinding = .{
            .binding = binding,
            .descriptor_type = descriptor_type,
            .descriptor_count = 1,
            .stage_flags = .{},
        };
        try self.bindings.append(new_binding);
    }

    pub fn build(self: *const @This(), device: vk.Device, shader_stages: vk.ShaderStageFlags) !vk.DescriptorSetLayout {
        assert(device != .null_handle);

        for (self.bindings.items) |*binding| {
            binding.stage_flags = shader_stages;
        }

        const create_info: vk.DescriptorSetLayoutCreateInfo = .{
            .binding_count = @intCast(self.bindings.items.len),
            .p_bindings = self.bindings.items.ptr,
        };

        return vkd().createDescriptorSetLayout(device, &create_info, null);
    }
};

pub const Allocator = struct {
    pub const PoolSizeRatio = struct {
        type: vk.DescriptorType,
        ratio: f32,
    };

    pool: vk.DescriptorPool,

    pub fn init(
        allocator: std.mem.Allocator,
        device: vk.Device,
        max_sets: u32,
        pool_ratios: []const PoolSizeRatio,
    ) !@This() {
        assert(device != .null_handle);

        const pool_sizes = try allocator.alloc(vk.DescriptorPoolSize, pool_ratios.len);

        for (0..pool_ratios.len) |i| {
            const count = vk_utils.scale(u32, max_sets, pool_ratios[i].ratio);
            pool_sizes[i] = .{ .type = pool_ratios[i].type, .descriptor_count = count };
        }

        const pool_info: vk.DescriptorPoolCreateInfo = .{
            .max_sets = max_sets,
            .pool_size_count = @intCast(pool_sizes.len),
            .p_pool_sizes = pool_sizes.ptr,
        };

        const pool = try vkd().createDescriptorPool(device, &pool_info, null);

        return .{ .pool = pool };
    }

    pub fn clearDescriptors(self: *@This(), device: vk.Device) !void {
        assert(device != .null_handle);
        assert(self.pool != .null_handle);

        try vkd().resetDescriptorPool(device, self.pool, .{});
    }

    pub fn alloc(self: *const @This(), device: vk.Device, layout: vk.DescriptorSetLayout) !vk.DescriptorSet {
        assert(device != .null_handle);
        assert(self.pool != .null_handle);
        assert(layout != .null_handle);

        const alloc_info: vk.DescriptorSetAllocateInfo = .{
            .descriptor_pool = self.pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&layout),
        };

        var descriptor_set: vk.DescriptorSet = undefined;
        try vkd().allocateDescriptorSets(device, &alloc_info, @ptrCast(&descriptor_set));
        return descriptor_set;
    }
};
