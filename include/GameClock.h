#pragma once

#include <chrono>
#include "MemoryUpdateComposer.h"

class GameClock {
    static const uint FRAME_DURATION_MICROS = 16666;
public:
    class UpdateFunction {
    public:
        UpdateFunction(StagingRegionHandle handle): handle_(handle) {}

        virtual ~UpdateFunction() = default;

        virtual void execute(void* mappedData) = 0;

        StagingRegionHandle getHandle() const {
            return handle_;
        }

        bool shouldRun(uint currentFrame) {
            if (currentFrame - lastFrame_ >= getFrequency()) {
                lastFrame_ = currentFrame;
                return true;
            }
            return false;
        }
    protected:
        virtual uint getFrequency() const = 0;
    private:
        long lastFrame_ = 0;
        StagingRegionHandle handle_;
    };

public:
    GameClock(Buffer<uint8_t>& stagingBuffer): stagingBuffer_(stagingBuffer) {
        callback_ = std::make_shared<std::function<void(VulkanApp<F>&,uint32_t)>>(
        [this](VulkanApp<F>&,uint32_t) {
            this->tick();
        });
    }

    void addUpdator(std::unique_ptr<UpdateFunction>&& updator) {
        updators_.emplace_back(std::move(updator));
    }

    void tick() {
        // Update current frame count
        auto now = std::chrono::system_clock::now();
        auto deltaTime = std::chrono::duration_cast<std::chrono::microseconds>(now - last_);
        if (deltaTime.count() >= FRAME_DURATION_MICROS) {
            currentFrame_ += 1;
            last_ = now;
        }

        // Update all systems that should run
        for (auto& updator : updators_) {
            if (updator->shouldRun(currentFrame_)) {
                const auto& handle = updator->getHandle();
                stagingBuffer_.mapAndExecute(handle.stagingDataOffset, handle.size, [&updator](void* mappedData) {
                    updator->execute(mappedData);
                });
            }
        }
    }

    std::shared_ptr<std::function<void(VulkanApp<F>&,uint32_t)>>& getCallback() {
        return callback_;
    }

private:
   std::chrono::time_point<std::chrono::system_clock> last_; 
   long currentFrame_ = 0;

   std::vector<std::unique_ptr<UpdateFunction>> updators_;
   Buffer<uint8_t>& stagingBuffer_;
   
   std::shared_ptr<std::function<void(VulkanApp<F>&,uint32_t)>> callback_;
};