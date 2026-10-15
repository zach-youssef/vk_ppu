#pragma once

#include <chrono>
#include <memory>
#include <vector>
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
        StagingRegionHandle handle_;
    private:
        long lastFrame_ = 0;
    };

public:
    // Updators write into stagingData, the CPU's copy of the staging data
    explicit GameClock(std::vector<uint8_t>& stagingData): stagingData_(stagingData) {}

    void addUpdator(std::unique_ptr<UpdateFunction>&& updator) {
        updators_.emplace_back(std::move(updator));
    }

    // Advances one game frame per tick instead of following the wall clock, so that captured
    // frames are deterministic
    void setFixedStep(bool fixedStep) {
        fixedStep_ = fixedStep;
    }

    void tick() {
        // Update current frame count
        auto now = std::chrono::system_clock::now();
        auto deltaTime = std::chrono::duration_cast<std::chrono::microseconds>(now - last_);
        if (fixedStep_ || deltaTime.count() >= FRAME_DURATION_MICROS) {
            currentFrame_ += 1;
            last_ = now;
        }

        // Update all systems that should run
        for (auto& updator : updators_) {
            if (updator->shouldRun(currentFrame_)) {
                updator->execute(stagingData_.data() + updator->getHandle().stagingDataOffset);
            }
        }
    }

private:
   std::chrono::time_point<std::chrono::system_clock> last_; 
   long currentFrame_ = 0;
   bool fixedStep_ = false;

   std::vector<std::unique_ptr<UpdateFunction>> updators_;
   std::vector<uint8_t>& stagingData_;
};