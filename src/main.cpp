#include <VulkanApp.h>

#include <iostream>
#include <iterator>
#include <fstream>

#include "NesMemory.h"

static const uint F = 1u;

int main(int argc, char** argv) {
    VulkanApp<F> app(256, 240);
    app.init();

    // attemting to read the PPU memory dump....
    std::ifstream dumpFile(std::string("ppu_dump.bin"), std::ios::binary);
    std::vector<uint8_t> buffer(std::istreambuf_iterator<char>(dumpFile), {});
    nes::PPUMemory ppuMemory;
    std::memcpy(&ppuMemory, buffer.data(), 0x4000);

    return 0;
}