import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:battery_plus/battery_plus.dart';
import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_info2/system_info2.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:digital_signage/models/compaign_model.dart';
import 'package:digital_signage/models/play_list_model.dart';
import 'package:digital_signage/utils/globle_variable.dart';
import 'package:digital_signage/view_models/system_apply_settings_vm.dart';

import '../data/api_repository/api_repository.dart';
import '../services/mqtt_client_service.dart';
import '../utils/constants.dart';

enum MqttState {
  initial,
  success,
  failure,
  noContent,
  campaignScreen,
  connectionScreen,
  noInternet,
  downloading,
  pairedScreen,
  playlistScreen
}

class MqttViewModel extends ChangeNotifier {
  final MqttClientService _mqttClientService;
  final DeviceSettingsViewModel deviceSettings = DeviceSettingsViewModel();

  MqttState _state = MqttState.initial;
  Map<String, dynamic> devicesinfo = deviceInfoMap;

  Map<String, dynamic>? _deviceInfo;
  List<dynamic> _mediaList = [];

  Map<String, dynamic>? get deviceInfo => _deviceInfo;
  static const _channel = MethodChannel('com.example/device_info');
  static const platform = MethodChannel('com.example/network');
  List<dynamic> get mediaList => _mediaList;
  MqttState get state => _state;
  String _topic = "";
  String get topic => _topic;

  PlayListModel? _playListModel;

  PlayListModel? get playListModel => _playListModel;

  CampaignModel? _campaignModel;

  CampaignModel? get campaignModel => _campaignModel;

  Map<String, String?> macAddresses = {
    'wlan0': null,
    'eth0': null,
  };
  Map<String, dynamic> storedJsonObj = {};
  Future<void> _loadStoredJsonObj() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? jsonString = prefs.getString('jsonObj');

