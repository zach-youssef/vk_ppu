#define VK_WRAP_UTIL_IMPL

#include "PpuSession.h"
#include "BufferUtil.h"
#include "ImageToScreenRenderable.h"
#include "NesMemory.h"
#include "PpuNodes.h"

#include "app/VulkanApp.h"
#include "descriptors/DescriptorHeap.h"
#include "graph/RenderGraph.h"
#include "graph/nodes/ReadbackNode.h"
#include "graph/nodes/RenderablesNode.h"
#include "materials/BasicMaterial.h"
#include "resources/Ubo.h"
#include "shaders/ShaderLibrary.h"

#include <glm/ext.hpp>

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>

#include <algorithm>
#include <filesystem>
#include <iostream>

// Defined by the Makefile
#ifndef PPU_SHADER_DIR
#error "PPU_SHADER_DIR must be defined to the directory containing the compiled shaders"
#endif

namespace {

bool isSrgb(VkFormat format) {
    switch (format) {
        case VK_FORMAT_B8G8R8A8_SRGB:
        case VK_FORMAT_R8G8B8A8_SRGB:
        case VK_FORMAT_A8B8G8R8_SRGB_PACK32:
            return true;
        default:
            return false;
    }
}

// Draws the PPU's output (draw.vert, draw.frag). Its bindings are the MVP buffer, the output image
// and a sampler, followed by whether the fragment shader must decode the output's sRGB values
// (when the surface encodes on write).
class DrawMaterial : public BasicMaterial<2> {
public:
    DrawMaterial(VulkanContext& context, std::vector<MaterialBinding> bindings, AttachmentFormats formats)
    : BasicMaterial<2>(context, std::move(bindings), formats,
                       context.shaders().get("draw.vert"), context.shaders().get("draw.frag"),
                       SimpleVertex::getBindingDescription(), SimpleVertex::getAttributeDescriptions()),
      decodeSrgb_(isSrgb(formats.color.at(0)) ? 1u : 0u) {}

protected:
    void writePushConstants(uint32_t, std::vector<uint8_t>& data) override {
        data.resize(data.size() + sizeof(decodeSrgb_));
        memcpy(data.data() + data.size() - sizeof(decodeSrgb_), &decodeSrgb_, sizeof(decodeSrgb_));
    }

private:
    uint32_t decodeSrgb_;
};

} // namespace

template<typename PPUMemory, typename OAM, typename Control>
PpuSession<PPUMemory, OAM, Control>::PpuSession(PpuSessionConfig config)
: config_(config), 
  app_(std::make_unique<VulkanApp>()) {}

template<typename PPUMemory, typename OAM, typename Control>
PpuSession<PPUMemory, OAM, Control>::~PpuSession() = default;

template<typename PPUMemory, typename OAM, typename Control>
void PpuSession<PPUMemory, OAM, Control>::run() {
    app_->run();
}

