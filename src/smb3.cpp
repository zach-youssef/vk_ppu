#include "NesMemory.h"
#include "PpuSession.h"
#include "MetaspriteUpdator.h"

class SMB3PaletteCycle : public GameClock::UpdateFunction {
public:
    SMB3PaletteCycle(StagingRegionHandle handle): GameClock::UpdateFunction(handle) {}

    void execute(void* mappedData) override {
        uint8_t* color = (uint8_t*) mappedData;
        if (*color == 0x37 || *color == 0x7) {
            descending_ = !descending_;
        }
        *color += descending_ ? -0x10 : 0x10;
    }

protected:
    uint getFrequency() const override {
        return 4;
    }

private:
    bool descending_ = true;
};

int main(int argc, char** argv) {
    PpuSessionConfig nesConfig{256, offsetof(nes::Control, yOffset)};
    PpuSession<nes::PPUMemory, nes::OAM, nes::Control> nesSession(nesConfig);

    nesSession.init("smb3/ppu_dump.bin",
                    "smb3/oam_dump.bin",
                    nes::Control{0, 0, 1, 0, 1, 0, 0, {0,0,0,0,0,0,0}},
                    "shaders/spirv/nes.comp.spirv",
                    [](MemoryUpdateComposer& composer) {
                        uint8_t initialColor = 0x17;
                        auto bgPalette3Color2 = composer.addStagingField(BufferIndex::PPU,
                                                                        offsetof(nes::PPUMemory, backgroundPalettes[3]) 
                                                                            + offsetof(nes::Palette, data[2]),
                                                                        sizeof(uint8_t),
                                                                        &initialColor);
                        uint8_t startNametableIdx = 0x00;
                        auto startingNametable = composer.addStagingField(BufferIndex::CONTROL,
                                                                        offsetof(nes::Control, nametableStart),
                                                                        sizeof(uint8_t),
                                                                        &startNametableIdx);
                        uint8_t endNametableIdx = 0x02;
                        auto midframeNametable = composer.addStagingField(BufferIndex::CONTROL,
                                                                        offsetof(nes::Control, nametableStart),
                                                                        sizeof(uint8_t),
                                                                        &endNametableIdx);
                        composer.addUpdate(bgPalette3Color2, 0);
                        composer.addUpdate(startingNametable, 0);
                        composer.addUpdate(midframeNametable, 192);

                        nes::Sprite turtleOAM[6] = {
                            {0xBA, 0xE9, 0x42, 0x06},
                            {0xBA, 0xE7, 0x42, 0x0E},
                            {0xAA, 0xE5, 0x43, 0x06},
                            {0xAA, 0xE3, 0x42, 0x0E},
                            {0x9A, 0xB1, 0x42, 0x06},
                            {0x9A, 0xE1, 0x42, 0x0E},
                        };
                        auto turtleMetasprite = composer.addStagingField(BufferIndex::OAM,
                                                                         offsetof(nes::OAM, sprites[0]),
                                                                         sizeof(turtleOAM),
                                                                         turtleOAM);
                        composer.addUpdate(turtleMetasprite, 0);
                        MetaspriteSize turtleSize{2, 3, sizeof(nes::Sprite)};
                        std::unordered_map<uint8_t, uint8_t> turtleAnimationMap = {
                            {0xE3, 0xEB},
                            {0xEB, 0xE3},
                            {0xE9, 0xEF},
                            {0xEF, 0xE9},
                            {0xE7, 0xED},
                            {0xED, 0xE7},
                        };
                        auto turtleTileUpdator = std::make_unique<MetaspriteTileAnimator>(turtleMetasprite,
                                                                                          turtleSize,
                                                                                          6, //freq
                                                                                          offsetof(nes::Sprite, tileIndex),
                                                                                          turtleAnimationMap);
                        auto turtlePositionUpdator = std::make_unique<MetaspritePositionAnimator>(
                            turtleMetasprite,
                            turtleSize,
                            3, //freq
                            std::pair<size_t, size_t>{offsetof(nes::Sprite, x), offsetof(nes::Sprite, y)},
                            std::pair<uint, uint>{1, 0},
                            std::pair<uint, uint>{256, 240});

                        UpdateList updateList;
                        updateList.emplace_back(std::move(std::make_unique<SMB3PaletteCycle>(bgPalette3Color2)));
                        updateList.emplace_back(std::move(turtleTileUpdator));
                        updateList.emplace_back(std::move(turtlePositionUpdator));
                        return updateList;
                    });

    nesSession.run();

    return 0;
}