    if (jsonString != null) {
      print('Retrieved JSON from SharedPreferences: $jsonString');
      storedJsonObj = jsonDecode(jsonString);
      print('Loaded JSON Object: $storedJsonObj');
      notifyListeners();
    } else {
      print('No JSON Object found in SharedPreferences.');
    }
  }

  Future<Map<String, dynamic>?> retrieveStoredResponse() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? jsonString = prefs.getString('apiResponse');

    if (jsonString != null) {
      final jsonResponse = jsonDecode(jsonString) as Map<String, dynamic>;
      print('Retrieved stored response: $jsonResponse');
      _topic = jsonResponse["player_code"];
      debugPrint("This is the response from the$topic API: $jsonResponse");
      globleTopic = _topic;
      return jsonResponse;
    } else {
      print('No stored response found.');
      return null;
    }
  }

  Future<void> loadDeviceInfoFromSharedPreferences() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? jsonString = prefs.getString('deviceInfoMap');

    if (jsonString != null) {
      // Decode the JSON string back to a Map
      deviceInfoMap = Map<String, dynamic>.from(jsonDecode(jsonString));
      print('Loaded device info from SharedPreferences: $deviceInfoMap');
    } else {
      print('No device info found in SharedPreferences.');
    }
  }

  MqttViewModel(this._mqttClientService) {
    _mqttClientService.receivedMessageNotifier.addListener(_updateMessage);
    _mqttClientService.onMessageReceived = _handleIncomingMessage;

    fetchAllInfo();
    _initializeBasedOnPlatform();
    _monitorConnectivity();
  }

  // Monitor connectivity changes and reinitialize MQTT on connection recovery
  void _monitorConnectivity() async {
    await _loadStoredJsonObj();
    await retrieveStoredResponse();
    await loadDeviceInfoFromSharedPreferences();
    InternetConnectionChecker().onStatusChange.listen((status) async {
      final hasConnection = status == InternetConnectionStatus.connected;

      if (hasConnection) {
        print("this is data $storedJsonObj");

        if (storedJsonObj["action"] == "publish_playlist") {
          await _mqttClientService.connect();

          subsibeMessage(_topic);
          publishMessage(globleTopic, jsonEncode(deviceInfoMap));
          _playListModel = playListModelFromJson(jsonEncode(storedJsonObj));

          print("model data ${_playListModel!.data.playlist.media}");
          print(_mediaList);
          for (var media in _playListModel!.data.playlist.media!) {
            print("Media URL: $media");

            _startDownloading();
          }
        } else if (storedJsonObj["action"] == "publish_campaign") {
          await _mqttClientService.connect();

          subsibeMessage(_topic);

          publishMessage(globleTopic, jsonEncode(deviceInfoMap));
          _campaignModel = campaignModelFromJson(jsonEncode(storedJsonObj));
          print("model data ${_campaignModel!.data.zones}");
          print(_mediaList);
          for (var media in _campaignModel!.data.zones) {
            print("Media URL: $media");

            _startDownloadingForCampaign();
          }
        } else {
          _mqttConnection();
        }
      } else {
        if (storedJsonObj["action"] == "publish_playlist") {
          print(
              "i am in actionPlaylist${storedJsonObj["data"]["playlist"]["media"]}");

          _playListModel = playListModelFromJson(jsonEncode(storedJsonObj));

          print("model data ${_playListModel!.data.playlist.media}");
          print(_mediaList);
          for (var media in _playListModel!.data.playlist.media!) {
            print("Media URL: $media");

            _startDownloading();
          }
        } else if (storedJsonObj["action"] == "publish_campaign") {
          _campaignModel = campaignModelFromJson(jsonEncode(storedJsonObj));

          for (var media in _campaignModel!.data.zones) {
            print("Media URL: $media");

            _startDownloadingForCampaign();
          }
        } else {
          _state = MqttState.noInternet;
          notifyListeners();
        }
      }
    });
  }

  Future<void> checkAndRequestPermissions() async {
    final status = await Permission.location.status;
    if (!status.isGranted) {
      await Permission.location.request();
    }
  }

  Future<void> fetchNetworkInfo() async {
    final NetworkInfo networkInfo = NetworkInfo();

    try {
      // Fetch network information
      final networkName = await networkInfo.getWifiName();
      final ipAddress = await networkInfo.getWifiIP();
      devicesinfo["last_ip_address"] = ipAddress;

      devicesinfo["network_name"] = networkName ?? "";

      print('Network Name (SSID): $networkName');
      print('IP Address: $ipAddress');
    } catch (e) {
      print('Failed to get network info: ${e.toString()}');
    }
  }

  Future<void> fetchBatteryInfo() async {
    final Battery battery = Battery();

    try {
      // Fetch battery information
      final batteryLevel = await battery.batteryLevel;
      print(batteryLevel);
    } catch (e) {
      print('Failed to get battery level: ${e.toString()}');
    }
  }

  String uniqueid = "";
  Future<String> getDeviceID() async {
    final result = await Process.run('powershell', [
      '-Command',
      'Get-WmiObject -Class Win32_ComputerSystemProduct | Select-Object -ExpandProperty UUID'
    ]);

    if (result.exitCode != 0) {
      return 'Error: ${result.stderr}';
    }

    return result.stdout.trim();
  }

  Future<void> fetchSystemInfo() async {
    try {
      // Common System Information
      final kernelArchitecture = SysInfo.kernelArchitecture.toString();
      print('Kernel Architecture: $kernelArchitecture');

      final kernelBitness = SysInfo.kernelBitness;
      print('Kernel Bitness: $kernelBitness');

      final kernelName = SysInfo.kernelName;
      print('Kernel Name: $kernelName');

      final kernelVersion = SysInfo.kernelVersion;
      print('Kernel Version: $kernelVersion');
      devicesinfo["android_version"] = kernelVersion;
      final operatingSystemName = SysInfo.operatingSystemName;
      print('Operating System Name: $operatingSystemName');

      final operatingSystemVersion = SysInfo.operatingSystemVersion;
      print('Operating System Version: $operatingSystemVersion');

      final userDirectory = SysInfo.userDirectory;
      print('User Directory: $userDirectory');

      final userId = SysInfo.userId;
      print('User ID: $userId');

      final userName = SysInfo.userName;
      print('User Name: $userName');

      final userSpaceBitness = SysInfo.userSpaceBitness;
      print('User Space Bitness: $userSpaceBitness');

      // Memory Information
      final totalPhysicalMemory = SysInfo.getTotalPhysicalMemory();
      print('Total Physical Memory: $totalPhysicalMemory bytes');

      final freePhysicalMemory = SysInfo.getFreePhysicalMemory();
      print('Free Physical Memory: $freePhysicalMemory bytes');

      final totalVirtualMemory = SysInfo.getTotalVirtualMemory();
      print('Total Virtual Memory: $totalVirtualMemory bytes');

      final freeVirtualMemory = SysInfo.getFreeVirtualMemory();
      print('Free Virtual Memory: $freeVirtualMemory bytes');
    } catch (e) {
      print("Failed to get system info: '${e.toString()}'.");
    }
  }

  Future<void> fetchAllInfo() async {
    await fetchNetworkInfo();
    await fetchBatteryInfo();
    await fetchSystemInfo();
  }

  Future<void> _initializeMacAddresses() async {
    final macAddressesMap = await getListOfMacAddresses();
    if (macAddressesMap != null) {
      final List<dynamic> macList = macAddressesMap['macAddress'];
      for (var item in macList) {
        final interface = item['interface'] as String?;
        final mac = item['mac'] as String?;
        if (interface != null && mac != null) {
          macAddresses[interface] = mac;
        }
      }

      print("Fetched MAC addresses: $macAddresses");
      devicesinfo["mac_address"]["macAddress"][0]["interface"] = "wlan0";
      devicesinfo["mac_address"]["macAddress"][1]["interface"] = "eth0";
      if (devicesinfo["mac_address"]["macAddress"][0]["interface"] == "wlan0") {
        devicesinfo["mac_address"]["macAddress"][0]["mac"] =
            macAddresses["wlan0"] ?? "";
      } else {
        devicesinfo["mac_address"]["macAddress"][1]["mac"] =
            macAddresses["eth0"] ?? "";
      }
      debugPrint("this is object$deviceInfoMap");
    } else {
      print("No MAC addresses found.");
    }
  }

  static Future<Map<String, dynamic>?> getListOfMacAddresses() async {
    final String? macAddressesJson =
        await platform.invokeMethod('getListOfMacAddresses');
    if (macAddressesJson != null) {
      return jsonDecode(macAddressesJson);
    }
    return null;
  }

  static Future<String?> getWifiMacAddress() async {
    return await _channel.invokeMethod('getWifiMacAddress');
  }

  static Future<String?> getEthernetMacAddress() async {
    return await _channel.invokeMethod('getEthernetMacAddress');
  }

  Future<void> _initializeBasedOnPlatform() async {
    if (Platform.isAndroid) {
      await _initializeMacAddresses();
      getDeviceInfoAndroid();
    } else if (Platform.isIOS) {
      final identifier =
          await _channel.invokeMethod<String>('getDeviceIdentifier');
      print('iOS Device Identifier: $identifier');
      devicesinfo["mac_address"]["platform"] = "IOS";
      devicesinfo["mac_address"]["macAddress"][0]["interface"] = "wlan0";
      if (devicesinfo["mac_address"]["macAddress"][0]["interface"] == "wlan0") {
        devicesinfo["mac_address"]["macAddress"][0]["mac"] = identifier;
      }
      getDeviceInfo();
    } else if (Platform.isMacOS) {
      await getDeviceIdentifiersForMac();
    } else if (Platform.isWindows) {
      await getSystemDataForWindows();
    } else if (Platform.isLinux) {
      await getDataForLinux();
    }
  }

  Future<void> getDeviceInfoAndroid() async {
    try {
      final String? result = await platform.invokeMethod('getSystemData');
      if (result != null) {
        print("Device Info from Android: $result");

        // Parse the JSON result
        final Map<String, dynamic> deviceInfo = jsonDecode(result);
        devicesinfo["device_info"] = deviceInfo;

        // Extract and parse the `cpu_detailed_information` field
        final cpuDetailedInfo =
            deviceInfo["cpu_detailed_information"] as String?;
        if (cpuDetailedInfo != null) {
          // Split the string by double newlines to separate processor blocks
          final processorBlocks = cpuDetailedInfo.trim().split('\n\n');

          final List<Map<String, String>> processorsList = [];

          for (var block in processorBlocks) {
            final lines = block.split('\n');
            final Map<String, String> processorMap = {};

            for (var line in lines) {
              final parts = line.split(':');
              if (parts.length == 2) {
                final key =
                    parts[0].trim().replaceAll(' ', '_').replaceAll('\t', '');
                final value = parts[1].trim();
                processorMap[key] = value;
              }
            }
            processorsList.add(processorMap);
          }

          // Update `cpu_detailed_information` in the device info map
          deviceInfo["cpu_detailed_information"] = processorsList;
        }

        debugPrint("this is ${deviceInfo["cpu_detailed_information"]}");
        devicesinfo["sender"] = "android";
        devicesinfo["android_version"] = deviceInfo["android_version"];
        devicesinfo["last_seen"] = deviceInfo["last_seen"];
        devicesinfo["device_model"] = deviceInfo["device_model"];
        devicesinfo["network_name"] = deviceInfo["network_name"];
        devicesinfo["time_zone"] = deviceInfo["time_zone"];
        devicesinfo["last_ip_address"] = deviceInfo["last_ip_address"];
        devicesinfo["cpu_information"]["processor"] =
            deviceInfo["cpu_information"]["processor"];
        devicesinfo["cpu_information"]["count_cores"] =
            deviceInfo["cpu_information"]["count_cores"];
        devicesinfo["memory_information"]["total_memory"] =
            int.parse(deviceInfo["memory_information"]["total_memory"]);
        devicesinfo["memory_information"]["available_memory"] =
            int.parse(deviceInfo["memory_information"]["available_memory"]);
        devicesinfo["memory_information"]["used_memory"] =
            int.parse(deviceInfo["memory_information"]["used_memory"]);
        devicesinfo["battery_information"]["battery_percentage"] = num.tryParse(
                deviceInfo["battery_information"]["battery_percentage"]
                        as String? ??
                    '') ??
            0;
        devicesinfo["battery_information"]["formatted_voltage"] = num.tryParse(
                deviceInfo["battery_information"]["formatted_voltage"]
                        as String? ??
                    '') ??
            0;

        devicesinfo["battery_information"]["formatted_temperature"] =
            num.tryParse(deviceInfo["battery_information"]
                        ["formatted_temperature"] as String? ??
                    '') ??
                0;
        devicesinfo["cpu_detailed_information"]["cpu_detailed_information"] =
            deviceInfo["cpu_detailed_information"];
        devicesinfo["hardware_details"] = deviceInfo["hardware_details"];
        devicesinfo["storage_info"]["total_storage"] =
            deviceInfo["storage_info"]["total_storage"];
        devicesinfo["storage_info"]["available_storage"] =
            deviceInfo["storage_info"]["available_storage"];
        devicesinfo["ram_info"] = deviceInfo["ram_info"];
        devicesinfo["device_resolution"]["width"] =
            deviceInfo["device_resolution"]["width"];
        devicesinfo["device_resolution"]["height"] =
            deviceInfo["device_resolution"]["height"];
        devicesinfo["camera_details"] =
            deviceInfo["camera_details"]["lens_facing"];
        debugPrint("this is full object$deviceInfoMap");
        _fetchCurrentLocation();
        notifyListeners();
      } else {
        print("Failed to get device info");
      }
    } on PlatformException catch (e) {
      print("Failed to get device info: '${e.message}'.");
    }
  }

  // Method to check and request location permissions
  Future<void> _getLocation() async {
    final status = await Permission.location.status;
    if (status.isGranted) {
      Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      print(
          'location Latitude: ${position.latitude}, Longitude: ${position.longitude}');
    } else if (status.isDenied) {
      // Handle permission denied case
    } else if (status.isPermanentlyDenied) {
      // Handle permission permanently denied case
    }
  }

  Future<void> _fetchCurrentLocation() async {
    try {
      await _getLocation();

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      devicesinfo["latitude"] = position.latitude;
      devicesinfo["longitude"] = position.longitude;

      print('sadasdasasda$deviceInfoMap');
    } catch (e) {
      print('Error fetching location: $e');
    }
  }

  Future<void> getDeviceInfo() async {
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod('getDeviceInfo');

      if (result != null) {
        print("this is result$result");
        _deviceInfo = Map<String, dynamic>.from(result);
        print('Device Info: $_deviceInfo');
        devicesinfo["sender"] = "ios";
        devicesinfo["android_version"] = _deviceInfo!["ios_version"];
        devicesinfo["storage_info"]["total_storage"] =
            _deviceInfo!["storage_info"]["total_storage"];
        devicesinfo["storage_info"]["available_storage"] =
            _deviceInfo!["storage_info"]["free_storage"];
        devicesinfo["cpu_information"]["count_cores"] =
            _deviceInfo!["cpu_information"]["processor_count"];
        devicesinfo["time_zone"] = _deviceInfo!["time_zone"];
        devicesinfo["battery_information"]["battery_percentage"] =
            _deviceInfo!["battery_information"]["battery_level"];
        devicesinfo["device_model"] = _deviceInfo!["name"];
        debugPrint("this is dzzata$deviceInfoMap");
        _fetchCurrentLocation();
      } else {
        _deviceInfo = null;
      }

      notifyListeners();
    } on PlatformException catch (e) {
      print("Failed to get device info: '${e.message}'.");
    }
  }

  double _screenWidth = 0;
  double _screenHeight = 0;

  double get screenWidth => _screenWidth;
  double get screenHeight => _screenHeight;

  void setScreenSize(double width, double height) {
    _screenWidth = width;
    _screenHeight = height;
    devicesinfo["device_resolution"] = "$_screenWidth x $screenHeight";

    notifyListeners();
  }

  Future<void> getSystemDataForWindows() async {
    try {
      final result = await getAllSystemInfo();
      if (result.exitCode == 0) {
        final output = result.stdout.trim();
        print(output);

        final Map<String, dynamic> systemInfo = jsonDecode(output);
        devicesinfo["sender"] = "windows";
        devicesinfo["time_zone"] = systemInfo["TimeZone"];
        devicesinfo["mac_address"]["platform"] = "Windows";
        devicesinfo["mac_address"]["macAddress"][0]["interface"] = "wlan0";
        if (devicesinfo["mac_address"]["macAddress"][0]["interface"] ==
            "wlan0") {
          devicesinfo["mac_address"]["macAddress"][0]["mac"] =
              systemInfo["DeviceID"];
        }
        devicesinfo["ram_info"] = systemInfo["InstalledRAM"].toString();

        devicesinfo["hardware_details"]["model"] = systemInfo["DeviceName"];
        print(systemInfo["TimeZone"]);
        devicesinfo["hardware_details"]["device_id"] = systemInfo["DeviceID"];
        devicesinfo["storage_info"]["total_storage"] =
            systemInfo["Drives"][0]["TotalSpaceGB"].toString();

        devicesinfo["storage_info"]["available_storage"] =
            systemInfo["Drives"][0]["FreeSpaceGB"].toString();
        print(systemInfo["TimeZone"]);
        devicesinfo["hardware_details"]["ram"] = systemInfo["InstalledRAM"];
        devicesinfo["cpu_information"]["cpu_architecture"] =
            systemInfo["CPUArchitecture"];
        devicesinfo["cpu_information"]["processor"] = systemInfo["CPUInfo"];
        systemInfo.forEach((key, value) {
          print('$key: $value');
        });

        _fetchCurrentLocation();
        await _checkPairingStatus();
      } else {
        print('Error: ${result.stderr}');
      }
    } catch (e) {
      print('An error occurred: $e');
    }
  }

  Future<ProcessResult> getAllSystemInfo() {
    return Process.run('powershell', [
      '-Command',
      '''
    # Get drive information
    \$drives = Get-WmiObject -Class Win32_LogicalDisk | ForEach-Object {
      [PSCustomObject]@{
        "DriveLetter" = \$_."DeviceID"
        "TotalSpaceGB" = [math]::round(\$_."Size" / 1GB, 2)
        "FreeSpaceGB" = [math]::round(\$_."FreeSpace" / 1GB, 2)
        "FileSystem" = \$_."FileSystem"
      }
    }

    # Get other system information
    \$info = @{
      "CPUInfo" = (Get-WmiObject -Class Win32_Processor | Select-Object -ExpandProperty Name);
      "CPUArchitecture" = (Get-WmiObject -Class Win32_Processor | Select-Object -ExpandProperty Architecture);
      "AvailableMemory" = (Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -ExpandProperty FreePhysicalMemory);
      "TimeZone" = (Get-TimeZone).Id;
      
      "DeviceName" = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Name);
      "InstalledRAM" = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty TotalPhysicalMemory);
      "DeviceID" = (Get-WmiObject -Class Win32_ComputerSystemProduct | Select-Object -ExpandProperty UUID);
      "Drives" = \$drives
    }

    # Output the information as JSON
    \$info | ConvertTo-Json
    '''
    ]);
  }

  Future<void> getDataForLinux() async {
    try {
      final result = await getAllSystemInfoFLinux();
      if (result.exitCode == 0) {
        final output = result.stdout.trim();

        // Parse the JSON output
        final Map<String, dynamic> systemInfo = jsonDecode(output);

        devicesinfo["sender"] = "Linux";
        devicesinfo["time_zone"] = systemInfo["TimeZone"];
        devicesinfo["mac_address"]["platform"] = "Linux";
        devicesinfo["mac_address"]["macAddress"][0]["interface"] = "wlan0";
        if (devicesinfo["mac_address"]["macAddress"][0]["interface"] ==
            "wlan0") {
          devicesinfo["mac_address"]["macAddress"][0]["mac"] =
              systemInfo["MacAddress"];
        }
        devicesinfo["ram_info"] = systemInfo["InstalledRAM"].toString();

        devicesinfo["hardware_details"]["model"] = systemInfo["DeviceName"];
        print(systemInfo["TimeZone"]);
        devicesinfo["hardware_details"]["device_id"] = systemInfo["MacAddress"];
        devicesinfo["storage_info"]["total_storage"] =
            systemInfo["DiskCapacity"].toString();

        print(systemInfo["TimeZone"]);
        devicesinfo["hardware_details"]["ram"] = systemInfo["InstalledRAM"];
        devicesinfo["cpu_information"]["cpu_architecture"] =
            systemInfo["CPUArchitecture"];
        devicesinfo["cpu_information"]["processor"] = systemInfo["CPUInfo"];

        // Print all the system information
        systemInfo.forEach((key, value) {
          print('$key: $value');
        });

        _fetchCurrentLocation();
        await _checkPairingStatus();
      } else {
        print('Error: ${result.stderr}');
      }
    } catch (e) {
      print('An error occurred: $e');
    }
  }

  Future<String> getDeviceIDForLinux() async {
    final result =
        await Process.run('bash', ['-c', 'sudo dmidecode -s system-uuid']);

    if (result.exitCode != 0) {
      return 'Error: ${result.stderr}';
    }

    return result.stdout.trim();
  }

  Future<ProcessResult> getAllSystemInfoFLinux() {
    return Process.run('bash', [
      '-c',
      '''
    # Get system information
    mac_address=\$(ip addr show | grep 'link/ether' | awk '{print \$2}' | head -n 1)
    serial_number=\$(sudo dmidecode -s system-serial-number)
    os_version=\$(uname -r)
    cpu_info=\$(lscpu | grep 'Model name' | awk -F: '{print \$2}' | xargs)
    cpu_architecture=\$(uname -m)
    available_memory=\$(free -m | grep 'Mem:' | awk '{print \$7}')
    ram_info=\$(sudo dmidecode -t memory | grep -A16 'Memory Device' | grep -E 'Size|Manufacturer|Speed' | grep -v 'No Module Installed')
    network_adapters=\$(ip link show | awk -F: '/^[0-9]+:/{print \$2}' | xargs)
    time_zone=\$(timedatectl | grep 'Time zone' | awk '{print \$3}')
    device_name=\$(hostname)
    installed_ram=\$(free -m | grep 'Mem:' | awk '{print \$2}')
    product_id=\$(sudo dmidecode -s system-product-name)
    disk_capacity=\$(df -h --total | grep 'total' | awk '{print \$2}')

    # Create JSON structure including Disk Capacity
    info=\$(cat <<EOF
    {
      "MacAddress": "\$mac_address",
      "SerialNumber": "\$serial_number",
      "OSVersion": "\$os_version",
      "CPUInfo": "\$cpu_info",
      "CPUArchitecture": "\$cpu_architecture",
      "AvailableMemory": "\$available_memory MB",
      "RAMInfo": "\$ram_info",
      "NetworkAdapters": "\$network_adapters",
      "TimeZone": "\$time_zone",
      "DeviceName": "\$device_name",
      "InstalledRAM": "\$installed_ram MB",
      "ProductID": "\$product_id",
      "DiskCapacity": "\$disk_capacity"
    }
EOF
    )

    # Output JSON
    echo "\$info"
    '''
    ]);
  }

  Future<Map<String, dynamic>?> getDeviceIdentifiersForMac() async {
    try {
      const channel = MethodChannel('com.example/systemInfo');

      // Fetch all system info (as a Map)
      final Map<dynamic, dynamic>? systemInfo =
          await channel.invokeMethod('getSystemInfo');
      // final battery = Battery();
      // final batteryLevel = await battery.batteryLevel;
      // final batteryStatus = await battery.batteryState;
      // final batteryPlugged = await battery.onBatteryStateChanged;
      // print(
      //     "this is batterydata $batteryLevel....$batteryPlugged...$batteryStatus");
      if (systemInfo != null) {
        // devicesinfo["mac_address"]["platform"] = "iOS";
        // devicesinfo["battery_information"]["battery_percentage"] = batteryLevel;
        devicesinfo["mac_address"]["macAddress"][0]["interface"] = "wlan0";
        if (devicesinfo["mac_address"]["macAddress"][0]["interface"] ==
            "wlan0") {
          devicesinfo["mac_address"]["macAddress"][0]["mac"] =
              systemInfo["uuid"];
        }
        print("System Info: $systemInfo"); // Print all system information
        devicesinfo["android_version"] = systemInfo["os_version"];
        devicesinfo["platform"] = "macos";
        devicesinfo["device_resolution"] = systemInfo["device_resolution"];
        devicesinfo["time_zone"] = systemInfo["time_zone"];
        devicesinfo["cpu_information"] = systemInfo["cpu_information"];
        devicesinfo["memory_information"] = systemInfo["memory_information"];
        devicesinfo["storage_info"] = systemInfo["storage_info"];

        _fetchCurrentLocation();
        return Map<String, dynamic>.from(systemInfo);
      } else {
        print("Failed to retrieve system info.");
        return null;
      }
    } on PlatformException catch (e) {
      print("Failed to get device identifier: '${e.message}'.");
      return null;
    }
  }

  static Future<String?> getDeviceIdentifiers() async {
    try {
      final String? identifier =
          await _channel.invokeMethod('getDeviceIdentifier');
      print("Unique ID: $identifier");
      return identifier;
    } on PlatformException catch (e) {
      print("Failed to get device identifier: '${e.message}'.");
      return null;
    }
  }

  String get receivedMessage =>
      _mqttClientService.receivedMessageNotifier.value;

  Future<void> _mqttConnection() async {
    try {
      debugPrint("Attempting to reconnect to MQTT.");
      await _mqttClientService.connect();
      _state = MqttState.connectionScreen;
      notifyListeners();
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        await _checkPairingStatus();
      }
    } catch (error) {
      _state = MqttState.noInternet;
      notifyListeners();
      debugPrint("Error during MQTT reinitialization: $error");
    }
  }

  double _progress = 0.0;
  bool _isDownloading = false;
  String _downloadedFilePath = '';

  double get progress => _progress;
  bool get isDownloading => _isDownloading;
  String get downloadedFilePath => _downloadedFilePath;

  int _downloadCount = 0;
  double _overallProgress = 0.0;
  double get overallProgress => _overallProgress;

  void _startDownloading() async {
    if (_state == MqttState.downloading) {
      print("Downloads are already in progress.");
      return;
    }

    _downloadCount = _playListModel!.data.playlist.media!.length;
    print(
        "Total files ${_playListModel!.data.playlist.media!.length} to download: $_downloadCount");

    if (_downloadCount > 0) {
      _state = MqttState.downloading;
      notifyListeners();
    } else {
      _state = MqttState.noContent;
      notifyListeners();
      return;
    }

    int completedDownloads = 0;
    _overallProgress = 0.0;

    for (var media in _playListModel!.data.playlist.media!) {
      String mediaUrl = media.mediaUrl;
      print("Starting download check for Media URL: $mediaUrl");

      String filename = _extractFilename(mediaUrl);
      print('Extracted filename: $filename');
      Directory? directory = await _getDirectory();
      if (directory == null) {
        print('Unable to determine directory');
        throw Exception('Unable to determine directory');
      }
      print('Download directory: ${directory.path}');

      String filePath = '${directory.path}/$filename';

      bool fileExists = await File(filePath).exists();
      if (fileExists) {
        print('File already exists: $filePath');
        _mediaPath.add(filePath);
        _updateMediaModel();

        completedDownloads++;
        _overallProgress = completedDownloads / _downloadCount;
        print(
            'Overall progress: ${(_overallProgress * 100).toStringAsFixed(2)}%');
        notifyListeners();
      } else {
        await downloadFile(mediaUrl).then((_) {
          completedDownloads++;
          _overallProgress = completedDownloads / _downloadCount;
          print(
              'Overall progress: ${(_overallProgress * 100).toStringAsFixed(2)}%');
          notifyListeners();
        }).catchError((error) {
          print("Error downloading file: $error");
          _state = MqttState.failure;
          notifyListeners();
        });
      }

      if (completedDownloads == _downloadCount) {
        print("All files processed.");

        _state = MqttState.playlistScreen;
        notifyListeners();
      }
    }
  }

  final List<String> _mediaPath = [];
  List<String> get mediaPath => _mediaPath;

  List<PlayListModel> storePlaylist = [];

  void _updateMediaModel() {
    if (_playListModel != null &&
        _playListModel!.data.playlist.media!.isNotEmpty) {
      for (int i = 0; i < _playListModel!.data.playlist.media!.length; i++) {
        var mediaItem = _playListModel!.data.playlist.media![i];
        if (i < _mediaPath.length) {
          mediaItem.mediaUrl = _mediaPath[i];
        }
      }
    }
  }

  Future<void> downloadFile(String url) async {
    // if (Platform.isAndroid) {
    //   print('Requesting storage permission...');
    //   var status = Permission.storage;

    //   if (Platform.version.startsWith('13') ||
    //       int.parse(Platform.operatingSystemVersion.split(' ').first) >= 13) {
    //     // Android 13+ requires specific media permissions
    //     var statuses = await [
    //       Permission.photos, // READ_MEDIA_IMAGES equivalent
    //       Permission.videos, // READ_MEDIA_VIDEO equivalent
    //       Permission.audio // READ_MEDIA_AUDIO equivalent
    //     ].request();

    //     if (statuses.values
    //         .any((permissionStatus) => !permissionStatus.isGranted)) {
    //       print('Media permissions denied');
    //       throw Exception('Required media permissions not granted');
    //     }
    //     print('Media permissions granted');
    //   } else {
    //     // Older Android versions
    //     var status = await Permission.storage.request();
    //     if (!status.isGranted) {
    //       print('Storage permission denied $status');
    //       throw Exception('Storage permission not granted');
    //     }
    //     print('Storage permission granted');
    //   }
    // }

    try {
      String filename = _extractFilename(url);
      Directory? directory = await _getDirectory();
      if (directory == null) {
        print('Unable to determine directory');
        throw Exception('Unable to determine directory');
      }

      String filePath = '${directory.path}/$filename';
      Dio dio = Dio();
      print('Starting download from URL: $url to $filePath');
      await dio.download(
        url,
        filePath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            double progress = received / total;
            print('Download progress: ${(progress * 100).toStringAsFixed(2)}%');
          }
        },
      );

      _mediaPath.add(filePath);
      _updateMediaModel();

      print('File downloaded to: $filePath');
    } catch (e) {
      print('Download failed: $e');
      throw Exception('Download failed: $e');
    }
  }

  String _extractFilename(String url, {String? mediaType}) {
    String decodedUrl = Uri.decodeFull(url);
    String filename = decodedUrl.split('/').last.split('?').first;
    if (mediaType != null) {
      switch (mediaType) {
        case 'audio/mpeg':
          filename += '.mp3';
          break;
        case 'audio/mp4':
          filename += '.m4a';
          break;
        case 'video/mp4':
          filename += '.mp4';
          break;
        case 'image/jpeg':
        case 'image/png':
        case 'image/gif':
          filename += '.jpg';
          break;
        default:
          break;
      }
    } else {
      if (url.contains('images')) {
        filename += '.jpg';
      }
    }

    return filename;
  }

