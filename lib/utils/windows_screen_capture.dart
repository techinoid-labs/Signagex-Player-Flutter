// Real OS-level screen capture for Windows Remote View.
//
// RenderRepaintBoundary (used everywhere else in this app for the
// screenshot path) can only ever capture this Flutter app's own render
// tree -- it has no way to reflect anything happening outside the app:
// another window in focus, the taskbar, or the real desktop after
// press_home (Shell.Application.MinimizeAll()) minimizes every window.
// That's why Remote View kept showing the player screen even though Home
// visibly worked on the actual machine. This captures the literal screen
// contents via GDI BitBlt -- the same technique most Windows screen-capture
// tools use -- so Remote View reflects whatever is actually on screen.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:win32/win32.dart';

/// Captures the full Windows virtual desktop (all monitors) and returns it
/// as an [img.Image], or null if the capture failed for any reason.
img.Image? captureWindowsDesktop() {
  final hdcScreen = GetDC(NULL);
  if (hdcScreen == 0) return null;

  try {
    final left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    final top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    final width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    final height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (width <= 0 || height <= 0) return null;

    final hdcMem = CreateCompatibleDC(hdcScreen);
    if (hdcMem == 0) return null;

    try {
      final hBitmap = CreateCompatibleBitmap(hdcScreen, width, height);
      if (hBitmap == 0) return null;

      try {
        final oldObj = SelectObject(hdcMem, hBitmap);
        var copied = 0;
        try {
          // CAPTUREBLT also picks up layered windows (WS_EX_LAYERED), which
          // a plain SRCCOPY can miss. hBitmap must be selected into hdcMem
          // for BitBlt to render into it.
          copied = BitBlt(
            hdcMem,
            0,
            0,
            width,
            height,
            hdcScreen,
            left,
            top,
            SRCCOPY | CAPTUREBLT,
          );
        } finally {
          // W26: restoring the previous selection *before* reading the
          // bitmap is the actual fix, not just cleanup -- the Win32
          // contract for GetDIBits (which _readBitmap calls) explicitly
          // requires the bitmap not be selected into any device context
          // when it's called. The previous version read the bitmap here,
          // inside this same try block, before this finally ever ran --
          // i.e. while hBitmap was still selected into hdcMem the entire
          // time GetDIBits executed, on every single capture.
          SelectObject(hdcMem, oldObj);
        }
        if (copied == 0) return null;
        return _readBitmap(hdcMem, hBitmap, width, height);
      } finally {
        DeleteObject(hBitmap);
      }
    } finally {
      DeleteDC(hdcMem);
    }
  } finally {
    ReleaseDC(NULL, hdcScreen);
  }
}

img.Image? _readBitmap(int hdcMem, int hBitmap, int width, int height) {
  final bmi = calloc<BITMAPINFO>();
  final bufferSize = width * height * 4;
  final pixels = calloc<Uint8>(bufferSize);

  try {
    bmi.ref.bmiHeader.biSize = sizeOf<BITMAPINFOHEADER>();
    bmi.ref.bmiHeader.biWidth = width;
    // Negative height requests a top-down DIB (first row = top of screen),
    // matching how Image.fromBytes expects row order -- a positive height
    // here would return the rows bottom-up instead.
    bmi.ref.bmiHeader.biHeight = -height;
    bmi.ref.bmiHeader.biPlanes = 1;
    bmi.ref.bmiHeader.biBitCount = 32;
    bmi.ref.bmiHeader.biCompression = BI_RGB;

    final linesCopied = GetDIBits(
      hdcMem,
      hBitmap,
      0,
      height,
      pixels.cast(),
      bmi,
      DIB_RGB_COLORS,
    );
    // W26: was `== 0` -- a partial copy (some rows copied, not all) is not
    // success either; treating it as one would hand back a buffer with
    // uninitialized/stale rows at the bottom silently mixed into a real
    // frame.
    if (linesCopied != height) return null;

    // CONFIRMED CRASH CAUSE (watchdog.log: repeated STATUS_ACCESS_VIOLATION
    // 0xC0000005 exits, roughly every 9-19 minutes -- this runs on every
    // periodic screenshot, ~15-25s apart): Pointer<Uint8>.asTypedList()
    // returns a zero-copy VIEW backed directly by this `pixels` calloc
    // allocation, not a copy. The old code handed that view's ByteBuffer
    // straight to Image.fromBytes and then freed `pixels` in the finally
    // block below -- regardless of whether Image.fromBytes happens to copy
    // internally (not guaranteed, and not something this can rely on across
    // package versions), anything that reads the image's pixel data after
    // this function returns is reading through a pointer into memory this
    // function just freed. calloc.free doesn't corrupt memory immediately;
    // it just marks it reusable, so this "worked" until something else
    // reused or unmapped that page -- exactly the intermittent, only-after-
    // a-while pattern in watchdog.log, not a crash on every single capture.
    // Uint8List.fromList allocates real Dart-GC-managed memory and copies
    // into it here, before the finally block frees the native buffer, so
    // nothing downstream can ever hold a dangling reference to freed memory.
    final bytes = Uint8List.fromList(pixels.asTypedList(bufferSize));
    return img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
  } finally {
    calloc.free(pixels);
    calloc.free(bmi);
  }
}
