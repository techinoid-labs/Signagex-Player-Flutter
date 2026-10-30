# Linux CEF safety overrides

`webview_cef` 0.2.2 is pinned in pubspec.yaml. Its Linux backend configures a
separate Chromium UI thread, then calls GTK/Flutter APIs from that thread.
Renderer-map changes also race between that thread and Flutter method calls.
Its pixel callback exposes a buffer that the producer deletes on the next
frame (`delete` is also used for a `new[]` allocation). The renderer never
releases its own GObject texture reference, retaining its final frame.

The application CMake generates Linux-only replacement sources in the build
folder. `prepare.py` verifies exact upstream source hashes before applying
these changes. It never writes into pub's shared dependency cache or changes
Windows/macOS sources. On dependency upgrades, review the fixes and expected
hashes instead of bypassing the check. The generated source derives from
hlwhl/webview_cef under the accompanying Apache 2.0 license.

- Use CEF's external message pump on the GTK platform loop. Create/close,
  browser notifications, method responses and texture registration therefore
  have the same thread owner, rather than concurrently accessing Flutter and
  browser maps. Remove the pump before shutdown; initialize CEF only once.
- Exchange complete frame snapshots through a mutex. A producer can replace
  its pending frame while the render thread retains a stable displayed frame.
  Buffers are reused. Oversized/invalid dimensions are rejected (64M pixels,
  sufficient for 8K). The renderer releases its texture and registrar refs;
  the GObject finalizer releases both frame buffers.
- Release method-response values and erase closed renderer entries.

`tests/frame_store_test.cc` checks channel conversion, invalid sizes, retained
buffer lifetime across 10,000 producer updates, concurrent snapshot updates,
and 1,000 create/destroy cycles under ASan/UBSan. CI also compiles the actual
plugin through both native architectures. Runtime acceptance still requires
browser/video transition and memory soak tests on the Byte; source fixes and
sanitizer success alone do not establish that every overnight failure is gone.

Flutter consumes the pixels after `copy_pixels` returns; see
https://api.flutter.dev/linux-embedder/fl__pixel__buffer__texture_8h.html.
