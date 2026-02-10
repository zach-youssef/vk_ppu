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

    void init(const std::string& ppuDumpPath, 
              const std::string& oamDumpPath, 
              Control control,
              const std::string& shaderPath,
              std::function<UpdateList(MemoryUpdateComposer&)> composeUpdates);

private:
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