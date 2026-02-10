#pragma once

#include "PpuComputeNode.h"
#include <VulkanApp.h>

static const std::string pathPrefix = "/Users/zyoussef/code/ppu/";

template<typename T>
std::unique_ptr<Buffer<T>> createUboFromStruct(T t, VulkanApp<F>& app, 
                                              VkMemoryPropertyFlags memFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) {
    std::unique_ptr<Buffer<T>> ubo;
    Buffer<T>::createAndInitialize(ubo, 
                                   {t}, 
                                   VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, 
                                   memFlags,
                                   app.getDevice(), 
                                   app.getPhysicalDevice(), 
                                   app.getGraphicsQueue(), 
                                   app.getCommandPool());
    return ubo;
}

template<typename T>
std::unique_ptr<Buffer<T>> createUboFromFile(const std::string& path, VulkanApp<F>& app) {
    std::ifstream dumpFile(pathPrefix + path, std::ios::binary);
    std::vector<uint8_t> buffer(std::istreambuf_iterator<char>(dumpFile), {});
    T memStruct;
    std::memcpy(&memStruct, buffer.data(), sizeof(T));

    // Upload PPU memory to a uniform buffer
    return createUboFromStruct<T>(memStruct, app);
}