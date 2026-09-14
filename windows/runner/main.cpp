#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "kiosk_identity.h"

namespace {
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
