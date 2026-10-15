#version 450

#include "bindless.glsl"

// Shared with draw.frag: the material's bindings, then whether to decode the output's sRGB values
layout(push_constant) uniform Indices {
    uint mvp;
    uint frame;
    uint frameSampler;
    uint decodeSrgb;
} indices;

struct Mvp {
    mat4 mvp;
};
BINDLESS_BUFFER(readonly, MvpBuffers, Mvp, mvps);

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inTexCoord;

layout(location = 0) out vec2 fragTexCoord;

void main() {
    gl_Position = mvps[indices.mvp].data.mvp * vec4(inPosition, 0.0, 1.0);
    fragTexCoord = inTexCoord;
}
