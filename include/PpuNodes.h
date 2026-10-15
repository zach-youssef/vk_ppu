#pragma once

#include "MemoryUpdateComposer.h"

#include "graph/RenderGraph.h"
#include "materials/Material.h"

#include <array>
#include <map>
#include <vector>

// Renders scanlines with nes.comp: one workgroup per scanline, starting at the control buffer's
// yOffset. Its bindings are the PPU memory, OAM and control buffers, then the output image.
class PpuMaterial : public ComputeMaterial {
public:
    PpuMaterial(VulkanContext& context, std::vector<MaterialBinding> bindings, Handle<Shader> shader)
    : ComputeMaterial(context, std::move(bindings), std::move(shader)) {}

    // The PPU nodes dispatch their own scanline counts
    glm::vec3 getDispatchDimensions() override {
        return glm::vec3(1, SCANLINES, 1);
    }

    void update(uint32_t, VkExtent2D) override {}
};

// The graph's buffers the PPU nodes use
struct PpuBuffers {
    BufferId staging;                   // Per frame: the frame's copy of the staging data
    std::array<BufferId, 3> memory;     // Indexed by BufferIndex
};

// Adds nodes rendering a frame: before each scanline with updates, a transfer node copying the
// updates from the staging buffer, and between them compute nodes rendering the scanlines. The
// graph orders them by their uses of the buffers and runs them on one queue.
void addPpuNodes(RenderGraph& graph,
                 Handle<PpuMaterial> material,
                 PpuBuffers buffers,
                 const std::map<uint, std::vector<MemoryUpdate>>& updates);
