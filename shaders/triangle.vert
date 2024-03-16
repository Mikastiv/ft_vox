#version 450

layout (location = 0) in uint data;

layout (location = 0) out vec2 out_uv;
layout (location = 1) out uint out_index;

layout (set = 0, binding = 0) uniform SceneData {
    mat4 view;
    mat4 proj;
    mat4 view_proj;
} scene_data;

layout (push_constant) uniform PushConstants {
    mat4 model;
} push;

const vec2 uvs[4] = vec2[](
    vec2(0.0, 0.0),
    vec2(0.0, 1.0),
    vec2(1.0, 1.0),
    vec2(1.0, 0.0)
);

void main() {
    uint x = data & 0x1F;
    uint y = (data >> 5) & 0x1F;
    uint z = (data >> 10) & 0x1F;
    uint texture_index = (data >> 15) & 0xFF;
    gl_Position = scene_data.view_proj * push.model * vec4(float(x), float(y), float(z), 1);
    out_uv = uvs[gl_VertexIndex % 4];
    out_index = texture_index;
}
