#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>
#include <cwchar>

#include "flutter_window.h"
#include "utils.h"
#include "kiosk_identity.h"

namespace {
// Filled in before the handler is installed, so the handler itself does as
// little as possible inside a process that has already crashed.
wchar_t g_native_crash_path[32768] = {};

// Records where a native crash happened, next to the exe as crash-native.txt;
// the next run includes it in the crash upload. The watchdog's exit code
// only says THAT the player crashed. A tester's player crashing ~5 seconds
// after every launch left nothing in the Dart log, so the only way to learn
// which module failed was to ask someone to dig through Event Viewer.
//
// Fail-fast exceptions (0xC0000409, 0xC0000602) bypass this handler by
// design; for those the watchdog's exit code is still recorded.
LONG WINAPI RecordNativeCrash(EXCEPTION_POINTERS* info) {
  const EXCEPTION_RECORD* record = info ? info->ExceptionRecord : nullptr;
  void* address = record ? record->ExceptionAddress : nullptr;
  char module_name[MAX_PATH] = "unknown";
  unsigned long long offset = 0;
  HMODULE module = nullptr;
  if (address &&
      GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                             GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         static_cast<LPCSTR>(address), &module) &&
      module) {
    GetModuleFileNameA(module, module_name, MAX_PATH);
    offset = reinterpret_cast<unsigned long long>(address) -
             reinterpret_cast<unsigned long long>(module);
  }
  char text[MAX_PATH + 160];
  const int length = snprintf(
      text, sizeof(text),
      "exception=0x%08lX module=%s offset=0x%llX thread=%lu\r\n",
      record ? record->ExceptionCode : 0ul, module_name, offset,
      GetCurrentThreadId());
  HANDLE file = CreateFileW(g_native_crash_path, GENERIC_WRITE,
                            FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    DWORD written = 0;
    if (length > 0) {
      WriteFile(file, text, static_cast<DWORD>(length), &written, nullptr);
    }
    CloseHandle(file);
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

class KeepAwake {
 public:
  KeepAwake() {
    if (!SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)) {
      OutputDebugStringW(L"SignageX: keep-awake request failed\n");
    }
  }
  ~KeepAwake() { SetThreadExecutionState(ES_CONTINUOUS); }
};
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One player per installation/session, even if a shortcut is opened twice.
  const auto directory = KioskDirectory();
  if (directory.empty()) return EXIT_FAILURE;
  KioskHandle player_mutex(CreateMutexW(nullptr, TRUE,
      KioskObjectName(directory, L"player").c_str()));
  if (!player_mutex.get()) return EXIT_FAILURE;
  if (GetLastError() == ERROR_ALREADY_EXISTS) return EXIT_SUCCESS;

  const auto crash_path = directory + L"\\crash-native.txt";
  wcsncpy_s(g_native_crash_path, crash_path.c_str(), _TRUNCATE);
  SetUnhandledExceptionFilter(RecordNativeCrash);

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"SignageX Player", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  KeepAwake keep_awake;

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Reaching here means the message loop ended because WM_QUIT arrived, and
  // the only thing that posts WM_QUIT is Win32Window's WM_DESTROY handler
  // under SetQuitOnClose(true) -- i.e. somebody deliberately closed the
  // window. A crash never gets here; it terminates the process outright.
  // So this point is a reliable "the operator meant to close it" signal,
  // and the supervisor is told to stand down.
  //
  // Signalling here rather than relying on the exit code is deliberate,
  // because the exit code turned out not to be trustworthy. Observed
  // repeatedly on real installs: closing the window produced
  //   player exit=3221227010   (0xC0000602, STATUS_FAIL_FAST_EXCEPTION)
  // instead of 0, because something faults during native teardown after
  // this point -- so the process never reached `return EXIT_SUCCESS` and
  // the watchdog, whose policy correctly ignores a clean exit, saw a crash
  // code every single time and dutifully restarted a player the user had
  // just closed.
  //
  // This runs BEFORE the FlutterWindow destructor (which is where that
  // teardown fault happens), so the stop is recorded even if the process
  // dies on the way out. Fixing the teardown fault itself is separate and
  // still worth doing; this makes a deliberate close mean "stay closed"
  // regardless of how messily the process manages to exit.
  {
    KioskHandle stop(OpenEventW(EVENT_MODIFY_STATE, FALSE,
        KioskObjectName(directory, L"stop").c_str()));
    // Absent when the player was launched directly rather than by the
    // watchdog, which is fine -- there is nothing supervising it.
    if (stop.get()) SetEvent(stop.get());
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
