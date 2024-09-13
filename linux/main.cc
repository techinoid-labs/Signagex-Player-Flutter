#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <gtk/gtk.h>
#include <iostream>
#include <string>
#include <vector>
#include <memory>
#include <cstdlib>
#include <cstdio>
#include <sstream>
#include "flutter_window.h"
#include "utils.h"

std::string ExecuteCommand(const char* cmd) {
  std::string result;
  char buffer[128];
  FILE* pipe = popen(cmd, "r");
  if (!pipe) return "ERROR";
  while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
    result += buffer;
  }
  pclose(pipe);
  return result;
}

std::string GetLinuxSystemInfo(const char* cmd) {
  std::string result = ExecuteCommand(cmd);
  result.erase(std::remove(result.begin(), result.end(), '\n'), result.end());
  result.erase(std::remove(result.begin(), result.end(), '\r'), result.end());
  return result;
}

std::tuple<std::string, std::string, int> GetCpuInfo() {
  std::string architecture = GetLinuxSystemInfo("uname -m");
  std::string processor = GetLinuxSystemInfo("lscpu | grep 'Model name' | awk -F: '{print $2}'");
  int cores = std::stoi(GetLinuxSystemInfo("nproc"));
  return std::make_tuple(architecture, processor, cores);
}

std::tuple<std::string, std::string, std::string> GetMemoryInfo() {
  std::string totalMemory = GetLinuxSystemInfo("grep MemTotal /proc/meminfo | awk '{print $2}'") + " kB";
  std::string availableMemory = GetLinuxSystemInfo("grep MemAvailable /proc/meminfo | awk '{print $2}'") + " kB";
  std::string usedMemory = GetLinuxSystemInfo("grep MemTotal /proc/meminfo | awk '{print $2}'") - 
                           GetLinuxSystemInfo("grep MemAvailable /proc/meminfo | awk '{print $2}'") + " kB";
  return std::make_tuple(totalMemory, availableMemory, usedMemory);
}

std::tuple<std::string, std::string, std::string> GetBatteryInfo() {
  std::string batteryPercentage = GetLinuxSystemInfo("cat /sys/class/power_supply/BAT0/capacity") + "%";
  std::string voltage = GetLinuxSystemInfo("cat /sys/class/power_supply/BAT0/voltage_now") + " uV";
  std::string temperature = GetLinuxSystemInfo("cat /sys/class/power_supply/BAT0/temp") + " C";
  return std::make_tuple(batteryPercentage, voltage, temperature);
}

std::string GetCpuUsage() {
  return GetLinuxSystemInfo("top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%* id.*/\\1/' | awk '{print 100 - $1}'");
}

std::tuple<std::string, std::string> GetStorageInfo() {
  std::string totalStorage = GetLinuxSystemInfo("df -h / | grep / | awk '{print $2}'");
  std::string availableStorage = GetLinuxSystemInfo("df -h / | grep / | awk '{print $4}'");
  return std::make_tuple(totalStorage, availableStorage);
}

std::string GetRamInfo() {
  return "Included in Memory Information";
}

std::tuple<std::string, std::string> GetDeviceResolution() {
  return std::make_tuple(GetLinuxSystemInfo("xrandr | grep '*' | awk '{print $1}'"), "Not Available");
}

std::string GetCameraDetails() {
  return "Not Available";
}

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);

  flutter::DartProject project(L"data");
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  if (!window.Create("digital_signage", 10, 10, 1280, 720)) {
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

  gtk_main();
  return EXIT_SUCCESS;
}
