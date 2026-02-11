#pragma once

#include "GameClock.h"

struct MetaspriteSize {
    size_t width;
    size_t height;
    size_t stride;

    size_t size() {
        return width * height * stride;
    }
};

class MetaspriteUpdator : public GameClock::UpdateFunction {
protected:
    MetaspriteUpdator(StagingRegionHandle handle, 
                      MetaspriteSize size, 
                      uint frequency)
    : GameClock::UpdateFunction(handle),
      size_(size),
      frequency_(frequency) {}

      void execute(void* mappedData) override {
        uint8_t* sprite = (uint8_t*) mappedData;
        for (uint y = 0; y < size_.height; ++y) {
            for (uint x = 0; x < size_.width; ++x) {
                updateSubSprite(x, y, sprite);
                sprite += size_.stride;
            }
        }
      }

      virtual void updateSubSprite(uint x, uint y, uint8_t* sprite) = 0;

      uint getFrequency() const override {
        return frequency_;
      }

protected:
    MetaspriteSize size_;
    uint frequency_;
};


class MetaspriteTileAnimator : public MetaspriteUpdator {
public:
    MetaspriteTileAnimator(StagingRegionHandle handle, 
                           MetaspriteSize size, 
                           uint frequency,
                           size_t tileOffset,
                           std::unordered_map<uint8_t, uint8_t> updateMapping)
    : MetaspriteUpdator(handle, size, frequency),
      tileOffset_(tileOffset),
      updateMapping_(updateMapping){}

protected:
    void updateSubSprite(uint, uint, uint8_t* sprite) override {
        uint8_t* tileIdx = sprite + tileOffset_;
        if (updateMapping_.find(*tileIdx) != updateMapping_.end()) {
            *tileIdx = updateMapping_.at(*tileIdx);
        }
    }

private:
    size_t tileOffset_;
    std::unordered_map<uint8_t, uint8_t> updateMapping_;
};

class MetaspritePositionAnimator : public MetaspriteUpdator {
public:
    MetaspritePositionAnimator(StagingRegionHandle handle,
                               MetaspriteSize size,
                               uint frequency,
                               std::pair<size_t, size_t> xyOffsets,
                               std::pair<uint, uint> xyDeltas,
                               std::pair<uint, uint> xyMax)
    : MetaspriteUpdator(handle, size, frequency),
    xyOffsets_(xyOffsets),
    xyDeltas_(xyDeltas),
    xyMax_(xyMax) {}

protected:
    void updateSubSprite(uint, uint, uint8_t* sprite) override {
        uint8_t* x = sprite + xyOffsets_.first;
        *x = (*x + xyDeltas_.first) % xyMax_.first;
        uint8_t* y = sprite + xyOffsets_.second;
        *y = (*y + xyDeltas_.second) % xyMax_.second;
    }
      
private:
    std::pair<size_t, size_t> xyOffsets_;
    std::pair<uint, uint> xyDeltas_;
    std::pair<uint, uint> xyMax_;
};