#version 450

layout (location = 0) in vec2 uv;
layout (location = 1) in flat uint texture_index;
layout (location = 2) in flat uint face_index;

layout (location = 0) out vec4 frag_color;

layout (set = 0, binding = 1) uniform sampler2DArray block_texture;

const float light_factors[6] = float[](
    0.95, // front
    0.60, // back
    0.85, // east
    0.65, // west
    0.95, // north
    0.5 // south
);

void main() {
    vec4 pixel = texture(block_texture, vec3(uv, texture_index));
    pixel = vec4(pixel.rgb * light_factors[face_index], 1);

    const float gamma = 2.2;
    frag_color = pow(pixel, vec4(1.0 / gamma));
}
