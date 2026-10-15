#pragma once

#include <vector>
#include "GameClock.h"

class UniformBufferObject;
class Image;

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
    // at each of kCaptureFrames to <directory>/<frame>.png
    void capture(const std::string& directory);

    // The game frames captured by capture(), which the screenshot tests compare
    static inline const std::vector<uint> kCaptureFrames = {1, 2, 3, 4, 8, 16, 60, 120};

    void init(const std::string& ppuDumpPath, 
              const std::string& oamDumpPath, 
              Control control,
              const std::string& shaderPath,
              std::function<UpdateList(MemoryUpdateComposer&)> composeUpdates);

private:
    // The PPU's output image, as RGBA8 bytes
    std::vector<uint8_t> readFrame();

    PpuSessionConfig config_;
    std::unique_ptr<VulkanApp<F>> app_;

    std::unique_ptr<Buffer<PPUMemory>> ppuUbo_;
    std::unique_ptr<Buffer<OAM>> oamUbo_;
    std::unique_ptr<Buffer<Control>> controlUbo_;

    std::unique_ptr<Buffer<UniformBufferObject>> mvpUbo_;
    std::unique_ptr<Image> frameTexture_;
    std::unique_ptr<VulkanSampler> sampler_;

    std::unique_ptr<Buffer<uint8_t>> stagingBuffer_;

    std::unique_ptr<GameClock> gameClock_;
};