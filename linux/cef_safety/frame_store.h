#pragma once

#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

namespace signagex {
// The CEF producer never writes the buffer returned to Flutter. The render
// thread owns that snapshot until its next copy_pixels call has completed.
class FrameStore {
 public:
  // Flutter can request a texture immediately after registration, before CEF's
  // first OnPaint. Always supply a valid transparent pixel in that interval.
  FrameStore() : displayed_(4, 0), displayed_width_(1), displayed_height_(1) {}

  bool PublishBgra(const void* source, int width, int height) {
    if (!source || width <= 0 || height <= 0 ||
        uint64_t(width) * uint64_t(height) > 64 * 1024 * 1024) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    const size_t bytes = size_t(width) * size_t(height) * 4;
    pending_.resize(bytes);
    // This runs on the platform thread for every CEF paint (8 MB at 1080p).
    // Swap B and R a whole pixel at a time so the compiler vectorises it; the
    // byte-by-byte loop cost about half of that thread on a web zone.
    // Both Linux targets (x86_64, arm64) are little-endian.
    const auto* src = static_cast<const uint8_t*>(source);
    uint8_t* dst = pending_.data();
    for (size_t i = 0; i < bytes; i += 4) {
      uint32_t pixel;
      std::memcpy(&pixel, src + i, 4);
      pixel = (pixel & 0xFF00FF00u) | ((pixel >> 16) & 0xFFu) | ((pixel & 0xFFu) << 16);
      std::memcpy(dst + i, &pixel, 4);
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
