#pragma once

#include "Constants.h"

#include <vulkan/vulkan.h>

#include <array>
#include <cstring>
#include <map>
#include <unordered_map>
#include <unordered_set>
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

// Copies from the staging data into one of the PPU's buffers
struct MemoryUpdate {
    BufferIndex dst;
    std::vector<VkBufferCopy> regions;
};

class MemoryUpdateComposer {
public:
    explicit MemoryUpdateComposer(size_t yOffsetLocation): yOffsetLocation_(yOffsetLocation) {}

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

        return handle;
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

    // The staging data's initial contents (never empty)
    std::vector<uint8_t> stagingData() const {
        return stagingData_.empty() ? std::vector<uint8_t>{0u} : stagingData_;
    }

    // The updates to apply before rendering each scanline, by scanline
    std::map<uint, std::vector<MemoryUpdate>> updates() const {
        std::map<uint, std::vector<MemoryUpdate>> byScanline;
        for (const auto& updates : updates_) {
            for (const auto& [scanline, update] : updates) {
                byScanline[scanline].push_back(update);
            }
        }
        return byScanline;
    }

private:
    void addUpdateInternal(StagingRegionHandle regionHandle, uint scanline) {
        auto& updates = updates_[regionHandle.bufferIndex];
        auto& mappings = bufferMappings_[regionHandle.bufferIndex];
        auto& mapping = mappings.at(regionHandle.mappingIndex);

        if (updates.find(scanline) == updates.end()) {
            updates.emplace(scanline, MemoryUpdate{regionHandle.bufferIndex, {}});
        }

        updates.at(scanline).regions.push_back(mapping);

    }
private:
    size_t yOffsetLocation_;

    std::vector<uint8_t> stagingData_;
    std::array<std::vector<VkBufferCopy>, 3> bufferMappings_;

    std::array<std::unordered_map<uint, MemoryUpdate>, 3> updates_;
    std::unordered_set<uint> scanlinesWithUpdates_;
};
