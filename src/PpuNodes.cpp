#include "PpuNodes.h"

#include <set>
#include <string>

namespace {

void addScanlines(RenderGraph& graph, const Handle<PpuMaterial>& material, uint first, uint count) {
    if (count == 0) {
        return;
    }
    graph.addCompute("ppu scanlines " + std::to_string(first) + "-" + std::to_string(first + count - 1),
                     [material](NodeBuilder& builder) { builder.uses(material); },
                     [material, count](RecordContext& context) {
                         material->bind(context.commandBuffer, context.frameIndex);
                         vkCmdDispatch(context.commandBuffer, 1, count, 1);
                     });
}

void addUpdates(RenderGraph& graph, PpuBuffers buffers, uint scanline, const std::vector<MemoryUpdate>& updates) {
    graph.addTransfer("ppu updates at scanline " + std::to_string(scanline),
                      [buffers, updates](NodeBuilder& builder) {
                          builder.read(buffers.staging, Access::TransferSrc);
                          std::set<BufferIndex> written;
                          for (const auto& update : updates) {
                              if (written.insert(update.dst).second) {
                                  builder.write(buffers.memory[update.dst], Access::TransferDst);
                              }
                          }
                      },
                      [buffers, updates](RecordContext& context) {
                          VkBuffer staging = context.graph.buffer(buffers.staging, context.frameIndex);
                          for (const auto& update : updates) {
                              vkCmdCopyBuffer(context.commandBuffer, staging,
                                              context.graph.buffer(buffers.memory[update.dst], context.frameIndex),
                                              static_cast<uint32_t>(update.regions.size()), update.regions.data());
                          }
                      });
}

} // namespace

void addPpuNodes(RenderGraph& graph,
                 Handle<PpuMaterial> material,
                 PpuBuffers buffers,
                 const std::map<uint, std::vector<MemoryUpdate>>& updates) {
    uint scanlinesRendered = 0;
    auto updateItr = updates.begin();

    // Render the scanlines before the first update
    if (updateItr != updates.end() && updateItr->first > 0) {
        addScanlines(graph, material, 0, updateItr->first);
        scanlinesRendered = updateItr->first;
    }

    while (updateItr != updates.end()) {
        const auto& [updateScanline, update] = *updateItr;

        // Perform updates
        addUpdates(graph, buffers, updateScanline, update);

        // Render scanlines until the next update (or the end of the frame if there are none)
        uint renderUntil = (++updateItr == updates.end()) ? SCANLINES : updateItr->first;
        addScanlines(graph, material, scanlinesRendered, renderUntil - scanlinesRendered);
        scanlinesRendered = renderUntil;
    }

    // Ensure that all scanlines are rendered
    addScanlines(graph, material, scanlinesRendered, SCANLINES - scanlinesRendered);
}
