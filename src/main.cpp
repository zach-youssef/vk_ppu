#include <VulkanApp.h>
#include <Ubo.h>
#include <RenderableNode.h>
#include <ComputeNode.h>
#include <AcquireImageNode.h>
#include <PresentNode.h>
#include <BasicMaterial.h>

#include <iostream>
#include <iterator>
#include <fstream>

#include <glm/ext.hpp>

#include "NesMemory.h"
#include "ImageToScreenRenderable.h"
#include "PpuComputeNode.h"

static const std::string pathPrefix = "/Users/zyoussef/code/ppu/";

struct StagingData {
    uint8_t bgPalette3Color2;
    uint8_t startingNametable;
    uint8_t midframeNametable;
    uint8_t yOffset0;
    uint8_t yOffset1;
};

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

int main(int argc, char** argv) {
    VulkanApp<F> app(240, 256);
    app.init();

    // Read PPU dump into a uniform buffer
    auto ppuUbo = createUboFromFile<nes::PPUMemory>("ppu_dump.bin", app);
                                            
    // Read OAM dump into a uniform buffer
    auto oamUbo = createUboFromFile<nes::OAM>("oam_dump.bin", app);

    // Create Control ubo
    // (TEST: settings for current scene)
    nes::Control ctrl{0, 0, 1, 0, 1, 0, 0, {0,0,0,0,0,0,0}};
    auto ctrlUbo = createUboFromStruct<nes::Control>(ctrl, app);

    // Construct M, V, P matrices
    auto model = glm::identity<glm::mat4>();
    auto view = glm::identity<glm::mat4>();
    auto projection = glm::ortho(-1.0, 1.0, -1.0, 1.0);
    // GLM was originally designed for OpenGL where the Y coordinate of the clip coordinates is inverted
    projection[1][1] *= -1;

    // Upload MVP UBO to a uniform buffer
    std::unique_ptr<Buffer<UniformBufferObject>> mvpUbo = createUboFromStruct<UniformBufferObject>(
        UniformBufferObject::fromModelViewProjection(model, view, projection), 
        app);

    // Create image to store frame texture
    std::unique_ptr<Image> frameTexture;
    Image::createEmptyRGBA(frameTexture, 
                           256, 
                           240, 
                           app.getGraphicsQueue(), 
                           app.getCommandPool(), 
                           app.getDevice(), 
                           app.getPhysicalDevice());

    // Create texture sampler
    std::unique_ptr<VulkanSampler> sampler;
    VulkanSampler::createWithModeAndFilter(sampler,
                                           VK_SAMPLER_ADDRESS_MODE_REPEAT,
                                           VK_FILTER_NEAREST,
                                           app.getDevice(),
                                           app.getPhysicalDevice()); 

    // Compute descriptors
    std::vector<std::shared_ptr<Descriptor>> computeDesc = {
        std::make_shared<UniformBufferDescriptor<nes::PPUMemory, F>>(
            std::array<VkBuffer, F>{ppuUbo->getBuffer()}, 
            VK_SHADER_STAGE_COMPUTE_BIT),
        std::make_shared<UniformBufferDescriptor<nes::OAM, F>>(
            std::array<VkBuffer, F>{oamUbo->getBuffer()}, 
            VK_SHADER_STAGE_COMPUTE_BIT),
        std::make_shared<UniformBufferDescriptor<nes::Control, F>>(
            std::array<VkBuffer, F>{ctrlUbo->getBuffer()}, 
            VK_SHADER_STAGE_COMPUTE_BIT),
        std::make_shared<StorageImageDescriptor<F>>(
            VK_SHADER_STAGE_COMPUTE_BIT, 
            std::array<VkImageView, F>{frameTexture->getImageView()})
    };

    // Create staging buffer for updates to our GPU memory
    std::unique_ptr<Buffer<StagingData>> stagingBuffer;
    Buffer<StagingData>::create(stagingBuffer,
                                1,
                                VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                app.getDevice(),
                                app.getPhysicalDevice());

    // Create compute node that controls our PPU rendering
    auto ppuCompute = std::make_unique<PpuComputeNode>(app.getDevice(),
                                                       app.getPhysicalDevice(),
                                                       app.getComputeQueue(),
                                                       app.getComputeCommandBuffers(),
                                                       computeDesc,
                                                       readFile(pathPrefix + "shaders/spirv/nes.comp.spirv"),
                                                       stagingBuffer->getBuffer());
    
    // Configure pre and mid frame updates to the PPU memory

    // TEST: SMB3 title screen palette cycle
    VkBufferCopy bgPalette3Color2;
    bgPalette3Color2.srcOffset = offsetof(StagingData, bgPalette3Color2);
    bgPalette3Color2.dstOffset = offsetof(nes::PPUMemory, backgroundPalettes[3])
                               + offsetof(nes::Palette, data[2]);
    bgPalette3Color2.size = sizeof(uint8_t);
    MemoryUpdate paletteCycle {ppuUbo->getBuffer(), {bgPalette3Color2}};
    ppuCompute->addUpdate(0, paletteCycle);

    // TEST: SMB3 title screen nametable swap
    VkBufferCopy startingNametable;
    startingNametable.srcOffset = offsetof(StagingData, startingNametable);
    startingNametable.dstOffset = offsetof(nes::Control, nametableStart);
    startingNametable.size = sizeof(uint8_t);
    VkBufferCopy yOffset0;
    yOffset0.srcOffset = offsetof(StagingData, yOffset0);
    yOffset0.dstOffset = offsetof(nes::Control, yOffset);
    yOffset0.size = sizeof(uint8_t);
    ppuCompute->addUpdate(0, MemoryUpdate{ctrlUbo->getBuffer(), {startingNametable, yOffset0}});


    VkBufferCopy midframeNametable;
    midframeNametable.srcOffset = offsetof(StagingData, midframeNametable);
    midframeNametable.dstOffset = offsetof(nes::Control, nametableStart);
    midframeNametable.size = sizeof(uint8_t);
    VkBufferCopy yOffset1;
    yOffset1.srcOffset = offsetof(StagingData, yOffset1);
    yOffset1.dstOffset = offsetof(nes::Control, yOffset);
    yOffset1.size = sizeof(uint8_t);
    ppuCompute->addUpdate(192, MemoryUpdate{ctrlUbo->getBuffer(), {midframeNametable, yOffset1}});

    // Initialize the staging buffer with the right starting color & nametables
    stagingBuffer->mapAndExecute(bgPalette3Color2.srcOffset, sizeof(StagingData), [](void* map){
        StagingData* data = (StagingData*) map;
        data->bgPalette3Color2 = 0x17;
        data->startingNametable = 0;
        data->midframeNametable = 2;
        data->yOffset0 = 0;
        data->yOffset1 = 192;
    });

    // Add pre-draw callback to update a clock
    auto last = std::chrono::system_clock::now();
    auto now = std::chrono::system_clock::now();
    long currentFrame = 0;
    auto updateClockCallback = std::make_shared<std::function<void(VulkanApp<F>&,uint32_t)>>();
    *updateClockCallback = [&last, &now, &currentFrame] (VulkanApp<F>&,uint32_t) {
        now = std::chrono::system_clock::now();
        auto deltaTime = std::chrono::duration_cast<std::chrono::microseconds>(now - last);
        if (deltaTime.count() >= 16666) {
            currentFrame += 1;
            last = now;
        }
    };
    app.addPreDrawCallback(updateClockCallback);

    // Add pre-draw callback to update the staging buffer
    auto updateStagingCallback = std::make_shared<std::function<void(VulkanApp<F>&,uint32_t)>>();
    uint lastFrame = 0;
    bool descending = true;
    *updateStagingCallback = [
        &stagingBuffer, 
        offset=bgPalette3Color2.srcOffset, 
        &currentFrame, 
        &lastFrame,
        &descending
    ] (VulkanApp<F>&,uint32_t){
        // Update palette cycle
        if (currentFrame - lastFrame >= 4) {
            stagingBuffer->mapAndExecute(offset, sizeof(uint8_t), [&descending](void* map){
                uint8_t* color = (uint8_t*) map;
                if (*color == 0x37 || *color == 0x7) {
                    descending = !descending;
                }
                *color += descending ? -0x10 : 0x10;
            });
            lastFrame = currentFrame;
        }
    };
    app.addPreDrawCallback(updateStagingCallback);

    // Graphics descriptors
    std::vector<std::shared_ptr<Descriptor>> graphicsDesc = {
        std::make_shared<UniformBufferDescriptor<UniformBufferObject, F>>(
            std::array<VkBuffer, F>{mvpUbo->getBuffer()}, 
            VK_SHADER_STAGE_VERTEX_BIT),
        std::make_shared<CombinedImageSamplerDescriptor<F>>(
            VK_SHADER_STAGE_FRAGMENT_BIT, 
            std::array<VkImageView, F>{frameTexture->getImageView()},
            **sampler)
    };

    // Create render graph
    std::unique_ptr<RenderGraph<F>> renderGraph = std::make_unique<RenderGraph<F>>(app.getDevice());

    auto computeNode = renderGraph->addNode(std::move(ppuCompute));

    auto graphicsNode = renderGraph->addNode(
        std::make_unique<RenderableNode<F>>(
            std::make_unique<ImageToScreenRenderable<F>>(
                std::make_unique<BasicMaterial<F, 2>>(
                    app.getDevice(),
                    app.getPhysicalDevice(),
                    graphicsDesc,
                    app.getSwapchainExtent(),
                    app.getRenderPass(),
                    readFile(pathPrefix + "shaders/spirv/draw.vert.spirv"),
                    readFile(pathPrefix + "shaders/spirv/draw.frag.spirv"),
                    SimpleVertex::getBindingDescription(),
                    SimpleVertex::getAttributeDescriptions()),
                app.getDevice(),
                app.getPhysicalDevice(),
                app.getGraphicsQueue(),
                app.getCommandPool()),
            app.getDevice(),
            app.getGraphicsQueue(),
            app.getRenderPass(),
            app.getGraphicsCommandBuffers()));

    auto acquireImageNode = renderGraph->addNode(std::make_unique<AcquireImageNode<F>>(app.getDevice()));
    auto presentNode = renderGraph->addNode(std::make_unique<PresentNode<F>>(app.getDevice(), app.getPresentQueue()));

    renderGraph->addEdge(computeNode, graphicsNode);
    renderGraph->addEdge(acquireImageNode, graphicsNode);
    renderGraph->addEdge(graphicsNode, presentNode);

    app.setRenderGraph(std::move(renderGraph));

    app.run();

    return 0;
}