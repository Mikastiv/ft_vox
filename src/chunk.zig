const mesh = @import("mesh.zig");

pub const Chunk = struct {
    vertices: []mesh.Vertex,
    indices: []u16,
};
