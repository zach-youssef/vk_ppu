#pragma once

#include <RenderGraph.h>
#include <Renderable.h>

#include <map>

static const uint F = 1u;

struct MemoryUpdate {
    VkBuffer dst;
    std::vector<VkBufferCopy> regions;
};

class PpuComputeNode : public RenderNode<F> {
public:
    PpuComputeNode(VkDevice device,
                   VkPhysicalDevice physicalDevice,
                   VkQueue computeQueue,
                   std::array<VkCommandBuffer, F> commandBuffers,
                   std::vector<std::shared_ptr<Descriptor>> descriptors,
                   const std::vector<char> & computeShaderCode,
                   VkBuffer stagingBuffer,
                   uint8_t* yOffsetPtr)
    : RenderNode<F>(device), 
      computeMaterial_(device, physicalDevice, descriptors, computeShaderCode), 
      stagingBuffer_(stagingBuffer),
      computeQueue_(computeQueue),
      commandBuffers_(commandBuffers),
      yOffsetPtr_(yOffsetPtr) {}

    void submit(RenderEvalContext& ctx) override;

    void addUpdate(uint scanline, const MemoryUpdate& update) {
        // Create a list of updates for this scanline if none exists
        updates_.try_emplace(scanline, std::vector<MemoryUpdate>{});
        // Add the update to the list of operations for this scanline
        updates_.at(scanline).push_back(update);
    }
protected:
    NodeDevice getDeviceType() override {
        return NodeDevice::GPU;
    }
private:
    void submitScanlineBatch(RenderEvalContext& ctx, bool wait, bool signal);

    void applyUpdates(const std::vector<MemoryUpdate>& updates) {
        for(const auto& update : updates) {
            applyUpdate(update);
        }
    }

    void applyUpdate(const MemoryUpdate& update);
private:
    class CompMat : public ComputeMaterial<F> {
    public:
        glm::vec3 getDispatchDimensions() override {
            return glm::vec3(1, scanlineCount_, 1);
        }

        CompMat(VkDevice device,
                VkPhysicalDevice physicalDevice,
                std::vector<std::shared_ptr<Descriptor>> descriptors,
                const std::vector<char> & computeShaderCode): 
        ComputeMaterial<F> (device, physicalDevice, descriptors, computeShaderCode) {}

        void setScanlineCount(uint scanlineCount) {
            scanlineCount_ = scanlineCount;
        }

        void update(uint32_t, VkExtent2D) override {}
    private:
        uint scanlineCount_ = 240;
    };
private:
    CompMat computeMaterial_;
    VkBuffer stagingBuffer_;
    VkQueue computeQueue_;
    std::array<VkCommandBuffer, F> commandBuffers_;
    std::map<uint, std::vector<MemoryUpdate>> updates_{};

    // Safety Warning - pointer managed elsewhere
    uint8_t* yOffsetPtr_;
};