#version 450

layout (location = 0) in vec3 color;

layout (location = 0) out vec4 frag_color;

void main() {
    const float gamma = 2.2;
    frag_color = vec4(pow(color, vec3(1.0 / gamma)), 1.0);
}
