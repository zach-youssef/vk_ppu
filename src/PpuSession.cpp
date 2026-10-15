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

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>

#include <algorithm>
#include <filesystem>
#include <iostream>

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
int PpuSession<PPUMemory, OAM, Control>::run(int argc, char** argv) {
    if (argc == 3 && std::string(argv[1]) == "--capture") {
        capture(argv[2]);
    } else if (argc == 1) {
        run();
    } else {
        std::cerr << "Usage: " << argv[0] << " [--capture <directory>]" << std::endl;
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}

template<typename PPUMemory, typename OAM, typename Control>
void PpuSession<PPUMemory, OAM, Control>::capture(const std::string& directory) {
    std::filesystem::create_directories(directory);
    gameClock_->setFixedStep(true);
    const uint lastFrame = *std::max_element(kCaptureFrames.begin(), kCaptureFrames.end());
    for (uint frame = 1; frame <= lastFrame; ++frame) {
        glfwPollEvents();
        app_->drawFrame();
        if (std::find(kCaptureFrames.begin(), kCaptureFrames.end(), frame) != kCaptureFrames.end()) {
            auto pixels = readFrame();
            const auto path = directory + "/" + std::to_string(frame) + ".png";
            const int width = static_cast<int>(frameTexture_->getWidth());
            const int height = static_cast<int>(frameTexture_->getHeight());
            if (!stbi_write_png(path.c_str(), width, height, 4, pixels.data(), width * 4)) {
                throw std::runtime_error("Failed to write " + path);
            }
        }
    }
    vkDeviceWaitIdle(app_->getDevice());
}

template<typename PPUMemory, typename OAM, typename Control>
std::vector<uint8_t> PpuSession<PPUMemory, OAM, Control>::readFrame() {
    vkDeviceWaitIdle(app_->getDevice());

    const uint32_t width = frameTexture_->getWidth();
    const uint32_t height = frameTexture_->getHeight();
    const size_t size = size_t(width) * height * 4;
    std::unique_ptr<Buffer<uint8_t>> readback;
    VK_SUCCESS_OR_THROW(Buffer<uint8_t>::create(readback, size,
                                                VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                                app_->getDevice(), app_->getPhysicalDevice()),
                        "Failed to create readback buffer");

    VkImage image = frameTexture_->getImage();
    auto barrier = [image](VkCommandBuffer commandBuffer, VkImageLayout from, VkImageLayout to) {
        VkImageMemoryBarrier barrier{};
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = from;
        barrier.newLayout = to;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        barrier.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
        vkCmdPipelineBarrier(commandBuffer, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                             0, 0, nullptr, 0, nullptr, 1, &barrier);
    };
    issueSingleTimeCommand([&](VkCommandBuffer commandBuffer) {
        barrier(commandBuffer, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
        VkBufferImageCopy region{};
        region.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        region.imageExtent = {width, height, 1};
        vkCmdCopyImageToBuffer(commandBuffer, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                               readback->getBuffer(), 1, &region);
        barrier(commandBuffer, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    }, app_->getGraphicsQueue(), app_->getDevice(), app_->getCommandPool());

    std::vector<uint8_t> pixels(size);
    readback->mapAndExecute(0, size, [&pixels, size](void* data) {
        memcpy(pixels.data(), data, size);
    });
    return pixels;
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

    // Create frame texture & sampler. As Image::createEmptyRGBA, plus transfer source usage so that
    // capture() can read it back.
    VK_SUCCESS_OR_THROW(Image::create(frameTexture_,
                                      config_.screenWidth, SCANLINES,
                                      VK_FORMAT_R8G8B8A8_SRGB,
                                      VK_IMAGE_TILING_OPTIMAL,
                                      VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                                      VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                                      app_->getDevice(), app_->getPhysicalDevice()),
                        "Failed to create frame texture");
    Image::transitionImageLayout(frameTexture_->getImage(),
                                 VK_FORMAT_R8G8B8A8_SRGB,
                                 VK_IMAGE_LAYOUT_UNDEFINED,
                                 VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                 app_->getGraphicsQueue(), app_->getCommandPool(), app_->getDevice());
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