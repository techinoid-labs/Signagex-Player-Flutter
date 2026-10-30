#include "../frame_store.h"
#include <atomic>
#include <cassert>
#include <climits>
#include <thread>

int main() {
  signagex::FrameStore frames;
  const uint8_t* pixels = nullptr;
  uint32_t width = 0, height = 0;
  assert(!frames.Snapshot(&pixels, &width, &height));
  uint8_t bgra[] = {1, 2, 3, 255, 4, 5, 6, 128};
  assert(!frames.PublishBgra(nullptr, 1, 1));
  assert(!frames.PublishBgra(bgra, 0, 1));
  assert(!frames.PublishBgra(bgra, -1, 1));
  assert(!frames.PublishBgra(bgra, INT_MAX, INT_MAX));
  assert(frames.PublishBgra(bgra, 2, 1));
  assert(frames.Snapshot(&pixels, &width, &height));
  assert(width == 2 && height == 1);
  assert(pixels[0] == 3 && pixels[1] == 2 && pixels[2] == 1);
  assert(pixels[4] == 6 && pixels[7] == 128);
  const auto* held = pixels;
  std::thread producer([&] {
    for (int i = 0; i < 10000; ++i) {
      std::vector<uint8_t> src((i % 32 + 1) * 4, uint8_t(i));
      assert(frames.PublishBgra(src.data(), i % 32 + 1, 1));
    }
  });
  // Deliberately keep Flutter's previous pointer while the producer resizes
  // and replaces frames. The old implementation freed/replaced these bytes.
  for (int i = 0; i < 10000; ++i) assert(held[0] == 3 && held[7] == 128);
  producer.join();
  assert(frames.Snapshot(&pixels, &width, &height));
  assert(width == 10000 % 32 && pixels[0] == uint8_t(9999));
  std::atomic<bool> done{false};
  std::thread racing_producer([&] {
    for (int i = 0; i < 20000; ++i) {
      std::vector<uint8_t> src((i % 48 + 1) * 4, uint8_t(i));
      assert(frames.PublishBgra(src.data(), i % 48 + 1, 1));
    }
    done = true;
  });
  while (!done) {
    assert(frames.Snapshot(&pixels, &width, &height));
    for (uint32_t i = 1; i < width * height * 4; ++i) assert(pixels[i] == pixels[0]);
  }
  racing_producer.join();
  for (int i = 0; i < 1000; ++i) {
    signagex::FrameStore disposable;
    assert(disposable.PublishBgra(bgra, 2, 1));
    assert(disposable.Snapshot(&pixels, &width, &height));
  }
}
