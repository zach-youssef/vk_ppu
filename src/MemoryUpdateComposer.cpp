#include "MemoryUpdateComposer.h"

#include <VulkanApp.h>

std::unique_ptr<Buffer<uint8_t>> MemoryUpdateComposer::produceStagingBuffer(VulkanApp<F>& app) {
    // Make sure data is nonempty
    if (stagingData_.empty()) {
        stagingData_.push_back(0u);
    }

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