template<typename PPUMemory, typename OAM, typename Control>
int PpuSession<PPUMemory, OAM, Control>::run(int argc, char** argv) {
    try {
        if (argc == 3 && std::string(argv[1]) == "--capture") {
            capture(argv[2]);
        } else if (argc == 1) {
            run();
        } else {
            std::cerr << "Usage: " << argv[0] << " [--capture <directory>]" << std::endl;
            return EXIT_FAILURE;
        }
    } catch (const std::exception& e) {
        std::cerr << e.what() << std::endl;
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}

template<typename PPUMemory, typename OAM, typename Control>
void PpuSession<PPUMemory, OAM, Control>::capture(const std::string& directory) {
    std::filesystem::create_directories(directory);
    gameClock_->setFixedStep(true);
    graph_->setEnabled(NodeId{captureNode_}, true);
    auto& readback = graph_->nodeAs<ReadbackNode>(NodeId{captureNode_});

    const uint lastFrame = *std::max_element(kCaptureFrames.begin(), kCaptureFrames.end());
    for (uint frame = 1; frame <= lastFrame; ++frame) {
        if (!app_->runFrame()) {
            throw std::runtime_error("The window was closed before capturing every frame");
        }
        if (std::find(kCaptureFrames.begin(), kCaptureFrames.end(), frame) != kCaptureFrames.end()) {
            auto pixels = readback.pixels();
            const auto path = directory + "/" + std::to_string(frame) + ".png";
            const int width = static_cast<int>(config_.screenWidth);
            if (!stbi_write_png(path.c_str(), width, SCANLINES, 4, pixels.data(), width * 4)) {
                throw std::runtime_error("Failed to write " + path);
            }
        }
    }
    app_->getContext().waitIdleAll();

    std::lock_guard<std::mutex> lock(errorsMutex_);
    if (!errors_.empty()) {
        throw std::runtime_error("Vulkan reported " + std::to_string(errors_.size()) + " errors while capturing");
    }
}

template<typename PPUMemory, typename OAM, typename Control>
void PpuSession<PPUMemory, OAM, Control>::init(const std::string& ppuDumpPath, 
              const std::string& oamDumpPath, 
              Control control,
              const std::string& shaderName,
              std::function<UpdateList(MemoryUpdateComposer&)> composeUpdates) {
    AppConfig appConfig;
    appConfig.applicationName = "ppu";
    appConfig.window = WindowConfig{"ppu", static_cast<uint32_t>(config_.screenWidth), SCANLINES};
    appConfig.enableValidation = true;
    appConfig.enableSynchronizationValidation = true;
    appConfig.logInstanceInfo = false;
    appConfig.onValidationMessage = [this](VkDebugUtilsMessageSeverityFlagBitsEXT severity, const char* message) {
        const bool error = severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
        std::cerr << "[Vulkan " << (error ? "error" : "warning") << "] " << message << std::endl;
        if (error) {
            std::lock_guard<std::mutex> lock(errorsMutex_);
            errors_.emplace_back(message);
        }
    };
    appConfig.shaderSearchPaths = {PPU_SHADER_DIR};
    // nes.comp reads the PPU's memory as the 8- and 16-bit fields of NesMemory.h
    appConfig.features.core.features.shaderInt16 = VK_TRUE;
    appConfig.features.vulkan11.storageBuffer16BitAccess = VK_TRUE;
    appConfig.features.vulkan12.shaderInt8 = VK_TRUE;
    appConfig.features.vulkan12.storageBuffer8BitAccess = VK_TRUE;
    app_->init(appConfig);
    auto& context = app_->getContext();
    auto& descriptors = context.descriptors();
    RenderGraph& graph = app_->createGraph();
    graph_ = &graph;

    // The PPU's memory
    auto ppuMemory = createBufferFromFile<PPUMemory>(ppuDumpPath, context);
    auto oam = createBufferFromFile<OAM>(oamDumpPath, context);
    auto controlBuffer = createBufferFromStruct<Control>(control, context);

    // Set up update mappings, and the staging data they copy from
    MemoryUpdateComposer composer(config_.yOffsetLocation);
    auto clockUpdates = composeUpdates(composer);
    stagingData_ = composer.stagingData();

    // Each frame copies the CPU's staging data into a staging buffer of its own, so the game clock
    // never writes data an earlier frame may still be copying from
    const size_t stagingSize = stagingData_.size();
    auto stagingBuffers = context.resources().create<PerFrameHandles<Buffer<uint8_t>>>(context, [&context, stagingSize](uint32_t) {
        Handle<Buffer<uint8_t>> buffer;
        VK_SUCCESS_OR_THROW(Buffer<uint8_t>::create(buffer, context, stagingSize, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
                            "Failed to create staging buffer");
        return buffer;
    });

    PpuBuffers buffers;
    buffers.staging = graph.importBuffer<uint8_t>("ppu staging", stagingBuffers);
    buffers.memory[BufferIndex::PPU] = graph.importBuffer<PPUMemory>("ppu memory", ppuMemory);
    buffers.memory[BufferIndex::OAM] = graph.importBuffer<OAM>("ppu oam", oam);
    buffers.memory[BufferIndex::CONTROL] = graph.importBuffer<Control>("ppu control", controlBuffer);

    // The game clock runs first each frame, then its updates are copied to the frame's staging buffer
    gameClock_ = std::make_unique<GameClock>(stagingData_);
    for (auto& clockUpdate : clockUpdates) {
        gameClock_->addUpdator(std::move(clockUpdate));
    }
    graph.addCpu("game clock",
                 [staging = buffers.staging](NodeBuilder& builder) { builder.write(staging, Access::HostWrite); },
                 [this, stagingBuffers](FrameContext& frame) {
                     gameClock_->tick();
                     (*stagingBuffers)[frame.frameIndex]->mapAndExecute(0, stagingData_.size(), [this](void* mapped) {
                         memcpy(mapped, stagingData_.data(), stagingData_.size());
                     });
                 });

    // The PPU's output. One per frame in flight, so a frame can render while the previous one draws.
    ImageId frameImage = graph.createImage("ppu frame", FrameMode::PerFrame, VK_FORMAT_R8G8B8A8_UNORM,
                                           FixedExtent{{static_cast<uint32_t>(config_.screenWidth), SCANLINES}});

    // Render the frame's scanlines, applying the composed updates between them
    auto ppuMaterial = context.resources().create<PpuMaterial>(context, std::vector<MaterialBinding>{
        MaterialBinding::storageBuffer(descriptors.storageBuffer(ppuMemory)),
        MaterialBinding::storageBuffer(descriptors.storageBuffer(oam)),
        MaterialBinding::storageBuffer(descriptors.storageBuffer(controlBuffer)),
        MaterialBinding::storageImage(graph.storageEntry(frameImage), Access::StorageWrite),
    }, context.shaders().get(shaderName));
    addPpuNodes(graph, ppuMaterial, buffers, composer.updates());

    // Draw the output to the screen
    // GLM was originally designed for OpenGL where the Y coordinate of the clip coordinates is inverted
    auto projection = glm::ortho(-1.0, 1.0, -1.0, 1.0);
    projection[1][1] *= -1;
    auto mvp = createBufferFromStruct<UniformBufferObject>(
        UniformBufferObject::fromModelViewProjection(glm::identity<glm::mat4>(), 
                                                     glm::identity<glm::mat4>(), 
                                                     projection), 
        context);
    Handle<VulkanSampler> sampler;
    VK_SUCCESS_OR_THROW(VulkanSampler::createWithModeAndFilter(sampler, context, VK_SAMPLER_ADDRESS_MODE_REPEAT, VK_FILTER_NEAREST),
                        "Failed to create sampler");
    RenderTarget screen = graph.surfaceTarget();
    auto drawMaterial = context.resources().create<DrawMaterial>(context, std::vector<MaterialBinding>{
        MaterialBinding::storageBuffer(descriptors.storageBuffer(mvp), Access::StorageBufferRead, VK_PIPELINE_STAGE_2_VERTEX_SHADER_BIT),
        MaterialBinding::sampled(graph.sampledEntry(frameImage), VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT),
        MaterialBinding::sampler(descriptors.sampler(sampler)),
    }, graph.formats(screen));
    auto quad = context.resources().create<ImageToScreenRenderable>(drawMaterial, context);
    graph.add<RenderablesNode>("draw", std::vector<Handle<Renderable>>{quad}, screen);

    // Reads the output back for capture(); disabled otherwise
    captureNode_ = graph.add<ReadbackNode>("capture", frameImage).index;
    graph.setEnabled(NodeId{captureNode_}, false);

    app_->setActiveGraph(graph);
}

template class PpuSession<nes::PPUMemory, nes::OAM, nes::Control>;
