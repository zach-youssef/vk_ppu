#version 450

layout(binding = 1) uniform sampler2D texSampler;

layout(location = 0) in vec2 fragTexCoord;

layout(location = 0) out vec4 outColor;

float approxLinearToSRGB(float channel) {
    return exp(log(channel) / 2.2);
}

vec4 approxLinearToSRGB(vec4 color) {
    return vec4(approxLinearToSRGB(color.r), 
                approxLinearToSRGB(color.g), 
                approxLinearToSRGB(color.b), 
                color.a);
}

void main() {
    outColor = approxLinearToSRGB(texture(texSampler, fragTexCoord));
}