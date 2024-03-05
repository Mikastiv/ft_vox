const std = @import("std");
const Chunk = @import("Chunk.zig");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const Engine = @import("Engine.zig");
const vk_utils = @import("vk_utils.zig");
const mesh = @import("mesh.zig");
const math = @import("math.zig");

const assert = std.debug.assert;
const vkd = vkk.dispatch.vkd;

pub const max_loaded_chunk = 16 * 16 + 16 * 4;

pub const ChunkState = enum {
    empty,
    loaded,
    in_queue,
};

const ChunkUploadQueue = std.BoundedArray(math.Vec3i, 256);

chunk_mapping: std.AutoHashMap(math.Vec3i, usize),
chunks: std.MultiArrayList(Chunk),
states: []ChunkState,
index_counts: []u32,
vertex_buffers: []vk.Buffer,
index_buffers: []vk.Buffer,
vertex_buffer_offsets: []vk.DeviceSize,
index_buffer_offsets: []vk.DeviceSize,
upload_queue: ChunkUploadQueue,

vertex_upload_buffer: std.ArrayList(mesh.Vertex),
index_upload_buffer: std.ArrayList(u16),

timer: std.time.Timer,

pub fn init(
    allocator: std.mem.Allocator,
    device: vk.Device,
    vertex_memory: Engine.AllocatedMemory,
    index_memory: Engine.AllocatedMemory,
    deletion_queue: *vk_utils.DeletionQueue,
) !@This() {
    var hmap = std.AutoHashMap(math.Vec3i, usize).init(allocator);
    try hmap.ensureTotalCapacity(max_loaded_chunk);

    var chunks = std.MultiArrayList(Chunk){};
    try chunks.ensureTotalCapacity(allocator, max_loaded_chunk);
    for (0..max_loaded_chunk) |_| {
        _ = try chunks.addOne(allocator);
    }

    const self: @This() = .{
        .chunk_mapping = hmap,
        .chunks = chunks,
        .states = try allocator.alloc(ChunkState, max_loaded_chunk),
        .index_counts = try allocator.alloc(u32, max_loaded_chunk),
        .vertex_buffers = try allocator.alloc(vk.Buffer, max_loaded_chunk),
        .index_buffers = try allocator.alloc(vk.Buffer, max_loaded_chunk),
        .vertex_buffer_offsets = try allocator.alloc(vk.DeviceSize, max_loaded_chunk),
        .index_buffer_offsets = try allocator.alloc(vk.DeviceSize, max_loaded_chunk),
        .upload_queue = try ChunkUploadQueue.init(0),
        .vertex_upload_buffer = try std.ArrayList(mesh.Vertex).initCapacity(allocator, Chunk.max_vertices),
        .index_upload_buffer = try std.ArrayList(u16).initCapacity(allocator, Chunk.max_indices),
        .timer = try std.time.Timer.start(),
    };

    @memset(self.states, .empty);

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
    if (self.chunk_mapping.get(chunk.pos) != null) return;
    const idx = self.freeSlot() orelse return error.NoFreeChunkSlot;

    self.chunks.set(idx, chunk.*);
    self.states[idx] = .in_queue;
    try self.chunk_mapping.put(chunk.pos, idx);
    try self.upload_queue.append(chunk.pos);
}

pub fn removeChunk(self: *@This(), pos: math.Vec3i) void {
    const idx = self.chunk_mapping.get(pos) orelse return;
    _ = self.chunk_mapping.remove(pos);
    self.states[idx] = .empty;
    for (self.upload_queue.constSlice(), 0..) |p, i| {
        if (math.vec.eql(p, pos)) {
            _ = self.upload_queue.orderedRemove(i);
            break;
        }
    }
}

pub fn uploadChunkFromQueue(self: *@This(), device: vk.Device, cmd: vk.CommandBuffer, staging_buffer: Engine.AllocatedBuffer) !bool {
    if (self.upload_queue.len == 0) return false;

    const pos = self.upload_queue.orderedRemove(0);
    try self.uploadChunk(device, pos, cmd, staging_buffer);

    return true;
}

fn uploadChunk(self: *@This(), device: vk.Device, pos: math.Vec3i, cmd: vk.CommandBuffer, staging_buffer: Engine.AllocatedBuffer) !void {
    const idx = self.chunk_mapping.get(pos) orelse @panic("no chunk");
    assert(self.states[idx] == .in_queue);

    self.vertex_upload_buffer.clearRetainingCapacity();
    self.index_upload_buffer.clearRetainingCapacity();
    try self.chunks.get(idx).generateMesh(&self.vertex_upload_buffer, &self.index_upload_buffer);

    const vertices = self.vertex_upload_buffer.items;
    const indices = self.index_upload_buffer.items;

    const vertex_size = @sizeOf(mesh.Vertex) * vertices.len;
    const index_size = @sizeOf(u16) * indices.len;
    assert(vertex_size + index_size <= Engine.staging_buffer_size);

    {
        const data = try vkd().mapMemory(device, staging_buffer.memory, 0, vertex_size + index_size, .{});
        defer vkd().unmapMemory(device, staging_buffer.memory);

        const ptr: [*]u8 = @ptrCast(@alignCast(data));
        @memcpy(ptr[0..vertex_size], std.mem.sliceAsBytes(vertices));
        @memcpy(ptr[vertex_size .. vertex_size + index_size], std.mem.sliceAsBytes(indices));
    }

    const vertex_copy = vk.BufferCopy{ .size = vertex_size, .src_offset = 0, .dst_offset = 0 };
    vkd().cmdCopyBuffer(cmd, staging_buffer.handle, self.vertex_buffers[idx], 1, @ptrCast(&vertex_copy));

    const index_copy = vk.BufferCopy{ .size = index_size, .src_offset = vertex_size, .dst_offset = 0 };
    vkd().cmdCopyBuffer(cmd, staging_buffer.handle, self.index_buffers[idx], 1, @ptrCast(&index_copy));

    self.states[idx] = .loaded;
    self.index_counts[idx] = @intCast(indices.len);
}

fn freeSlot(self: *const @This()) ?usize {
    for (0..self.states.len) |i| {
        if (self.states[i] == .empty) return i;
    }
    return null;
}
