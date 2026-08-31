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

        try {
          // CAPTUREBLT also picks up layered windows (WS_EX_LAYERED), which
          // a plain SRCCOPY can miss.
          final copied = BitBlt(
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
          if (copied == 0) return null;

          return _readBitmap(hdcMem, hBitmap, width, height);
        } finally {
          SelectObject(hdcMem, oldObj);
        }
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
    if (linesCopied == 0) return null;

    final bytes = pixels.asTypedList(bufferSize);
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
