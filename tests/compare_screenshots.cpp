// Compares a received screenshot with its approved version.
//     compare_screenshots <approved.png> <received.png> [tolerance]
// Pixels match when every channel differs by at most tolerance (default 0). On a mismatch, writes
// <received>.diff.png (differing pixels red, others dimmed) and exits with 1.

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    if (argc != 3 && argc != 4) {
        std::cerr << "Usage: " << argv[0] << " <approved.png> <received.png> [tolerance]" << std::endl;
        return 2;
    }
    const int tolerance = argc == 4 ? std::atoi(argv[3]) : 0;

    int approvedWidth, approvedHeight, receivedWidth, receivedHeight, channels;
    stbi_uc* approved = stbi_load(argv[1], &approvedWidth, &approvedHeight, &channels, 4);
    stbi_uc* received = stbi_load(argv[2], &receivedWidth, &receivedHeight, &channels, 4);
    if (!approved || !received) {
        std::cerr << "Can't read " << (approved ? argv[2] : argv[1]) << std::endl;
        return 2;
    }
    if (approvedWidth != receivedWidth || approvedHeight != receivedHeight) {
        std::cerr << argv[2] << ": size " << receivedWidth << "x" << receivedHeight << " differs from approved "
                  << approvedWidth << "x" << approvedHeight << std::endl;
        return 1;
    }

    const size_t pixels = size_t(approvedWidth) * approvedHeight;
    std::vector<stbi_uc> diff(pixels * 4);
    size_t mismatched = 0;
    int largest = 0;
    for (size_t i = 0; i < pixels; ++i) {
        bool matches = true;
        for (int c = 0; c < 4; ++c) {
            const int delta = std::abs(int(approved[i * 4 + c]) - int(received[i * 4 + c]));
            largest = std::max(largest, delta);
            matches = matches && delta <= tolerance;
        }
        mismatched += matches ? 0 : 1;
        for (int c = 0; c < 3; ++c) {
            diff[i * 4 + c] = matches ? received[i * 4 + c] / 4 : (c == 0 ? 255 : 0);
        }
        diff[i * 4 + 3] = 255;
    }
    stbi_image_free(approved);
    stbi_image_free(received);

    if (mismatched) {
        const std::string diffPath = std::string(argv[2]) + ".diff.png";
        stbi_write_png(diffPath.c_str(), approvedWidth, approvedHeight, 4, diff.data(), approvedWidth * 4);
        std::cerr << argv[2] << ": " << mismatched << " of " << pixels << " pixels differ from " << argv[1]
                  << " (largest channel difference " << largest << "); see " << diffPath << std::endl;
        return 1;
    }
    return 0;
}
