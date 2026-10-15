#pragma once

#include "Constants.h"

#include "resources/Buffer.h"

#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

// A device local storage buffer holding t
template<typename T>
Handle<Buffer<T>> createBufferFromStruct(T t, VulkanContext& context) {
    Handle<Buffer<T>> buffer;
    Buffer<T>::createAndInitialize(buffer, context, {t}, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    return buffer;
}

// A device local storage buffer holding the T dumped to path (relative to dataDir)
template<typename T>
Handle<Buffer<T>> createBufferFromFile(const std::string& path, VulkanContext& context) {
    std::ifstream dumpFile(dataDir + "/" + path, std::ios::binary);
    std::vector<uint8_t> buffer(std::istreambuf_iterator<char>(dumpFile), {});
    if (buffer.size() < sizeof(T)) {
        throw std::runtime_error("Can't read " + dataDir + "/" + path);
    }
    T memStruct;
    std::memcpy(&memStruct, buffer.data(), sizeof(T));
    return createBufferFromStruct<T>(memStruct, context);
}
