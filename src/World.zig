const std = @import("std");
const Chunk = @import("Chunk.zig");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const Engine = @import("Engine.zig");
const vk_utils = @import("vk_utils.zig");

const vkd = vkk.dispatch.vkd;

const max_loaded_chunk = 32;

chunk_mapping: std.AutoHashMap(Chunk.Pos, usize),
chunks: []Chunk,
in_use: []bool,
vertex_buffers: []vk.Buffer,
index_buffers: []vk.Buffer,
vertex_buffer_offsets: []vk.DeviceSize,
index_buffer_offsets: []vk.DeviceSize,

pub fn init(
    allocator: std.mem.Allocator,
    device: vk.Device,
    vertex_memory: Engine.AllocatedMemory,
    index_memory: Engine.AllocatedMemory,
    deletion_queue: *vk_utils.DeletionQueue,
) !@This() {
    var hmap = std.AutoHashMap(Chunk.Pos, usize).init(allocator);
    try hmap.ensureTotalCapacity(max_loaded_chunk);
    const self: @This() = .{
        .chunk_mapping = hmap,
        .chunks = try allocator.alloc(Chunk, max_loaded_chunk),
        .in_use = try allocator.alloc(bool, max_loaded_chunk),
        .vertex_buffers = try allocator.alloc(vk.Buffer, max_loaded_chunk),
        .index_buffers = try allocator.alloc(vk.Buffer, max_loaded_chunk),
        .vertex_buffer_offsets = try allocator.alloc(vk.DeviceSize, max_loaded_chunk),
        .index_buffer_offsets = try allocator.alloc(vk.DeviceSize, max_loaded_chunk),
    };

    @memset(self.in_use, false);

    for (0..max_loaded_chunk) |i| {
        const vertex_buffer_info: vk.BufferCreateInfo = .{
            .size = Chunk.vertex_buffer_size,
            .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
            .sharing_mode = .exclusive,
        };
        self.vertex_buffers[i] = try vkd().createBuffer(device, &vertex_buffer_info, null);
        try deletion_queue.append(self.vertex_buffers[i]);
        self.vertex_buffer_offsets[i] = i * std.mem.alignForward(vk.DeviceSize, Chunk.vertex_buffer_size, vertex_memory.alignment);
        try vkd().bindBufferMemory(device, self.vertex_buffers[i], vertex_memory.handle, self.vertex_buffer_offsets[i]);

        const index_buffer_info: vk.BufferCreateInfo = .{
            .size = Chunk.index_buffer_size,
            .usage = .{ .transfer_dst_bit = true, .index_buffer_bit = true },
            .sharing_mode = .exclusive,
        };
        self.index_buffers[i] = try vkd().createBuffer(device, &index_buffer_info, null);
        try deletion_queue.append(self.index_buffers[i]);
        self.index_buffer_offsets[i] = i * std.mem.alignForward(vk.DeviceSize, Chunk.index_buffer_size, index_memory.alignment);
        try vkd().bindBufferMemory(device, self.index_buffers[i], index_memory.handle, self.index_buffer_offsets[i]);
    }

    return self;
}

pub fn addChunk(self: *@This(), chunk: *const Chunk) !void {
    const idx = self.freeSlot() orelse return error.NoFreeChunkSlot;

    self.chunks[idx] = chunk.*;
    self.in_use[idx] = true;
    try self.chunk_mapping.put(chunk.pos, idx);
}

pub fn removeChunk(self: *@This(), pos: Chunk.Pos) void {
    const idx = self.chunk_mapping.get(pos) orelse @panic("no chunk");
    _ = self.chunk_mapping.remove(pos);
    self.in_use[idx] = false;
}

fn freeSlot(self: *const @This()) ?usize {
    for (0..self.in_use.len) |i| {
        if (!self.in_use[i]) return i;
    }
    return null;
}