Future<Directory?> _getDirectory() async {
  if (Platform.isAndroid || Platform.isIOS) {
    // Use the application documents directory for Android and iOS
    return await getApplicationDocumentsDirectory();
  } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    // For desktop platforms, we can use getDownloadsDirectory() or application documents
    try {
      // Check if a method for getting downloads directory exists for the platform
      // For Windows/Linux/macOS, this may not exist, so fallback to applicationDocumentsDirectory
      return await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    } catch (e) {
      // Fallback if getDownloadsDirectory doesn't work
      print('Error getting downloads directory, falling back to applicationDocumentsDirectory: $e');
      return await getApplicationDocumentsDirectory();
    }
  }
  return null;
}

  final Map<int, List<String>> _mediaPaths = {};

  void _startDownloadingForCampaign() async {
    if (_state == MqttState.downloading) {
      print("Downloads are already in progress.");
      return;
    }

    _downloadCount =
        _campaignModel!.data.zones.expand((zone) => zone.mediaItems).length;

    print("Total files to download: $_downloadCount");

    if (_downloadCount > 0) {
      _state = MqttState.downloading;
      notifyListeners();
    } else {
      _state = MqttState.noContent;
      notifyListeners();
      return;
    }

    int completedDownloads = 0;
    _overallProgress = 0.0;

    for (var zone in _campaignModel!.data.zones) {
      _mediaPaths[zone.id] = [];

      for (var media in zone.mediaItems) {
        String mediaUrl = media.mediaUrl;
        print("Starting download check for Media URL: $mediaUrl");

        String filename = _extractFilename(mediaUrl);
        print('Extracted filename: $filename');

        Directory? directory = await _getDirectory();
        if (directory == null) {
          print('Unable to determine directory');
          throw Exception('Unable to determine directory');
        }
        print('Download directory: ${directory.path}');

        String filePath = '${directory.path}/$filename';

        bool fileExists = await File(filePath).exists();
        if (fileExists) {
          print('File already exists: $filePath');
          _mediaPaths[zone.id]!.add(filePath);
          _updateMediaModelForCampaign();
          completedDownloads++;
          _overallProgress = completedDownloads / _downloadCount;
          print(
              'Overall progress: ${(_overallProgress * 100).toStringAsFixed(2)}%');
          notifyListeners();
        } else {
          await downloadFileForCampaign(mediaUrl, zone.id).then((_) {
            _mediaPaths[zone.id]!.add(filePath);
            completedDownloads++;
            _overallProgress = completedDownloads / _downloadCount;
            print(
                'Overall progress: ${(_overallProgress * 100).toStringAsFixed(2)}%');
            notifyListeners();
          }).catchError((error) {
            print("Error downloading file: $error");
            _state = MqttState.failure;
            notifyListeners();
          });
        }

        if (completedDownloads == _downloadCount) {
          print("All files processed.");
          _state = MqttState.campaignScreen;
          notifyListeners();
        }
      }
    }
  }

  void _updateMediaModelForCampaign() {
    if (_campaignModel != null) {
      for (var zone in _campaignModel!.data.zones) {
        if (_mediaPaths.containsKey(zone.id)) {
          List<String> zoneMediaPaths = _mediaPaths[zone.id]!;
          for (int i = 0;
              i < zone.mediaItems.length && i < zoneMediaPaths.length;
              i++) {
            zone.mediaItems[i].mediaUrl = zoneMediaPaths[i];
          }
        }
      }
    }
  }

