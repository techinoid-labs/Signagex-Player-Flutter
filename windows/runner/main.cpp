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
  serialNumber.erase(std::remove(serialNumber.begin(), serialNumber.end(), '\n'), serialNumber.end());
  serialNumber.erase(std::remove(serialNumber.begin(), serialNumber.end(), '\r'), serialNumber.end());
  return serialNumber;
}

std::tuple<std::string, std::string, int> GetCpuInfo() {
  SYSTEM_INFO sysInfo;
  GetSystemInfo(&sysInfo);
  std::string architecture;
  switch (sysInfo.wProcessorArchitecture) {
    case PROCESSOR_ARCHITECTURE_AMD64: architecture = "x64"; break;
    case PROCESSOR_ARCHITECTURE_INTEL: architecture = "x86"; break;
    case PROCESSOR_ARCHITECTURE_ARM: architecture = "ARM"; break;
    default: architecture = "Unknown"; break;
  }
  std::string processor = "Unknown Processor";
  int cores = sysInfo.dwNumberOfProcessors;
  return std::make_tuple(architecture, processor, cores);
}

std::tuple<std::string, std::string, std::string> GetMemoryInfo() {
  MEMORYSTATUSEX statex;
  statex.dwLength = sizeof(statex);
  GlobalMemoryStatusEx(&statex);
  std::string totalMemory = std::to_string(statex.ullTotalPhys / (1024 * 1024)) + " MB";
  std::string availableMemory = std::to_string(statex.ullAvailPhys / (1024 * 1024)) + " MB";
  std::string usedMemory = std::to_string((statex.ullTotalPhys - statex.ullAvailPhys) / (1024 * 1024)) + " MB";
  return std::make_tuple(totalMemory, availableMemory, usedMemory);
}

std::tuple<std::string, std::string, std::string> GetBatteryInfo() {
  SYSTEM_POWER_STATUS sps;
  GetSystemPowerStatus(&sps);
  std::string batteryPercentage = std::to_string(sps.BatteryLifePercent) + "%";
  std::string voltage = "Not Available";
  std::string temperature = "Not Available";
  return std::make_tuple(batteryPercentage, voltage, temperature);
}

std::string GetCpuUsage() {
  return "Not Available";
}

std::tuple<std::string, std::string> GetStorageInfo() {
  ULARGE_INTEGER freeBytesAvailable, totalNumberOfBytes, totalNumberOfFreeBytes;
  GetDiskFreeSpaceEx("C:\\", &freeBytesAvailable, &totalNumberOfBytes, &totalNumberOfFreeBytes);
  std::string totalStorage = std::to_string(totalNumberOfBytes.QuadPart / (1024 * 1024 * 1024)) + " GB";
  std::string availableStorage = std::to_string(freeBytesAvailable.QuadPart / (1024 * 1024 * 1024)) + " GB";
  return std::make_tuple(totalStorage, availableStorage);
}

std::string GetRamInfo() {
  return "Included in Memory Information";
}

std::tuple<std::string, std::string> GetDeviceResolution() {
  DEVMODE devMode;
  EnumDisplaySettings(NULL, ENUM_CURRENT_SETTINGS, &devMode);
  std::string resolution = std::to_string(devMode.dmPelsWidth) + "x" + std::to_string(devMode.dmPelsHeight);
  std::string density = "Not Available";
  return std::make_tuple(resolution, density);
}

std::string GetCameraDetails() {
  return "Not Available";
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"digital_signage", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  const auto channel_name = "com.example/system_info";
  flutter::MethodChannel<flutter::EncodableValue> channel(
      window.engine(), channel_name,
      &flutter::StandardMethodCodec::GetInstance());

  channel.SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getSystemInfo") {
          flutter::EncodableMap systemInfo;
          
          auto cpuInfo = GetCpuInfo();
          systemInfo["cpu_information"] = flutter::EncodableMap{
              {"cpu_architecture", flutter::EncodableValue(std::get<0>(cpuInfo))},
              {"processor", flutter::EncodableValue(std::get<1>(cpuInfo))},
              {"cores", flutter::EncodableValue(std::get<2>(cpuInfo))}
          };

          auto memoryInfo = GetMemoryInfo();
          systemInfo["memory_information"] = flutter::EncodableMap{
              {"total_memory", flutter::EncodableValue(std::get<0>(memoryInfo))},
              {"available_memory", flutter::EncodableValue(std::get<1>(memoryInfo))},
              {"used_memory", flutter::EncodableValue(std::get<2>(memoryInfo))}
          };

          auto batteryInfo = GetBatteryInfo();
          systemInfo["battery_information"] = flutter::EncodableMap{
              {"battery_percentage", flutter::EncodableValue(std::get<0>(batteryInfo))},
              {"formatted_voltage", flutter::EncodableValue(std::get<1>(batteryInfo))},
              {"formated_tempature", flutter::EncodableValue(std::get<2>(batteryInfo))}
          };

          systemInfo["cpu_usage"] = flutter::EncodableValue(GetCpuUsage());

          auto storageInfo = GetStorageInfo();
          systemInfo["storage_info"] = flutter::EncodableMap{
              {"total_storage", flutter::EncodableValue(std::get<0>(storageInfo))},
              {"available_storage", flutter::EncodableValue(std::get<1>(storageInfo))}
          };

          systemInfo["ram_info"] = flutter::EncodableValue(GetRamInfo());

          auto resolution = GetDeviceResolution();
          systemInfo["device_resolution"] = flutter::EncodableMap{
              {"resolution", flutter::EncodableValue(std::get<0>(resolution))},
              {"density", flutter::EncodableValue(std::get<1>(resolution))}
          };

          systemInfo["camera_details"] = flutter::EncodableValue(GetCameraDetails());

          result->Success(flutter::EncodableValue(systemInfo));
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
