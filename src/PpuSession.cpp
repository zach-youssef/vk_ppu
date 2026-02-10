#define VK_WRAP_UTIL_IMPL

#include "PpuSession.h"
#include "ImageToScreenRenderable.h"

#include <VulkanApp.h>
#include <Ubo.h>
#include <VkTypes.h>
#include <Image.h>
#include <PresentNode.h>
#include <AcquireImageNode.h>
#include <RenderableNode.h>
#include <BasicMaterial.h>
#include <FileUtil.h>

#include <glm/ext.hpp>

#include "NesMemory.h"
#include "UboUtil.h"
#include "MemoryUpdateComposer.h"
#include "PpuComputeNode.h"
#include "GameClock.h"

template<typename PPUMemory, typename OAM, typename Control>
PpuSession<PPUMemory, OAM, Control>::PpuSession(PpuSessionConfig config)
: config_(config), 
  app_(std::make_unique<VulkanApp<F>>(SCANLINES, config.screenWidth)) {}

template<typename PPUMemory, typename OAM, typename Control>
PpuSession<PPUMemory, OAM, Control>::~PpuSession() = default;

template<typename PPUMemory, typename OAM, typename Control>
void PpuSession<PPUMemory, OAM, Control>::run() {
    app_->run();
}

template<typename PPUMemory, typename OAM, typename Control>
void PpuSession<PPUMemory, OAM, Control>::init(const std::string& ppuDumpPath, 
              const std::string& oamDumpPath, 
              Control control,
              const std::string& shaderPath,
              std::function<UpdateList(MemoryUpdateComposer&)> composeUpdates) {
    app_->init();

    // Create compute memory buffers
    ppuUbo_ = createUboFromFile<PPUMemory>(ppuDumpPath, *app_);
    oamUbo_ = createUboFromFile<OAM>(oamDumpPath, *app_);
    controlUbo_ = createUboFromStruct<Control>(control, *app_);

    // Construct M, V, P matrices
    // Create MVP UBO for graphics
    // GLM was originally designed for OpenGL where the Y coordinate of the clip coordinates is inverted
    auto projection = glm::ortho(-1.0, 1.0, -1.0, 1.0);
    projection[1][1] *= -1;
    mvpUbo_ = createUboFromStruct<UniformBufferObject>(
        UniformBufferObject::fromModelViewProjection(glm::identity<glm::mat4>(), 
                                                        glm::identity<glm::mat4>(), 
                                                        projection), 
        *app_);

    // Create frame texture & sampler
    Image::createEmptyRGBA(frameTexture_, 
                           config_.screenWidth, 
                           SCANLINES, 
                           app_->getGraphicsQueue(), 
                           app_->getCommandPool(), 
                           app_->getDevice(), 
                           app_->getPhysicalDevice());
    VulkanSampler::createWithModeAndFilter(sampler_,
                                            VK_SAMPLER_ADDRESS_MODE_REPEAT,
                                            VK_FILTER_NEAREST,
                                            app_->getDevice(),
                                            app_->getPhysicalDevice()); 
    
    // Set up update mappings
    MemoryUpdateComposer composer(ppuUbo_->getBuffer(), oamUbo_->getBuffer(), controlUbo_->getBuffer(), config_.yOffsetLocation);
    auto clockUpdates = composeUpdates(composer);
    // Create staging buffer for updates to our GPU memory
    stagingBuffer_ = composer.produceStagingBuffer(*app_);
    // Create compute node that controls our PPU rendering
    auto ppuCompute = std::make_unique<PpuComputeNode>(app_->getDevice(),
                                                       app_->getPhysicalDevice(),
                                                       app_->getComputeQueue(),
                                                       app_->getComputeCommandBuffers(),
                                                       // Compute descriptors
                                                       std::vector<std::shared_ptr<Descriptor>>{
                                                       std::make_shared<UniformBufferDescriptor<PPUMemory, F>>(
                                                           std::array<VkBuffer, F>{ppuUbo_->getBuffer()}, 
                                                           VK_SHADER_STAGE_COMPUTE_BIT),
                                                       std::make_shared<UniformBufferDescriptor<OAM, F>>(
                                                           std::array<VkBuffer, F>{oamUbo_->getBuffer()}, 
                                                           VK_SHADER_STAGE_COMPUTE_BIT),
                                                       std::make_shared<UniformBufferDescriptor<Control, F>>(
                                                           std::array<VkBuffer, F>{controlUbo_->getBuffer()}, 
                                                           VK_SHADER_STAGE_COMPUTE_BIT),
                                                       std::make_shared<StorageImageDescriptor<F>>(
                                                           VK_SHADER_STAGE_COMPUTE_BIT, 
                                                           std::array<VkImageView, F>{frameTexture_->getImageView()})
                                                       },
                                                       readFile(pathPrefix + shaderPath),
                                                       stagingBuffer_->getBuffer());
    // Add our composed updates to the compute node
    composer.populateUpdates(*ppuCompute);

    // Initialize the game clock
    gameClock_ = std::make_unique<GameClock>(*stagingBuffer_);
    for (auto& clockUpdate : clockUpdates) {
        gameClock_->addUpdator(std::move(clockUpdate));
    }
    app_->addPreDrawCallback(gameClock_->getCallback());


    // Graphics descriptors
    std::vector<std::shared_ptr<Descriptor>> graphicsDesc = {
        std::make_shared<UniformBufferDescriptor<UniformBufferObject, F>>(
            std::array<VkBuffer, F>{mvpUbo_->getBuffer()}, 
            VK_SHADER_STAGE_VERTEX_BIT),
        std::make_shared<CombinedImageSamplerDescriptor<F>>(
            VK_SHADER_STAGE_FRAGMENT_BIT, 
            std::array<VkImageView, F>{frameTexture_->getImageView()},
            **sampler_)
    };

    // Create render graph
    std::unique_ptr<RenderGraph<F>> renderGraph = std::make_unique<RenderGraph<F>>(app_->getDevice());

    auto computeNode = renderGraph->addNode(std::move(ppuCompute));

    auto graphicsNode = renderGraph->addNode(
        std::make_unique<RenderableNode<F>>(
            std::make_unique<ImageToScreenRenderable<F>>(
                std::make_unique<BasicMaterial<F, 2>>(
                    app_->getDevice(),
                    app_->getPhysicalDevice(),
                    graphicsDesc,
                    app_->getSwapchainExtent(),
                    app_->getRenderPass(),
                    readFile(pathPrefix + "shaders/spirv/draw.vert.spirv"),
                    readFile(pathPrefix + "shaders/spirv/draw.frag.spirv"),
                    SimpleVertex::getBindingDescription(),
                    SimpleVertex::getAttributeDescriptions()),
                app_->getDevice(),
                app_->getPhysicalDevice(),
                app_->getGraphicsQueue(),
                app_->getCommandPool()),
            app_->getDevice(),
            app_->getGraphicsQueue(),
            app_->getRenderPass(),
            app_->getGraphicsCommandBuffers()));

    auto acquireImageNode = renderGraph->addNode(std::make_unique<AcquireImageNode<F>>(app_->getDevice()));
    auto presentNode = renderGraph->addNode(std::make_unique<PresentNode<F>>(app_->getDevice(), app_->getPresentQueue()));

    renderGraph->addEdge(computeNode, graphicsNode);
    renderGraph->addEdge(acquireImageNode, graphicsNode);
    renderGraph->addEdge(graphicsNode, presentNode);

    app_->setRenderGraph(std::move(renderGraph));
}

template class PpuSession<nes::PPUMemory, nes::OAM, nes::Control>;