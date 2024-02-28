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

pub const Writer = struct {
    const ImageInfoList = std.DoublyLinkedList(vk.DescriptorImageInfo);
    const BufferInfoList = std.DoublyLinkedList(vk.DescriptorBufferInfo);
    allocator: std.mem.Allocator,
    image_infos: ImageInfoList,
    buffer_infos: BufferInfoList,
    writes: std.ArrayList(vk.WriteDescriptorSet),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .image_infos = ImageInfoList{},
            .buffer_infos = BufferInfoList{},
            .writes = std.ArrayList(vk.WriteDescriptorSet).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.clear();
        self.writes.deinit();
    }

    pub fn writeImage(
        self: *@This(),
        binding: u32,
        image_view: vk.ImageView,
        layout: vk.ImageLayout,
        sampler: vk.Sampler,
        descriptor_type: vk.DescriptorType,
    ) !void {
        assert(image_view != .null_handle);
        assert(layout != .null_handle);
        assert(sampler != .null_handle);

        switch (descriptor_type) {
            .sampler => std.debug.assert(sampler != .null_handle and image_view == .null_handle and layout == .undefined),
            .combined_image_sampler => std.debug.assert(sampler != .null_handle and image_view != .null_handle and layout != .undefined),
            .sampled_image => std.debug.assert(image_view != .null_handle and layout != .undefined and sampler == .null_handle),
            .storage_image => std.debug.assert(image_view != .null_handle and layout != .undefined and sampler == .null_handle),
            else => @panic("invalid type"),
        }

        const node = try self.allocator.create(ImageInfoList.Node);
        errdefer self.allocator.destroy(node);

        self.image_infos.append(node);

        node.data = .{
            .image_view = image_view,
            .sampler = sampler,
            .image_layout = layout,
        };

        const write: vk.WriteDescriptorSet = .{
            .dst_binding = binding,
            .dst_set = .null_handle,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = descriptor_type,
            .p_image_info = @ptrCast(&node.data),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        try self.writes.append(write);
    }

    pub fn writeBuffer(
        self: *@This(),
        binding: u32,
        buffer: vk.Buffer,
        size: vk.DeviceSize,
        offset: vk.DeviceSize,
        descriptor_type: vk.DescriptorType,
    ) !void {
        assert(buffer != .null_handle);

        assert(descriptor_type == .uniform_buffer or
            descriptor_type == .storage_buffer or
            descriptor_type == .uniform_buffer_dynamic or
            descriptor_type == .storage_buffer_dynamic);

        const node = try self.allocator.create(BufferInfoList.Node);
        errdefer self.allocator.destroy(node);

        self.buffer_infos.append(node);

        node.data = .{
            .buffer = buffer,
            .range = size,
            .offset = offset,
        };

        const write: vk.WriteDescriptorSet = .{
            .dst_binding = binding,
            .dst_set = .null_handle,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = descriptor_type,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&node.data),
            .p_texel_buffer_view = undefined,
        };
        try self.writes.append(write);
    }

    pub fn clear(self: *@This()) void {
        while (self.image_infos.pop()) |node| {
            self.allocator.destroy(node);
        }
        while (self.buffer_infos.pop()) |node| {
            self.allocator.destroy(node);
        }
        self.writes.clearRetainingCapacity();
    }

    pub fn updateSet(self: *@This(), device: vk.Device, set: vk.DescriptorSet) void {
        assert(device != .null_handle);
        assert(set != .null_handle);

        for (self.writes.items) |*write| {
            write.dst_set = set;
        }

        vkd().updateDescriptorSets(device, @intCast(self.writes.items.len), self.writes.items.ptr, 0, null);
    }
};
