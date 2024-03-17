#version 450

layout (location = 0) in vec3 pos;

layout (location = 0) out vec3 out_uv;

layout (set = 0, binding = 0) uniform SceneData {
    mat4 view;
    mat4 proj;
    mat4 view_proj;
} scene_data;

void main() {
    mat4 view = mat4(mat3(scene_data.view));
    gl_Position = scene_data.proj * view * vec4(pos, 1);
    out_uv = pos;
}
