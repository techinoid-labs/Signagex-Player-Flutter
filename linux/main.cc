#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <gtk/gtk.h>
#include <iostream>
#include <fstream>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

std::string GetMotherboardSerial() {
  std::ifstream file("/sys/class/dmi/id/board_serial");
  std::string serialNumber;
  
  if (file.is_open()) {
    std::getline(file, serialNumber);
    file.close();
  } else {
    serialNumber = "ERROR: Could not read motherboard serial";
  }

  return serialNumber;
}

int main(int argc, char** argv) {
  // Initialize GTK
  gtk_init(&argc, &argv);

  // Initialize the Flutter Dart project
  flutter::DartProject project("data");

  std::vector<std::string> command_line_arguments = GetCommandLineArgumentsFromArgcArgv(argc, argv);
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Create the Flutter window
  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"digital_signage", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Platform channel to get motherboard serial number
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

  // GTK Main loop
  gtk_main();

  return EXIT_SUCCESS;
}
