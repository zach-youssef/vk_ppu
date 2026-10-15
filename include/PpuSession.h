#pragma once

#include "GameClock.h"

#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

class VulkanApp;
class RenderGraph;

struct PpuSessionConfig {
    size_t screenWidth;
    size_t yOffsetLocation;
};

using UpdateList = std::vector<std::unique_ptr<GameClock::UpdateFunction>>;

template<typename PPUMemory, typename OAM, typename Control>
class PpuSession {
public:
    PpuSession(PpuSessionConfig config);
    ~PpuSession();

    void run();

    // Runs the session, or with `--capture <directory>` captures kCaptureFrames instead
    int run(int argc, char** argv);

    // Renders kCaptureFrames' last frame, one game frame per rendered frame, writing the PPU's output
    // at each of kCaptureFrames to <directory>/<frame>.png. Throws if Vulkan reported errors.
    void capture(const std::string& directory);

    // The game frames captured by capture(), which the screenshot tests compare
    static inline const std::vector<uint> kCaptureFrames = {1, 2, 3, 4, 8, 16, 60, 120};

    // shaderName is the PPU's compute shader, e.g. "nes.comp"
    void init(const std::string& ppuDumpPath, 
              const std::string& oamDumpPath, 
              Control control,
              const std::string& shaderName,
              std::function<UpdateList(MemoryUpdateComposer&)> composeUpdates);

private:
    PpuSessionConfig config_;

    // Errors reported by validation
    std::mutex errorsMutex_;
    std::vector<std::string> errors_;

    std::unique_ptr<VulkanApp> app_;
    RenderGraph* graph_ = nullptr;
    uint32_t captureNode_ = 0;

    // The CPU's copy of the staging data, which the game clock updates and each frame copies to
    // its staging buffer
    std::vector<uint8_t> stagingData_;
    std::unique_ptr<GameClock> gameClock_;
};
