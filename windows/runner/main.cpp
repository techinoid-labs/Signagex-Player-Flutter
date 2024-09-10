#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <iostream>
#include <string>
#include <vector>
#include <memory>
#include "flutter_window.h"
#include "utils.h"

std::string ExecuteCommand(const char* cmd) {
  std::string result;
  char buffer[128];
  FILE* pipe = _popen(cmd, "r");
  if (!pipe) return "ERROR";
  while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
    result += buffer;
  }
  _pclose(pipe);
  return result;
}

std::string GetMotherboardSerial() {
  std::string command = "wmic baseboard get serialnumber";
  std::string serialNumber = ExecuteCommand(command.c_str());
  
  // Clean up the result to extract just the serial number
  serialNumber.erase(std::remove(serialNumber.begin(), serialNumber.end(), '\n'), serialNumber.end());
  serialNumber.erase(std::remove(serialNumber.begin(), serialNumber.end(), '\r'), serialNumber.end());
  return serialNumber;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line, _In_ int show_command) {
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
  if (!window.Create(L"digital_signage", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Platform channel setup to get motherboard serial number
  const auto channel_name = "com.example/motherboard_serial";
  flutter::MethodChannel<flutter::EncodableValue> channel(
      window.engine(), channel_name,
      &flutter::StandardMethodCodec::GetInstance());

  channel.SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getMotherboardSerial") {
          std::string serial_number = GetMotherboardSerial();
          result->Success(flutter::EncodableValue(serial_number));
        } else {
          result->NotImplemented();
        }
      });

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
