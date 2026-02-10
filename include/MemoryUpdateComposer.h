#pragma once

#include "PpuComputeNode.h"

#include <VulkanApp.h>

#include <vulkan/vulkan.h>

#include <vector>

enum BufferIndex {
    PPU = 0,
    OAM = 1,
    CONTROL = 2
};

struct StagingRegionHandle {
    size_t stagingDataOffset;
    size_t mappingIndex;
    size_t size;
    BufferIndex bufferIndex;
};

class MemoryUpdateComposer {
public:
    MemoryUpdateComposer(VkBuffer ppuMemory, 
                         VkBuffer oam, 
                         VkBuffer control, 
                         size_t yOffsetLocation): yOffsetLocation_(yOffsetLocation) {
        bufferHandles_[BufferIndex::PPU] = ppuMemory;
        bufferHandles_[BufferIndex::OAM] = oam;
        bufferHandles_[BufferIndex::CONTROL] = control;
    }
    // Returns the offset into the staging buffer of the new field
    StagingRegionHandle addStagingField(BufferIndex dstBuffer, 
                                        size_t dstOffset, 
                                        size_t size,
                                        void* initialValue = nullptr) {
        // Construct the handle
        StagingRegionHandle handle;
        handle.stagingDataOffset = stagingData_.size();
        handle.mappingIndex = bufferMappings_[dstBuffer].size();
        handle.bufferIndex = dstBuffer;
        handle.size = size;

        // Create & insert our mapping
        VkBufferCopy regionMap;
        regionMap.srcOffset = stagingData_.size();
        regionMap.dstOffset = dstOffset;
        regionMap.size = size;
        bufferMappings_[dstBuffer].push_back(regionMap);

        // Grow staging data to accomodate the new field
        stagingData_.resize(stagingData_.size() + size);

        // Optionally initialize the value
        if (initialValue != nullptr) {
            memcpy(stagingData_.data() + handle.stagingDataOffset, initialValue, size);
        }
    }

    void addUpdate(StagingRegionHandle regionHandle, uint scanline) {
        if (scanlinesWithUpdates_.find(scanline) == scanlinesWithUpdates_.end()) {
            // For each new scanline updated, we need to add an update to shift the yOffset
            StagingRegionHandle yOffsetHandle = addStagingField(CONTROL, yOffsetLocation_, sizeof(uint8_t), &scanline);
            addUpdateInternal(yOffsetHandle, scanline);
            scanlinesWithUpdates_.emplace(scanline);
        }

        addUpdateInternal(regionHandle, scanline);
    }

    std::unique_ptr<Buffer<uint8_t>> produceStagingBuffer(VulkanApp<F>& app) {
        std::unique_ptr<Buffer<uint8_t>> stagingBuffer;
        Buffer<uint8_t>::create(stagingBuffer,
                                stagingData_.size(),
                                VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                app.getDevice(),
                                app.getPhysicalDevice());
        
        stagingBuffer->mapAndExecute(0, stagingData_.size(), [this](void* mappedBuffer){
            memcpy(mappedBuffer, stagingData_.data(), stagingData_.size());
        });

        return stagingBuffer;
    }

    void populateUpdates(PpuComputeNode& ppuNode) {
        for (const auto& updates : updates_) {
            for (const auto& [scanline, update] : updates) {
                ppuNode.addUpdate(scanline, update);
            }
        }
    }

private:
    void addUpdateInternal(StagingRegionHandle regionHandle, uint scanline) {
        auto& updates = updates_[regionHandle.bufferIndex];
        auto& mappings = bufferMappings_[regionHandle.bufferIndex];
        auto& mapping = mappings.at(regionHandle.mappingIndex);

        if (updates.find(scanline) == updates.end()) {
            updates.emplace(scanline, MemoryUpdate{bufferHandles_[regionHandle.bufferIndex], {}});
        }

        updates.at(scanline).regions.push_back(mapping);

    }
private:
    std::array<VkBuffer, 3> bufferHandles_;
    size_t yOffsetLocation_;

    std::vector<uint8_t> stagingData_;
    std::array<std::vector<VkBufferCopy>, 3> bufferMappings_;

    std::array<std::unordered_map<uint, MemoryUpdate>, 3> updates_;
    std::unordered_set<uint> scanlinesWithUpdates_;
};