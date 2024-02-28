#version 450

layout (location = 0) in vec3 position;
layout (location = 1) in vec3 color;

layout (location = 0) out vec3 out_color;

layout (set = 0, binding = 0) uniform SceneData {
    mat4 view;
    mat4 proj;
    mat4 view_proj;
} scene_data;

layout (push_constant) uniform PushConstants {
    mat4 model;
} push;

void main() {
    gl_Position = scene_data.view_proj * push.model * vec4(position, 1);
    out_color = color;
}
