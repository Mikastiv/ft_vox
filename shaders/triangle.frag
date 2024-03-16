#version 450

layout (location = 0) in vec2 uv;
layout (location = 1) in flat uint index;

layout (location = 0) out vec4 frag_color;

layout (set = 0, binding = 1) uniform sampler2DArray block_texture;

void main() {
    vec4 pixel = texture(block_texture, vec3(uv, index));

    const float gamma = 2.2;
    frag_color = pow(pixel, vec4(1.0 / gamma));
}