Future<void> requestStoragePermission() async {
  var status = await Permission.storage.status;
  if (!status.isGranted) {
    var result = await Permission.storage.request();
    if (result.isGranted) {
      print('Storage permission granted');
    } else {
      print('Storage permission denied');
      throw Exception('Storage permission not granted');
    }
  }

  // For Android 11 and above
  if (Platform.isAndroid && await Permission.manageExternalStorage.isGranted == false) {
    var result = await Permission.manageExternalStorage.request();
    if (result.isGranted) {
      print('External storage management permission granted');
    } else {
      print('External storage management permission denied');
      throw Exception('External storage management permission not granted');
    }
  }
}

  Future<void> downloadFileForCampaign(String url, int zoneId) async {
    // if (Platform.isAndroid) {
    //   print('Requesting storage permission...');
    //   var status = await Permission.storage.request();
    //   if (!status.isGranted) {
    //     print('Storage permission denied $status');
    //     throw Exception('Storage permission not granted');
    //   }
    //   print('Storage permission granted');
    // }

    try {
      String filename = _extractFilename(url);
      Directory? directory = await _getDirectory();
      if (directory == null) {
        print('Unable to determine directory');
        throw Exception('Unable to determine directory');
      }

      String filePath = '${directory.path}/$filename';

      Dio dio = Dio();
      print('Starting download from URL: $url to $filePath');
      await dio.download(
        url,
        filePath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            double progress = received / total;
            print('Download progress: ${(progress * 100).toStringAsFixed(2)}%');
          }
        },
      );

      _mediaPaths[zoneId]?.add(filePath);
      _updateMediaModelForCampaign();

      print('File downloaded to: $filePath');
    } catch (e) {
      print('Download failed: $e');
      throw Exception('Download failed: $e');
    }
  }

  Future<void> _checkPairingStatus() async {
    Map<String, dynamic> requestBody;

    if (Platform.isAndroid) {
      requestBody = {
        "platform": "android",
        "macAddress": [
          {"mac": macAddresses['wlan0'] ?? "123123", "interface": "wlan0"},
          {"mac": macAddresses['eth0'] ?? "123213", "interface": "eth0"}
        ]
      };
    } else if (Platform.isIOS || Platform.isMacOS) {
      final uuid = Platform.isIOS
          ? await getDeviceIdentifiers()
          : (await getDeviceIdentifiersForMac())?["uuid"];

      requestBody = {"platform": "ios", "uuid": uuid ?? "unknown"};
      print(requestBody);
    } else if (Platform.isWindows) {
      requestBody = {"platform": "windows", "uuid": await getDeviceID()};
      print("windows$requestBody");
    } else if (Platform.isLinux) {
      requestBody = {"platform": "linux", "uuid": await getDeviceIDForLinux()};
      print("windows$requestBody");
    } else {
      debugPrint("Unsupported platform");

      return;
    }

    debugPrint("Request body: $requestBody");

    try {
      final response = await ApiRepository().postData(
        "3002/player/connection/",
        requestBody,
        null,
      );
      final jsonResponse = jsonEncode(response);

      SharedPreferences prefs = await SharedPreferences.getInstance();
      bool isSaved = await prefs.setString('apiResponse', jsonResponse);
      print("check status ::::$isSaved");

      _topic = response["player_code"];

      globleTopic = _topic;
      subsibeMessage(topic);
      await prefs.setString('deviceInfoMap', jsonEncode(deviceInfoMap));
      publishMessage(globleTopic, jsonEncode(deviceInfoMap));

      if (response["paired"] == false) {
        _state = MqttState.pairedScreen;
      } else if (response["paired"] == true) {
        _state = MqttState.noContent;
      } else {
        _state = MqttState.failure;
      }
      notifyListeners();
    } catch (error) {
      _state = MqttState.failure;
      debugPrint("Error: $error");
    }

    notifyListeners();
  }

  void subsibeMessage(String topic) {
    _mqttClientService.subscribe(topic);
  }

  void publishMessage(String topic, String message) {
    _mqttClientService.publish(topic, message);
  }

  void _handleIncomingMessage(String message) async {
    print('Received message in ViewModel: $message');
    final jsonObj = jsonDecode(message);
    print('Saving JSON Object: $jsonObj');
    if (jsonObj["action"] == "publish_playlist" ||
        jsonObj["action"] == "publish_campaign") {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      bool isSaved = await prefs.setString('jsonObj', jsonEncode(jsonObj));

      if (isSaved) {
        print('Data successfully saved to SharedPreferences');
      } else {
        print('Failed to save data to SharedPreferences');
      }
    }
    print(jsonObj["action"]);
    if (jsonObj["action"] == "action_reboot") {
      print("action rebooot");
      var data = {"success": true};
      publishMessage(globleTopic, jsonEncode(data));

      if (Platform.isMacOS) {
        deviceSettings.rebootDeviceForMacOS();
      } else if (Platform.isAndroid) {
        print("i am here for andorind");
        deviceSettings.rebootDeviceForAndroid();
      } else if (Platform.isWindows) {
        deviceSettings.rebootDeviceForWindows();
      } else if (Platform.isLinux) {
        deviceSettings.rebootDeviceForLinux();
      }
    } else if (jsonObj["action"] == "action_setup_player") {
      print("action mute${jsonObj["settings"]["mute_audio"]}");
      if (jsonObj["settings"]["mute_audio"] == true) {
        if (Platform.isMacOS) {
          deviceSettings.muteVolumeForMac();
        } else if (Platform.isAndroid) {
          print("i am here for andorind");
          deviceSettings.muteVolumeForAndroid();
        } else if (Platform.isWindows) {
          deviceSettings.muteVolumeForWindows();
        } else if (Platform.isLinux) {
          deviceSettings.muteVolumeForLinux();
        }
      } else if (jsonObj["settings"]["mute_audio"] == false) {
        if (Platform.isMacOS) {
          deviceSettings.unmuteVolumeForMac();
        } else if (Platform.isAndroid) {
          print("i am here for andorind");
          deviceSettings.unmuteVolumeForAndroid();
        } else if (Platform.isWindows) {
          deviceSettings.unmuteVolumeForWindows();
        } else if (Platform.isLinux) {
          deviceSettings.unmuteVolumeForLinux();
        }
      } else if (jsonObj["settings"]["brightness"]['value'] != null) {
        if (Platform.isMacOS) {
          print("No brightness For Mac");
          deviceSettings.unmuteVolumeForMac();
        } else if (Platform.isAndroid) {
          print("i am here for andorind");
          var value = jsonObj["settings"]["brightness"]['value'];
          deviceSettings.setAppBrightnessForAndroid(value);
        } else if (Platform.isWindows) {
          var res = jsonObj["settings"]["brightness"]['value'];
          deviceSettings.adjustBrightnessForWindows(res);
        } else if (Platform.isLinux) {
          var res = jsonObj["settings"]["brightness"]['value'];
          deviceSettings.changeBrightnessForLinux(res);
        }
      }
      var data = {"success": true};
      publishMessage(globleTopic, jsonEncode(data));
    } else if (jsonObj["action"] == "publish_playlist") {
      print("i am in actionPlaylist${jsonObj["data"]["playlist"]["media"]}");
      _playListModel = playListModelFromJson(jsonEncode(jsonObj));

      print("model data ${_playListModel!.data.playlist.media}");
      print(_mediaList);
      for (var media in _playListModel!.data.playlist.media!) {
        print("Media URL: $media");

        _startDownloading();
      }
    } else if (jsonObj["action"] == "publish_campaign") {
      _campaignModel = campaignModelFromJson(jsonEncode(jsonObj));
      print("model data ${_campaignModel!.data.zones}");
      print(_mediaList);
      for (var media in _campaignModel!.data.zones) {
        print("Media URL: $media");
        _startDownloadingForCampaign();
      }
    } else if (jsonObj["action"] == "remove_playlist") {
      debugPrint("remove playlist and update screen");
      SharedPreferences prefs = await SharedPreferences.getInstance();
      prefs.clear();
      await _checkPairingStatus();
    } else if (jsonObj["action"] == "remove_compaign") {
      debugPrint("remove playlist and update screen");
      SharedPreferences prefs = await SharedPreferences.getInstance();
      prefs.clear();
      await _checkPairingStatus();
    }
  }

  void _updateMessage() {
    notifyListeners();
  }

  Future<void> launchUrl(String url) async {
    if (await canLaunch(url)) {
      await launch(url);
    } else {
      throw 'Could not launch $url';
    }
  }
}
