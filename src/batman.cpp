#include "NesMemory.h"
#include "PpuSession.h"
#include "BufferCycler.h"

#include <format>
#include <fstream>

static const uint FRAMES = 8;
static const std::string pathPrefix = "/Users/zyoussef/code/ppu/";
static const size_t animOffset = offsetof(nes::PPUMemory, tileSets[0]) + offsetof(nes::TileSet, tiles[0xC0]);

class BatmanTilesetAnimator : public GameClock::UpdateFunction {
public:
    BatmanTilesetAnimator(StagingRegionHandle handle): GameClock::UpdateFunction(handle) {
        for (uint i = 0; i < FRAMES; ++i) {
            std::ifstream dumpFile(std::format("{}/batman/tileframes/{}.bin", pathPrefix, i), 
                                   std::ios::binary);
            ppuDumps_[i] = std::vector<uint8_t>(std::istreambuf_iterator<char>(dumpFile), {});
        }
    }

    void execute(void* mappedData) override {
        memcpy(mappedData, ppuDumps_[idx_].data() + animOffset, handle_.size);
        idx_ = (idx_ + 1) % FRAMES;
    }

protected:
    uint getFrequency() const override {
        return 2;
    }
private:
    std::array<std::vector<uint8_t>, FRAMES> ppuDumps_;
    uint8_t idx_ = 0;
};

class NesOamCycler : public GameClock::UpdateFunction {
public:
    NesOamCycler(StagingRegionHandle handle): GameClock::UpdateFunction(handle) {
        std::ifstream dumpFile(std::format("{}/batman/oam_dump.bin", pathPrefix), std::ios::binary);
        std::vector<uint8_t> buffer(std::istreambuf_iterator<char>(dumpFile), {});
        bufferCycler = BufferCycler(std::move(buffer));
    }

    void execute(void* mappedData) override {
        memcpy(mappedData, bufferCycler.cycleBuffer(sizeof(nes::Sprite)).data(), handle_.size);
    }
protected:
    uint getFrequency() const override {
        return 1;
    }
private:
    BufferCycler bufferCycler;
};

int main(int argc, char** argv) {
    PpuSessionConfig nesConfig{256, offsetof(nes::Control, yOffset)};
    PpuSession<nes::PPUMemory, nes::OAM, nes::Control> nesSession(nesConfig);

    nesSession.init("batman/ppu_dump.bin",
                    "batman/oam_dump.bin",
                    nes::Control{0, 0, 1, 0, 1, 0, 0, {0,0,0,0,0,0,0}},
                    "shaders/spirv/nes.comp.spirv",
                    [](MemoryUpdateComposer& composer) {
                        auto animTiles = composer.addStagingField(BufferIndex::PPU, 
                                                                  animOffset,
                                                                  (0xF9 - 0xC0) * sizeof(nes::Tile));
                        composer.addUpdate(animTiles, 0);

                        auto oam = composer.addStagingField(BufferIndex::OAM,
                                                            0,
                                                            sizeof(nes::OAM));
                        composer.addUpdate(oam, 0);

                        UpdateList updateList;
                        updateList.emplace_back(std::move(std::make_unique<BatmanTilesetAnimator>(animTiles)));
                        updateList.emplace_back(std::move(std::make_unique<NesOamCycler>(oam)));
                        return updateList;
                    });

    nesSession.run();

    return EXIT_SUCCESS;
}