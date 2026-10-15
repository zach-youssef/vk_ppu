#version 450

#include "bindless.glsl"

// Shared with draw.vert
layout(push_constant) uniform Indices {
    uint mvp;
    uint frame;
    uint frameSampler;
    uint decodeSrgb;
} indices;

layout(location = 0) in vec2 fragTexCoord;

layout(location = 0) out vec4 outColor;

vec3 srgbToLinear(vec3 color) {
    return mix(color / 12.92, pow((color + 0.055) / 1.055, vec3(2.4)), greaterThan(color, vec3(0.04045)));
}

void main() {
    // The PPU's output holds sRGB-encoded colors. An sRGB surface encodes what's written to it, so
    // decode them first; either way the screen shows the output's values.
    vec4 color = texture(sampler2D(bindlessTextures[indices.frame], bindlessSamplers[indices.frameSampler]), fragTexCoord);
    outColor = indices.decodeSrgb != 0 ? vec4(srgbToLinear(color.rgb), color.a) : color;
}
