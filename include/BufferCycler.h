#pragma once

#include <vector>

class BufferCycler {
public:
    BufferCycler() {}

    BufferCycler(std::vector<uint8_t>&& buffer): buffer_(buffer) {}

    std::vector<uint8_t>& cycleBuffer(size_t stride) {
        std::vector<uint8_t> temp0, temp1;
        temp0.resize(stride);
        temp1.resize(stride);
        bool select = true;

        for (size_t i = 0; i < buffer_.size(); i += stride) {
            memcpy(select ? temp0.data() : temp1.data(), buffer_.data() + i, stride);
            memcpy(buffer_.data() + i, select ? temp1.data() : temp0.data(), stride);

            select = !select;
        }
        // fix front
        memcpy(buffer_.data(), select ? temp1.data() : temp0.data(), stride);

        return buffer_;
    }

private:
    std::vector<uint8_t> buffer_;
};