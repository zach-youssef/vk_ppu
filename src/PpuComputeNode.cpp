#include "PpuComputeNode.h"
#include <VkUtil.h>

// TODO: Submit single command buffer instead of multiple

void PpuComputeNode::submit(RenderEvalContext& ctx) {
    static const uint SCANLINES = 240;
    uint scanlinesRendered = 0;
    bool wait = true;

    auto updateItr = updates_.begin();

    // Dispatch the scanlines before the first update
    if (updateItr != updates_.end() && updateItr->first > 0) {
        uint scanlinesToRender = updateItr->first;
        // If there's an update at 0 (pre-frame), then do nothing
        if (scanlinesToRender > 0) {
            computeMaterial_.setScanlineCount(scanlinesToRender), 
            submitScanlineBatch(ctx, wait, false);
            scanlinesRendered += scanlinesToRender;
            wait = false;
        }
    }

    while(updateItr != updates_.end()) {
        const auto& [updateScanline, update] = *updateItr;

        // Perform updates
        applyUpdates(update);

        // Dispatch scanlines until the next update (or end of frame if there are none)
        uint renderUntil = (++updateItr == updates_.end()) ? SCANLINES : updateItr->first;
        uint scanlinesToRender = renderUntil - scanlinesRendered;

        computeMaterial_.setScanlineCount(scanlinesToRender);

        submitScanlineBatch(ctx, wait, scanlinesToRender + scanlinesRendered >= SCANLINES);

        scanlinesRendered += scanlinesToRender;
        wait = false;
    }

    // Ensure that all scanlines have been submitted
    uint scanlinesToRender = SCANLINES - scanlinesRendered;
    if (scanlinesToRender > 0) {
        computeMaterial_.setScanlineCount(scanlinesToRender);
        submitScanlineBatch(ctx, wait, true);
        scanlinesRendered += scanlinesToRender;
    }

    // All scanlines should now have been submitted
    assert(scanlinesRendered == SCANLINES);
}

void PpuComputeNode::submitScanlineBatch(RenderEvalContext& ctx, bool wait, bool signal) {
    // Start command buffer
    auto& commandBuffer = commandBuffers_[ctx.frameIndex];
    VK_SUCCESS_OR_THROW(vkResetCommandBuffer(commandBuffer, 0),
                        "Failed to reset compute command buffer");
    
    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    VK_SUCCESS_OR_THROW(vkBeginCommandBuffer(commandBuffer, &beginInfo),
                        "Failed to begin compute commmand buffer");

    // Bind pipeline & descriptor sets
    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, computeMaterial_.getPipeline());
    vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE,
                            computeMaterial_.getPipelineLayout(),
                            0, 1,
                            computeMaterial_.getDescriptorSet(ctx.frameIndex),
                            0, 0);
    // Dispatch workgroups
    auto dispatchSize = computeMaterial_.getDispatchDimensions();
    vkCmdDispatch(commandBuffer, dispatchSize.x, dispatchSize.y, dispatchSize.z);
    
    // End command buffer
    vkEndCommandBuffer(commandBuffer);
    
    // Submit Work
    VkSubmitInfo submitInfo{};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &commandBuffer;
    
    auto& waitSemaphores = RenderNode<F>::waitSemaphores_[ctx.frameIndex];
    submitInfo.waitSemaphoreCount = static_cast<uint32_t>(waitSemaphores.size());
    submitInfo.pWaitSemaphores = waitSemaphores.data();
    std::array<VkSemaphore,1> signalSemaphores = {**RenderNode<F>::signalSemaphores_[ctx.frameIndex]};
    submitInfo.signalSemaphoreCount = static_cast<uint32_t>(signalSemaphores.size());
    submitInfo.pSignalSemaphores = signalSemaphores.data();
    
    VK_SUCCESS_OR_THROW(vkQueueSubmit(computeQueue_,
                                        1,
                                        &submitInfo,
                                        **RenderNode<F>::signalFences_[ctx.frameIndex]),
                        "Failed to submit compute");
}

void PpuComputeNode::applyUpdate(const MemoryUpdate& update) {
    // Begin command buffer
    vkResetCommandBuffer(commandBuffers_[0], 0);
    VkCommandBufferBeginInfo beginInfo{};
    beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    vkBeginCommandBuffer(commandBuffers_[0], &beginInfo);
    VkSubmitInfo submitInfo{};
    submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submitInfo.commandBufferCount = 1;
    submitInfo.pCommandBuffers = &commandBuffers_[0];

    vkCmdCopyBuffer(commandBuffers_[0], stagingBuffer_, update.dst, update.regions.size(), update.regions.data());
    vkEndCommandBuffer(commandBuffers_[0]);
    
    // Submit command buffer
    vkQueueSubmit(computeQueue_, 1, &submitInfo, VK_NULL_HANDLE);
}