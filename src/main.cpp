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

static const uint F = 1u;

static const std::string pathPrefix = "/Users/zyoussef/code/ppu/";

class CompMat : public ComputeMaterial<F> {
public:
    glm::vec3 getDispatchDimensions() override {
        return glm::vec3(1, 240, 1);
    }

    CompMat(VkDevice device,
            VkPhysicalDevice physicalDevice,
            std::vector<std::shared_ptr<Descriptor>> descriptors,
            const std::vector<char> & computeShaderCode): 
    ComputeMaterial<F> (device, physicalDevice, descriptors, computeShaderCode) {}

    void update(uint32_t, VkExtent2D) override {}
};

int main(int argc, char** argv) {
    VulkanApp<F> app(240, 256);
    app.init();

    // attemting to read the PPU memory dump....
    std::ifstream dumpFile(pathPrefix + std::string("ppu_dump.bin"), std::ios::binary);
    std::vector<uint8_t> buffer(std::istreambuf_iterator<char>(dumpFile), {});
    nes::PPUMemory ppuMemory;
    std::memcpy(&ppuMemory, buffer.data(), 0x4000);

    // Upload PPU memory to a uniform buffer
    std::unique_ptr<Buffer<nes::PPUMemory>> ppuUbo;
    Buffer<nes::PPUMemory>::createAndInitialize(ppuUbo, 
                                               {ppuMemory}, 
                                               VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, 
                                               app.getDevice(), 
                                               app.getPhysicalDevice(), 
                                               app.getGraphicsQueue(), 
                                               app.getCommandPool());

    // Construct M, V, P matrices
    auto model = glm::identity<glm::mat4>();
    auto view = glm::identity<glm::mat4>();
    auto projection = glm::ortho(-1.0, 1.0, -1.0, 1.0);
    // GLM was originally designed for OpenGL where the Y coordinate of the clip coordinates is inverted
    projection[1][1] *= -1;

    // Upload MVP UBO to a uniform buffer
    std::unique_ptr<Buffer<UniformBufferObject>> mvpUbo;
    Buffer<UniformBufferObject>::createAndInitialize(mvpUbo, 
                                                    {UniformBufferObject::fromModelViewProjection(model, view, projection)}, 
                                                    VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, 
                                                    app.getDevice(), 
                                                    app.getPhysicalDevice(), 
                                                    app.getGraphicsQueue(), 
                                                    app.getCommandPool());

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
        std::make_shared<StorageImageDescriptor<F>>(
            VK_SHADER_STAGE_COMPUTE_BIT, 
            std::array<VkImageView, F>{frameTexture->getImageView()})
    };

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

    auto computeNode = renderGraph->addNode(
        std::make_unique<ComputeNode<F>>(
            std::make_unique<CompMat>(
                app.getDevice(),
                app.getPhysicalDevice(),
                computeDesc,
                readFile(pathPrefix + "shaders/spirv/nes.comp.spirv")),
            app.getDevice(),
            app.getComputeQueue(),
            app.getComputeCommandBuffers()));

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