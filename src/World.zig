const std = @import("std");
const Chunk = @import("Chunk.zig");
const vk = @import("vulkan-zig");
const vkk = @import("vk-kickstart");
const Engine = @import("Engine.zig");
const vk_utils = @import("vk_utils.zig");
const mesh = @import("mesh.zig");
const math = @import("mksv").math;
const Heightmap = @import("Heightmap.zig");

const assert = std.debug.assert;
const vkd = vkk.dispatch.vkd;

pub const chunk_radius = 8;
pub const max_loaded_chunks = chunk_radius * chunk_radius * chunk_radius * chunk_radius;
pub const max_uploaded_chunks = max_loaded_chunks * 100 * 100;

pub const ChunkState = enum {
    empty,
    loaded,
    in_queue,
};

const ChunkUploadQueue = std.BoundedArray(math.Vec3i, max_loaded_chunks);

chunk_mapping: std.AutoHashMap(math.Vec3i, usize),
chunks: []Chunk,
positions: []math.Vec3i,
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
heightmap: Heightmap,

pub fn init(
    allocator: std.mem.Allocator,
    device: vk.Device,
    vertex_memory: Engine.AllocatedMemory,
    index_memory: Engine.AllocatedMemory,
    deletion_queue: *vk_utils.DeletionQueue,
) !@This() {
    var hmap = std.AutoHashMap(math.Vec3i, usize).init(allocator);
    try hmap.ensureTotalCapacity(max_loaded_chunks);

    const self: @This() = .{
        .chunk_mapping = hmap,
        .chunks = try allocator.alloc(Chunk, max_loaded_chunks),
        .positions = try allocator.alloc(math.Vec3i, max_loaded_chunks),
        .states = try allocator.alloc(ChunkState, max_loaded_chunks),
        .index_counts = try allocator.alloc(u32, max_loaded_chunks),
        .vertex_buffers = try allocator.alloc(vk.Buffer, max_loaded_chunks),
        .index_buffers = try allocator.alloc(vk.Buffer, max_loaded_chunks),
        .vertex_buffer_offsets = try allocator.alloc(vk.DeviceSize, max_loaded_chunks),
        .index_buffer_offsets = try allocator.alloc(vk.DeviceSize, max_loaded_chunks),
        .upload_queue = try ChunkUploadQueue.init(0),
        .vertex_upload_buffer = try std.ArrayList(mesh.Vertex).initCapacity(allocator, Chunk.max_vertices),
        .index_upload_buffer = try std.ArrayList(u16).initCapacity(allocator, Chunk.max_indices),
        .timer = try std.time.Timer.start(),
        .heightmap = try Heightmap.init(allocator),
    };

    @memset(self.states, .empty);

    for (0..max_loaded_chunks) |i| {
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

pub fn addChunk(self: *@This(), pos: math.Vec3i) !void {
    if (self.chunk_mapping.get(pos) != null) return;
    const idx = self.freeSlot() orelse return error.NoFreeChunkSlot;

    self.states[idx] = .in_queue;
    self.positions[idx] = pos;
    try self.chunk_mapping.put(pos, idx);
    try self.upload_queue.append(pos);
    outer: for (0..Chunk.directions.len) |i| {
        const neighbor_idx = self.chunk_mapping.get(pos + Chunk.directions[i]) orelse continue;
        for (self.upload_queue.constSlice()) |p| {
            if (math.vec.eql(p, self.positions[neighbor_idx])) {
                continue :outer;
            }
        }
        try self.upload_queue.append(self.positions[neighbor_idx]);
    }
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
    assert(self.states[idx] != .empty);

    const chunk_heightmap = try self.heightmap.get(.{ pos[0], pos[2] });
    self.chunks[idx].generateChunk(pos, chunk_heightmap);

    self.vertex_upload_buffer.clearRetainingCapacity();
    self.index_upload_buffer.clearRetainingCapacity();
    var neighbor_chunks: [Chunk.directions.len]?*const Chunk = undefined;
    for (0..Chunk.directions.len) |i| {
        const neighbor_idx = self.chunk_mapping.get(pos + Chunk.directions[i]);
        if (neighbor_idx) |n_idx| {
            const ptr = &self.chunks[n_idx];
            const neighbor_pos = self.positions[n_idx];
            const neighbor_heightmap = try self.heightmap.get(.{ neighbor_pos[0], neighbor_pos[2] });
            ptr.generateChunk(neighbor_pos, neighbor_heightmap);
            neighbor_chunks[i] = ptr;
        } else {
            neighbor_chunks[i] = null;
        }
    }
    try self.chunks[idx].generateMesh(&self.vertex_upload_buffer, &self.index_upload_buffer, neighbor_chunks);

    const vertices = self.vertex_upload_buffer.items;
    const indices = self.index_upload_buffer.items;

    const vertex_size = @sizeOf(mesh.Vertex) * vertices.len;
    const index_size = @sizeOf(u16) * indices.len;
    self.states[idx] = .loaded;
    self.index_counts[idx] = @intCast(indices.len);
    assert(vertex_size + index_size <= Engine.staging_buffer_size);
    if (indices.len == 0) return;

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
}

fn freeSlot(self: *const @This()) ?usize {
    for (0..self.states.len) |i| {
        if (self.states[i] == .empty) return i;
    }
    return null;
}

pub const ChunkData = struct {
    data: *Chunk,
    position: math.Vec3i,
    state: ChunkState,
    vertex_buffer: vk.Buffer,
    index_buffer: vk.Buffer,
    index_count: u32,
};

pub const ChunkIterator = struct {
    current: usize = 0,
    chunks: []Chunk,
    positions: []math.Vec3i,
    states: []ChunkState,
    vertex_buffers: []vk.Buffer,
    index_buffers: []vk.Buffer,
    index_counts: []u32,

    pub fn next(self: *@This()) ?ChunkData {
        while (self.current < self.chunks.len) {
            if (self.states[self.current] != .empty) break;
            self.current += 1;
        }
        if (self.current >= self.chunks.len) return null;

        const idx = self.current;
        self.current += 1;

        return .{
            .data = &self.chunks[idx],
            .position = self.positions[idx],
            .state = self.states[idx],
            .vertex_buffer = self.vertex_buffers[idx],
            .index_buffer = self.index_buffers[idx],
            .index_count = self.index_counts[idx],
        };
    }
};

pub fn chunkIterator(self: *@This()) ChunkIterator {
    return .{
        .chunks = self.chunks,
        .positions = self.positions,
        .states = self.states,
        .vertex_buffers = self.vertex_buffers,
        .index_buffers = self.index_buffers,
        .index_counts = self.index_counts,
    };
}
