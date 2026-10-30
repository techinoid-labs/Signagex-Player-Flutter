#pragma once

#include <cstdint>
#include <mutex>
#include <vector>

namespace signagex {
// The CEF producer never writes the buffer returned to Flutter. The render
// thread owns that snapshot until its next copy_pixels call has completed.
class FrameStore {
 public:
  bool PublishBgra(const void* source, int width, int height) {
    if (!source || width <= 0 || height <= 0 ||
        uint64_t(width) * uint64_t(height) > 64 * 1024 * 1024) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    const size_t bytes = size_t(width) * size_t(height) * 4;
    pending_.resize(bytes);
    const auto* src = static_cast<const uint8_t*>(source);
    for (size_t i = 0; i < bytes; i += 4) {
      pending_[i] = src[i + 2];
      pending_[i + 1] = src[i + 1];
      pending_[i + 2] = src[i];
      pending_[i + 3] = src[i + 3];
    }
    pending_width_ = width;
    pending_height_ = height;
    ready_ = true;
    return true;
  }

  // Called only by Flutter's render thread. The returned bytes remain valid
  // across any number of producer updates, until the next Snapshot call.
  bool Snapshot(const uint8_t** pixels, uint32_t* width, uint32_t* height) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (ready_) {
      displayed_.swap(pending_);
      displayed_width_ = pending_width_;
      displayed_height_ = pending_height_;
      ready_ = false;
    }
    if (displayed_.empty()) return false;
    *pixels = displayed_.data();
    *width = displayed_width_;
    *height = displayed_height_;
    return true;
  }

 private:
  std::mutex mutex_;
  std::vector<uint8_t> pending_, displayed_;
  uint32_t pending_width_ = 0, pending_height_ = 0;
  uint32_t displayed_width_ = 0, displayed_height_ = 0;
  bool ready_ = false;
};
}  // namespace signagex
