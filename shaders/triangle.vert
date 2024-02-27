#version 450

const vec3 vertices[] = vec3[](
    vec3(0, -1, 0),
    vec3(-1, 1, 0),
    vec3(1, 1, 0)
);

void main() {
    gl_Position = vec4(vertices[gl_VertexIndex], 1);
}
