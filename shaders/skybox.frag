#version 450

layout (location = 0) in vec3 uv;

layout (location = 0) out vec4 frag_color;

layout (set = 0, binding = 1) uniform samplerCube sky_texture;

void main() {
    vec4 pixel = texture(sky_texture, uv);

    const float gamma = 2.2;
    frag_color = pow(pixel, vec4(1.0 / gamma));
}
