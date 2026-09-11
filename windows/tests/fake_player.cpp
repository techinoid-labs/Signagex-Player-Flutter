// Only built by native smoke tests, never shipped.
#include <windows.h>
#include <fstream>
#include "../runner/kiosk_identity.h"

LRESULT CALLBACK FakeWindow(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(window, message, wparam, lparam);
}

int APIENTRY wWinMain(HINSTANCE instance, HINSTANCE, wchar_t*, int) {
  KioskHandle mutex(CreateMutexW(nullptr, TRUE,
      KioskObjectName(KioskDirectory(), L"player").c_str()));
  if (!mutex.get()) return 1;
  if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;
  const bool first = GetFileAttributesW(L"launches.txt") == INVALID_FILE_ATTRIBUTES;
  { std::ofstream record("launches.txt", std::ios::app); record << GetCurrentProcessId() << '\n'; }
  wchar_t mode[32]{};
  GetEnvironmentVariableW(L"SIGNAGEX_WATCHDOG_TEST_MODE", mode, 32);
  if (std::wstring(mode) == L"normal") return 0;
  if (std::wstring(mode) == L"crash-once" && first) return 42;
  WNDCLASSW cls{};
  cls.hInstance = instance;
  cls.lpszClassName = L"SignageXFakePlayer";
  cls.lpfnWndProc = FakeWindow;
  RegisterClassW(&cls);
  if (!CreateWindowW(cls.lpszClassName, L"Test player", 0, 0, 0, 0, 0,
                     nullptr, nullptr, instance, nullptr)) return 1;
  MSG message;
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  return 0;
}
