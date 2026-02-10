#include "NesMemory.h"
#include "PpuSession.h"

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

    nesSession.init("ppu_dump.bin",
                    "oam_dump.bin",
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

                        UpdateList updateList;
                        updateList.emplace_back(std::move(std::make_unique<SMB3PaletteCycle>(bgPalette3Color2)));
                        return updateList;
                    });

    nesSession.run();

    return 0;
}