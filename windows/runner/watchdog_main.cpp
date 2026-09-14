#include <windows.h>
#include <shellapi.h>
#include <string>

#include "kiosk_identity.h"
#include "watchdog_policy.h"

namespace {
bool stopping = false;

LRESULT CALLBACK WatchdogWindow(HWND window, UINT message, WPARAM wparam,
                                LPARAM lparam) {
  if (message == WM_QUERYENDSESSION || message == WM_CLOSE ||
      (message == WM_ENDSESSION && wparam)) {
    stopping = true;
    return message == WM_QUERYENDSESSION ? TRUE : 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

// Pump shutdown/session messages even while waiting for a crashed child.
bool WaitUnlessStopped(HANDLE stop, DWORD milliseconds) {
  const auto deadline = GetTickCount64() + milliseconds;
  while (!stopping) {
    const auto now = GetTickCount64();
    const DWORD remaining = now >= deadline ? 0 :
        static_cast<DWORD>(deadline - now);
    const DWORD result = MsgWaitForMultipleObjects(
        1, &stop, FALSE, remaining, QS_ALLINPUT);
    if (result == WAIT_OBJECT_0 || result == WAIT_FAILED) return false;
    if (result == WAIT_TIMEOUT) return true;
    MSG message;
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) stopping = true;
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
  }
  return false;
}

// Left next to the exe for the next player process to find.
// Deliberately a file rather than an event or registry value: it must
// survive the supervisor itself being killed or the machine losing
// power, which is exactly when a crash is most worth reporting.
void WriteCrashMarker(const std::wstring& directory, DWORD exit_code) {
  const auto path = directory + L"\\crash-marker.txt";
  KioskHandle file(CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
                               nullptr, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_NORMAL, nullptr));
  if (file.get() == INVALID_HANDLE_VALUE) return;
  const auto text = std::to_string(exit_code);
  DWORD written = 0;
  WriteFile(file.get(), text.c_str(), static_cast<DWORD>(text.size()),
            &written, nullptr);
}

void Log(const std::wstring& directory, const std::string& message) {
  // One bounded log per installation; no dependency on Flutter/plugin startup.
  const auto path = directory + L"\\watchdog.log";
  WIN32_FILE_ATTRIBUTE_DATA data{};
  if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data) &&
      (data.nFileSizeHigh != 0 || data.nFileSizeLow > 1024 * 1024)) {
    MoveFileExW(path.c_str(), (path + L".previous").c_str(), MOVEFILE_REPLACE_EXISTING);
  }
  KioskHandle file(CreateFileW(path.c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (file.get() == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME time{};
  GetSystemTime(&time);
  const auto line = std::to_string(time.wYear) + "-" + std::to_string(time.wMonth) +
      "-" + std::to_string(time.wDay) + " " + std::to_string(time.wHour) + ":" +
      std::to_string(time.wMinute) + ":" + std::to_string(time.wSecond) +
      " UTC " + message + "\r\n";
  DWORD written = 0;
  WriteFile(file.get(), line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
}

BOOL CALLBACK ClosePlayerWindow(HWND window, LPARAM pid) {
  DWORD owner = 0;
  GetWindowThreadProcessId(window, &owner);
  if (owner == static_cast<DWORD>(pid)) PostMessageW(window, WM_CLOSE, 0, 0);
  return TRUE;
}

int StopWatchdog(const std::wstring& directory) {
  KioskHandle mutex(OpenMutexW(SYNCHRONIZE | MUTEX_MODIFY_STATE, FALSE,
      KioskObjectName(directory, L"watchdog").c_str()));
  if (!mutex.get()) {
    if (GetLastError() != ERROR_FILE_NOT_FOUND) return 1;
    KioskHandle player(OpenMutexW(SYNCHRONIZE, FALSE,
        KioskObjectName(directory, L"player").c_str()));
    return player.get() ? 1 : 0;  // Direct launch or a previously hung child.
  }
  // Handle a launcher that has acquired its mutex but not yet created its event.
  for (int attempt = 0; attempt < 50; ++attempt) {
    KioskHandle stop(OpenEventW(EVENT_MODIFY_STATE, FALSE,
        KioskObjectName(directory, L"stop").c_str()));
    if (stop.get()) {
      if (!SetEvent(stop.get())) return 1;
      const auto result = WaitForSingleObject(mutex.get(), 15000);
      if (result != WAIT_OBJECT_0 && result != WAIT_ABANDONED) return 1;
      ReleaseMutex(mutex.get());
      // The supervisor never force-kills a hung player. Tell Setup to stop
      // instead of replacing its files or racing an automatic relaunch.
      KioskHandle player(OpenMutexW(SYNCHRONIZE, FALSE,
          KioskObjectName(directory, L"player").c_str()));
      return player.get() ? 1 : 0;
    }
    Sleep(100);
  }
  return 1;
}
}  // namespace

int APIENTRY wWinMain(HINSTANCE instance, HINSTANCE, wchar_t*, int) {
  const auto directory = KioskDirectory();
  if (directory.empty()) return 1;
  int count = 0;
  auto arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  const bool stop_requested = arguments && count == 2 &&
      std::wstring(arguments[1]) == L"--stop";
  if (arguments) LocalFree(arguments);
  if (stop_requested) return StopWatchdog(directory);

  KioskHandle mutex(CreateMutexW(nullptr, TRUE,
      KioskObjectName(directory, L"watchdog").c_str()));
  if (!mutex.get()) return 1;
  if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;
  KioskHandle stop(CreateEventW(nullptr, TRUE, FALSE,
      KioskObjectName(directory, L"stop").c_str()));
  if (!stop.get()) return 1;
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WatchdogWindow;
  window_class.hInstance = instance;
  window_class.lpszClassName = L"SignageXWatchdog";
  if (!RegisterClassW(&window_class)) return 1;
  // Hidden top-level window receives session-end broadcasts (message-only
  // windows don't). It does not steal focus or show in the taskbar.
  const HWND window = CreateWindowW(window_class.lpszClassName, L"SignageX Watchdog",
      0, 0, 0, 0, 0, nullptr, nullptr, instance, nullptr);
  if (!window) return 1;
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  WatchdogPolicy policy;
  const auto executable = directory + L"\\SignageXPlayer.exe";
  Log(directory, "supervision started");
  while (WaitUnlessStopped(stop.get(), 0)) {
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION child{};
    std::wstring command = L"\"" + executable + L"\"";
    if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr,
                        FALSE, 0, nullptr, directory.c_str(), &startup, &child)) {
      Log(directory, "launch failed: " + std::to_string(GetLastError()));
      DestroyWindow(window);
      return 1;
    }
    KioskHandle process(child.hProcess);
    CloseHandle(child.hThread);
    const auto started = GetTickCount64();
    Log(directory, "player launched: " + std::to_string(child.dwProcessId));
    bool cancelled = false;
    while (WaitForSingleObject(process.get(), 0) == WAIT_TIMEOUT) {
      if (!WaitUnlessStopped(stop.get(), 250)) {
        cancelled = true;
        break;
      }
    }
    if (cancelled || !WaitUnlessStopped(stop.get(), 0)) {
      EnumWindows(ClosePlayerWindow, static_cast<LPARAM>(child.dwProcessId));
      WaitForSingleObject(process.get(), 10000);
      Log(directory, "supervision stopped for maintenance/session end");
      break;
    }
    DWORD code = 0;
    if (!GetExitCodeProcess(process.get(), &code)) break;
    const unsigned delay = policy.DelayAfterExit(code, GetTickCount64() - started);
    Log(directory, "player exit=" + std::to_string(code) +
        " restart delay seconds=" + std::to_string(delay));
    // Record an abnormal exit so the NEXT player run can upload the log
    // of the run that died. Only the supervisor knows an exit was
    // abnormal -- the replacement process starts with no memory of it --
    // and by then the interesting log has been rotated to ".previous".
    // Without this handover a crash on an unattended screen leaves no
    // trace anybody sees until someone is asked to fetch a file by hand.
    if (code != 0) {
      WriteCrashMarker(directory, code);
    }
    if (delay == 0 || !WaitUnlessStopped(stop.get(), delay * 1000)) break;
  }
  DestroyWindow(window);
  return 0;
}
