import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:battery_plus/battery_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_phoenix/flutter_phoenix.dart';
import 'package:geolocator/geolocator.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_info2/system_info2.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:digital_signage/models/ad_proof_of_play_model.dart';
import 'package:digital_signage/models/compaign_model.dart';
import 'package:digital_signage/models/intractivity_model.dart'
    hide MediaItem, Settings;
import 'package:digital_signage/models/play_list_model.dart';
import 'package:digital_signage/utils/globle_variable.dart';
import 'package:digital_signage/view_models/system_apply_settings_vm.dart';

import '../data/api_repository/api_repository.dart';
import '../services/mqtt_client_service.dart';
import '../utils/constants.dart';

// #region agent log
void _mqttAgentDebugLog(
  String location,
  String message,
  Map<String, dynamic> data,
  String hypothesisId, {
  String runId = 'webapp-solo-fix',
}) {
  try {
    final payload = jsonEncode({
      'sessionId': '25797a',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'location': location,
      'message': message,
      'data': data,
      'hypothesisId': hypothesisId,
      'runId': runId,
    });
    File('/tmp/debug-25797a.log')
        .writeAsStringSync('$payload\n', mode: FileMode.append);
  } catch (_) {}
}
// #endregion

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
  String get playerCode => _topic;

  PlayListModel? _playListModel;

  PlayListModel? get playListModel => _playListModel;

  CampaignModel? _campaignModel;

  CampaignModel? get campaignModel => _campaignModel;

  InteractivityModel? _interactivityModel;

  InteractivityModel? get interactivityModel => _interactivityModel;

  Map<String, String?> macAddresses = {
    'wlan0': null,
    'eth0': null,
  };
  Map<String, dynamic> storedJsonObj = {};
  Map<String, dynamic>? _storedApiResponse;
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

  bool? storeState;
  Future<void> getStoredState() async {
    final prefs = await SharedPreferences.getInstance();

    // Retrieve the 'storeState' value
    storeState = prefs.getBool('storeState');

    if (storeState != null) {
      debugPrint("Stored State: $storeState");
      // Use the value as needed
    } else {
      debugPrint("No 'storeState' value found.");
    }
  }

  Future<Map<String, dynamic>?> retrieveStoredResponse() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? jsonString = prefs.getString('apiResponse');

    if (jsonString != null) {
      final jsonResponse = jsonDecode(jsonString) as Map<String, dynamic>;
      print('Retrieved stored response: $jsonResponse');
      _topic = jsonResponse["player_code"] ?? "";
      debugPrint("This is the response from the$topic API: $jsonResponse");
      if (_topic.isNotEmpty) {
        globleTopic = _topic;
      }
      _storedApiResponse = jsonResponse;
      return jsonResponse;
    } else {
      print('No stored response found.');
      return null;
    }
  }

  Future<void> loadDeviceInfoFromSharedPreferences() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? jsonString = prefs.getString('deviceInfoMap');
    await prefs.remove('deviceInfoMap');
    if (jsonString != null) {
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

  Future<void> captureAndSendScreenshot(String topic) async {
    try {
      RenderRepaintBoundary boundary = boundaryKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;

      if (boundary.debugNeedsPaint) {
        debugPrint("Widget not rendered yet. Waiting for rendering...");
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final image =
          await boundary.toImage(pixelRatio: 0.5); // Reduce pixel ratio

      final ByteData? byteData =
          await image.toByteData(format: ImageByteFormat.png);

      if (byteData != null) {
        final Uint8List imageBytes = byteData.buffer.asUint8List();
        debugPrint("Original image size: ${imageBytes.length}");

        // Compress the image further (not supported on Linux — skip compression)
        final Uint8List compressedImageBytes;
        if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
          compressedImageBytes = await _compressImage(imageBytes);
        } else {
          compressedImageBytes = imageBytes;
        }
        debugPrint("Compressed image size: ${compressedImageBytes.length}");

        // Convert to Base64 string
        final base64String = base64Encode(compressedImageBytes);

        // Publish the Base64-encoded string
        Map<String, dynamic> sendLog = {
          "action": "screenShot",
          "name": "screenshot",
          "type": "screenShot",
          "dateTime": DateTime.now()
              .toIso8601String(), // Current date and time in ISO 8601 format
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
        _mqttClientService.publishMessage(topic, utf8.encode(base64String));
      } else {
        debugPrint("Failed to capture screenshot: ByteData is null.");
      }
    } catch (error) {
      debugPrint("Error capturing or sending screenshot: $error");
    }
  }

  Future<Uint8List> _compressImage(Uint8List imageBytes) async {
    // Compress the image further by lowering quality and size
    final compressedBytes = await FlutterImageCompress.compressWithList(
      imageBytes,
      minWidth: 400,
      minHeight: 300,
      quality: 5,
      format: CompressFormat.jpeg,
    );
    return compressedBytes;
  }

  // Monitor connectivity changes and reinitialize MQTT on connection recovery
  Future<void> _monitorConnectivity() async {
    await _loadStoredJsonObj();
    await getStoredState();
    await retrieveStoredResponse();
    await loadDeviceInfoFromSharedPreferences();

    if (await InternetConnectionChecker().hasConnection) {
      await _handleConnectivityChange(true);
    }

    InternetConnectionChecker().onStatusChange.listen((status) async {
      await _handleConnectivityChange(
        status == InternetConnectionStatus.connected,
      );
    });
  }

  Future<void> _handleConnectivityChange(bool hasConnection) async {
    if (hasConnection) {
      print("this is data $storedJsonObj");

      if (storedJsonObj["action"] == "publish_playlist") {
        await _mqttClientService.connect();

        if (_topic.isNotEmpty) {
          subsibeMessage(_topic);
        }
        if (globleTopic.isNotEmpty) {
          publishMessage(globleTopic, jsonEncode(deviceInfoMap));
        }
        _playListModel = playListModelFromJson(jsonEncode(storedJsonObj));

        for (var playlist in _playListModel!.data.playlist) {
          if (playlist.media != null && playlist.media!.isNotEmpty) {
            for (var media in playlist.media!) {
              print("Media URL: ${media.mediaUrl}");
              _startDownloadingForPlaylist();
            }
          }
        }
      } else if (storedJsonObj["action"] == "publish_campaign") {
        await _mqttClientService.connect();

        if (_topic.isNotEmpty) {
          subsibeMessage(_topic);
        }
        if (globleTopic.isNotEmpty) {
          publishMessage(globleTopic, jsonEncode(deviceInfoMap));
        }
        _campaignModel = normalizeCampaignResponse(
          campaignModelFromJson(jsonEncode(storedJsonObj)),
          storedJsonObj,
        );
        _selectCompositionCampaignIndexIfPresent();

        print(_mediaList);
        for (var campaign in _campaignModel?.data?.playerCampaigns ?? []) {
          for (var zone in campaign.zones ?? []) {
            for (var media in zone.mediaItems ?? []) {
              print("Media URL: ${media.mediaUrl}");
              _startDownloadingForCampaign();
            }
          }
        }
      } else if (_topic.isNotEmpty) {
        await _restoreSessionFromStorage();
      } else {
        print("elssssssssssssssssssssse caseeeeeee}");
        await _mqttConnection();
      }
    } else {
      if (storedJsonObj["action"] == "publish_playlist") {
        _playListModel = playListModelFromJson(jsonEncode(storedJsonObj));
        print(_mediaList);
        for (var playlist in _playListModel!.data.playlist) {
          if (playlist.media != null && playlist.media!.isNotEmpty) {
            for (var media in playlist.media!) {
              print("Media URL: ${media.mediaUrl}");
              _startDownloadingForPlaylist();
            }
          }
        }
      } else if (storedJsonObj["action"] == "publish_campaign") {
        _campaignModel = normalizeCampaignResponse(
          campaignModelFromJson(jsonEncode(storedJsonObj)),
          storedJsonObj,
        );
        _selectCompositionCampaignIndexIfPresent();

        for (var campaign in _campaignModel?.data?.playerCampaigns ?? []) {
          for (var zone in campaign.zones ?? []) {
            for (var media in zone.mediaItems ?? []) {
              print("Media URL: ${media.mediaUrl}");
              _startDownloadingForCampaign();
            }
          }
        }
      } else if (_topic.isNotEmpty && storeState == false) {
        _state = MqttState.pairedScreen;
        notifyListeners();
      } else {
        _state = MqttState.noInternet;
        notifyListeners();
      }
    }
  }

  Future<void> _restoreSessionFromStorage() async {
    await _checkPairingStatus(refresh: true);
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
      final systemInfo = await _collectLinuxSystemInfo();
      _applyLinuxSystemInfo(systemInfo);
      systemInfo.forEach((key, value) {
        print('$key: $value');
      });
    } catch (e) {
      print('Linux system info collection failed: $e');
    }

    _fetchCurrentLocation();
    if (_topic.isEmpty) {
      await _checkPairingStatus();
    } else {
      await _restoreSessionFromStorage();
    }
  }

  Future<String> _runLinuxShell(String command) async {
    final result = await Process.run('bash', ['-c', command]);
    if (result.exitCode != 0) {
      return '';
    }
    return result.stdout.toString().trim();
  }

  Future<Map<String, String>> _collectLinuxSystemInfo() async {
    final machineId = await getDeviceIDForLinux();
    final macAddress = await _runLinuxShell(
      "ip addr show | grep 'link/ether' | awk '{print \$2}' | head -n 1",
    );
    final osVersion = await _runLinuxShell('uname -r');
    final cpuInfo = await _runLinuxShell(
      "lscpu | grep 'Model name' | awk -F: '{print \$2}' | xargs",
    );
    final cpuArchitecture = await _runLinuxShell('uname -m');
    final availableMemory = await _runLinuxShell(
      "free -m | grep 'Mem:' | awk '{print \$7}'",
    );
    final networkAdapters = await _runLinuxShell(
      "ip link show | awk -F: '/^[0-9]+:/{print \$2}' | xargs",
    );
    final timeZone = await _runLinuxShell(
      "timedatectl 2>/dev/null | grep 'Time zone' | awk '{print \$3}'",
    );
    final deviceName = await _runLinuxShell('hostname');
    final installedRam = await _runLinuxShell(
      "free -m | grep 'Mem:' | awk '{print \$2}'",
    );
    final diskCapacity = await _runLinuxShell(
      "df -h --total 2>/dev/null | grep 'total' | awk '{print \$2}'",
    );

    return {
      'MachineId': machineId,
      'MacAddress': macAddress,
      'OSVersion': osVersion,
      'CPUInfo': cpuInfo,
      'CPUArchitecture': cpuArchitecture,
      'AvailableMemory': availableMemory.isEmpty ? '' : '$availableMemory MB',
      'NetworkAdapters': networkAdapters,
      'TimeZone': timeZone,
      'DeviceName': deviceName,
      'InstalledRAM': installedRam.isEmpty ? '' : '$installedRam MB',
      'DiskCapacity': diskCapacity,
    };
  }

  void _applyLinuxSystemInfo(Map<String, String> systemInfo) {
    final macAddress = systemInfo['MacAddress'] ?? '';
    final machineId = systemInfo['MachineId'] ?? '';

    devicesinfo['sender'] = 'Linux';
    devicesinfo['time_zone'] = systemInfo['TimeZone'] ?? '';
    devicesinfo['mac_address']['platform'] = 'Linux';
    devicesinfo['mac_address']['macAddress'][0]['interface'] = 'wlan0';
    devicesinfo['mac_address']['macAddress'][0]['mac'] =
        macAddress.isNotEmpty ? macAddress : machineId;
    devicesinfo['ram_info'] = systemInfo['InstalledRAM'] ?? '';
    devicesinfo['hardware_details']['model'] =
        systemInfo['DeviceName'] ?? 'Linux';
    devicesinfo['hardware_details']['device_id'] =
        machineId.isNotEmpty ? machineId : macAddress;
    devicesinfo['storage_info']['total_storage'] =
        systemInfo['DiskCapacity'] ?? '';
    devicesinfo['hardware_details']['ram'] = systemInfo['InstalledRAM'] ?? '';
    devicesinfo['cpu_information']['cpu_architecture'] =
        systemInfo['CPUArchitecture'] ?? '';
    devicesinfo['cpu_information']['processor'] = systemInfo['CPUInfo'] ?? '';
    devicesinfo['android_version'] = systemInfo['OSVersion'] ?? '';
  }

  Future<String> getDeviceIDForLinux() async {
    for (final path in ['/etc/machine-id', '/var/lib/dbus/machine-id']) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final id = (await file.readAsString()).trim();
          if (id.isNotEmpty) {
            return id;
          }
        }
      } catch (e) {
        print('Failed to read Linux machine id from $path: $e');
      }
    }

    final hostname = await _runLinuxShell('hostname');
    if (hostname.isNotEmpty) {
      return hostname;
    }

    return 'linux-${DateTime.now().millisecondsSinceEpoch}';
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
        print("System Info: $systemInfo");
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
      if (_topic.isNotEmpty) {
        await _restoreSessionFromStorage();
        return;
      }
      await _mqttClientService.connect();
      _state = MqttState.connectionScreen;
      notifyListeners();
      await _checkPairingStatus();
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
  int _completedDownloadCount = 0;
  double _currentFileProgress = 0.0;
  DateTime? _lastProgressNotify;

  int get downloadCount => _downloadCount;
  int get completedDownloadCount => _completedDownloadCount;
  double get overallProgress => _overallProgress;

  final Map<String, List<String>> _mediaPath = {};
  Map<String, List<String>> get mediaPath => _mediaPath;

  void _startDownloadingForPlaylist() async {
    if (_state == MqttState.downloading) {
      print("Downloads are already in progress.");
      return;
    }

    _downloadCount = _playListModel!.data.playlist.fold(
      0,
      (count, playlist) => count + (playlist.media?.length ?? 0),
    );

    Map<String, dynamic> sendLog = {
      "action": "player_logs",
      "log": "Download Playlist",
      "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      "type": "info",
      "date_time": DateTime.now().toIso8601String(),
    };
    _mqttClientService.publish(topic, jsonEncode(sendLog));
    print("Total media files to download: $_downloadCount");

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
    _completedDownloadCount = 0;
    _currentFileProgress = 0.0;

    for (var playlist in _playListModel!.data.playlist) {
      _mediaPath[playlist.id] = [];

      for (var media in playlist.media!) {
        String mediaUrl = media.mediaUrl;

        // For web-based media types, do NOT download; keep remote URL so they load in WebView.
        final mediaType = (media.mediaType).toLowerCase();
        if (mediaType == 'web_app_instance' || mediaType == 'text/html') {
          print(
              'Skipping download for web media type: $mediaType, url: $mediaUrl');
          completedDownloads++;
          _updateOverallProgress(completedDownloads);
          continue;
        }
        String filename = _extractFilename(mediaUrl);
        Directory? directory = await _getDirectory();
        if (directory == null) {
          print('Unable to determine directory');
          throw Exception('Unable to determine directory');
        }

        String filePath = '${directory.path}/$filename';
        bool fileExists = await File(filePath).exists();

        if (fileExists) {
          _mediaPath[playlist.id]!.add(filePath);
          completedDownloads++;
          _updateOverallProgress(completedDownloads);
        } else {
          try {
            await downloadFileForPlaylist(mediaUrl, playlist.id);
            _mediaPath[playlist.id]!.add(filePath);
            completedDownloads++;
            _updateOverallProgress(completedDownloads);
          } catch (error) {
            print("Error downloading file: $error");
            Map<String, dynamic> errorLog = {
              "action": "player_logs",
              "log": "Download Playlist",
              "name":
                  "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
              "type": "error",
              "date_time": DateTime.now().toIso8601String(),
            };

            _mqttClientService.publish(topic, jsonEncode(errorLog));
            _state = MqttState.failure;
            notifyListeners();
          }
        }
      }
    }

    if (completedDownloads == _downloadCount) {
      print("All media files for all playlists have been downloaded.");
      _updateMediaModelForPlaylist(); // Update model with local file paths
      _state = MqttState.playlistScreen;
      notifyListeners();
    }
  }

  void _updateOverallProgress(int completedDownloads) {
    _completedDownloadCount = completedDownloads;
    _currentFileProgress = 0.0;
    _overallProgress =
        _downloadCount > 0 ? completedDownloads / _downloadCount : 0.0;
    print(
        'Overall progress: ${(_overallProgress * 100).toStringAsFixed(2)}% ($completedDownloads/$_downloadCount)');
    notifyListeners();
  }

  void _updateCurrentFileProgress(int received, int total) {
    if (total <= 0) return;
    _currentFileProgress = received / total;
    _overallProgress = _downloadCount > 0
        ? (_completedDownloadCount + _currentFileProgress) / _downloadCount
        : 0.0;
    final now = DateTime.now();
    if (_lastProgressNotify == null ||
        now.difference(_lastProgressNotify!).inMilliseconds >= 100) {
      _lastProgressNotify = now;
      notifyListeners();
    }
  }

  void _updateMediaModelForPlaylist() {
    if (_playListModel != null) {
      for (var playlist in _playListModel!.data.playlist) {
        if (_mediaPath.containsKey(playlist.id)) {
          List<String> playlistMediaPaths = _mediaPath[playlist.id]!;
          for (int i = 0; i < playlist.media!.length; i++) {
            if (i < playlistMediaPaths.length) {
              String localPath = playlistMediaPaths[i];
              if (File(localPath).existsSync()) {
                playlist.media![i].mediaUrl = localPath; // Update to local path
              } else {
                print("File not found: $localPath");
              }
            }
          }
        }
      }
      _playListModel!.data.playlist.forEach((playlist) {
        playlist.media!.forEach((media) {
          print("Updated Media URL: ${media.mediaUrl}");
        });
      });
      notifyListeners();
    }
  }

  Future<void> downloadFileForPlaylist(String url, String playlistId,
      {int retries = 3}) async {
    int attempt = 0;
    while (attempt < retries) {
      try {
        attempt++;
        String filename = _extractFilename(url);
        Directory? directory = await _getDirectory();
        if (directory == null) {
          print('Unable to determine directory');
          throw Exception('Unable to determine directory');
        }

        String filePath = '${directory.path}/$filename';
        print('Downloading from URL: $url to $filePath');

        _currentFileProgress = 0.0;
        notifyListeners();

        Dio dio = Dio();
        await dio.download(
          url,
          filePath,
          onReceiveProgress: (received, total) {
            if (total != -1 && total > 0) {
              _updateCurrentFileProgress(received, total);
            }
          },
        );

        _mediaPath[playlistId]?.add(filePath);
        print('Download complete: $filePath');
        return; // Exit on successful download
      } catch (e) {
        print('Download attempt $attempt failed: $e');
        if (attempt >= retries) {
          print('Maximum retry attempts reached. Download failed.');
          throw Exception('Download failed after $retries attempts: $e');
        } else {
          print('Retrying download...');
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }
  }

  void _startDownloadingForCampaign() async {
    if (_state == MqttState.downloading) {
      print("Downloads are already in progress.");
      return;
    }

    Map<String, dynamic> sendLog = {
      "action": "player_logs",
      "log": "Download Campaign",
      "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      "type": "info",
      "date_time": DateTime.now().toIso8601String(),
    };

    _mqttClientService.publish(topic, jsonEncode(sendLog));

    // Collect ALL downloadable media items (including nested sub-zones inside campaign media).
    final downloadTargets = _collectCampaignMediaItemsForDownload(
      _campaignModel?.data?.playerCampaigns ?? const [],
    );
    _downloadCount = downloadTargets.length;

    print("Total files to download: $_downloadCount");

    final campaigns = _campaignModel?.data?.playerCampaigns ?? const [];
    final hasPlayableCampaignMedia = _campaignHasPlayableMediaItems(campaigns);

    // #region agent log
    _mqttAgentDebugLog(
      'mqtt_view_model.dart:_startDownloadingForCampaign',
      'download target summary',
      {
        'downloadCount': _downloadCount,
        'campaignCount': campaigns.length,
        'hasPlayableCampaignMedia': hasPlayableCampaignMedia,
      },
      'C',
    );
    // #endregion

    if (_downloadCount > 0) {
      _state = MqttState.downloading;
      notifyListeners();
    } else if (hasPlayableCampaignMedia) {
      print(
          'No downloadable files; showing campaign with web/inline media '
          '(${campaigns.length} campaign(s)).');
      _selectCompositionCampaignIndexIfPresent();
      _state = MqttState.campaignScreen;
      notifyListeners();
      return;
    } else {
      _state = MqttState.noContent;
      notifyListeners();
      return;
    }

    int completedDownloads = 0;
    _overallProgress = 0.0;
    _completedDownloadCount = 0;
    _currentFileProgress = 0.0;

    for (final media in downloadTargets) {
      String? originalUrl;
      if (media.mediaType?.toLowerCase() == 'sticker') {
        originalUrl = media.settings?.remoteSrc ?? media.mediaUrl;
      } else {
        originalUrl = media.mediaUrl;
      }

      if (originalUrl == null || originalUrl.isEmpty) {
        completedDownloads++;
        _overallProgress = completedDownloads / _downloadCount;
        notifyListeners();
        continue;
      }

      _completedDownloadCount = completedDownloads;
      _currentFileProgress = 0.0;
      notifyListeners();

      try {
        final localPath = await _ensureLocalMediaUrl(
          originalUrl,
          onProgress: _updateCurrentFileProgress,
        );
        // Update the appropriate URL field
        if (media.mediaType?.toLowerCase() == 'sticker') {
          // Stickers: always store local path in settings.remoteSrc so the UI uses it at render time
          media.settings ??= Settings();
          media.settings!.remoteSrc = localPath;
          media.mediaUrl = localPath; // keep mediaUrl in sync for fallback
        } else if (media.isAd || idLooksLikeAdSlot(media.id)) {
          media.settings ??= Settings();
          if (originalUrl.startsWith('http')) {
            media.settings!.creativeUrl = originalUrl;
          }
          media.mediaUrl = localPath;
        } else {
          media.mediaUrl = localPath;
        }
        completedDownloads++;
        _overallProgress = completedDownloads / _downloadCount;
        print(
            'Overall progress: ${(_overallProgress * 100).toStringAsFixed(2)}%');
        notifyListeners();
      } catch (error) {
        print("Error downloading file: $error");
        Map<String, dynamic> sendLog = {
          "action": "player_logs",
          "log": "Download Campaign",
          "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
          "type": "error",
          "date_time": DateTime.now().toIso8601String(),
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
        // Keep original URL so campaign view can still try to load from network.
        // Don't set failure – continue and show campaign with partial downloads.
        completedDownloads++;
        _overallProgress = completedDownloads / _downloadCount;
        notifyListeners();
      }
    }

    print("All files processed.");
    _state = MqttState.campaignScreen;
    notifyListeners();
  }

  bool _isNestedCampaignMediaItem(MediaItem media) {
    final type = (media.mediaType ?? '').toLowerCase();
    return type == 'campaign' ||
        type == 'composition' ||
        (media.zones != null && media.zones!.isNotEmpty);
  }

  List<MediaItem> _collectCampaignMediaItemsForDownload(
      List<Campaign> campaigns) {
    final result = <MediaItem>[];

    void visitZones(List<CampaignZone> zones) {
      for (final zone in zones) {
        final items = zone.mediaItems ?? const <MediaItem>[];
        for (final media in items) {
          // Skip purely web-based / inline media: keep remote URLs or render in-app.
          final mediaType = (media.mediaType ?? '').toLowerCase();
          if (mediaType == 'web_app_instance' ||
              mediaType == 'text/html' ||
              mediaType == 'text' ||
              mediaType == 'shape') {
            continue;
          }
          if (mediaType == 'content' && mediaItemIsWebAppIframe(media)) {
            continue;
          }
          final rawUrl = media.mediaUrl ?? '';
          if (rawUrl.contains('<svg')) {
            continue;
          }
          if (_isNestedCampaignMediaItem(media)) {
            visitZones(media.zones ?? const <CampaignZone>[]);
            continue;
          }
          // For stickers, prefer remoteSrc; for ads, prefer creative URL
          String? url;
          if (media.isAd || idLooksLikeAdSlot(media.id)) {
            url = media.adCreativeUrl;
          } else if (media.mediaType?.toLowerCase() == 'sticker') {
            url = media.settings?.remoteSrc ?? media.mediaUrl;
          } else {
            url = media.mediaUrl;
          }
          if (url != null && url.isNotEmpty) {
            result.add(media);
          }
        }
      }
    }

    for (final c in campaigns) {
      visitZones(c.zones ?? const <CampaignZone>[]);
    }
    return result;
  }

  bool _campaignHasPlayableMediaItems(List<Campaign> campaigns) {
    for (final campaign in campaigns) {
      if (campaign.isPaused == true) continue;
      final zones = campaign.zones;
      if (zones == null || zones.isEmpty) continue;

      bool zoneHasMedia(List<CampaignZone> zoneList) {
        for (final zone in zoneList) {
          final items = zone.mediaItems;
          if (items != null && items.isNotEmpty) return true;
        }
        return false;
      }

      if (zoneHasMedia(zones)) return true;
    }
    return false;
  }

  Future<String> _ensureLocalMediaUrl(String url,
      {void Function(int received, int total)? onProgress}) async {
    final trimmed = url.trim();

    if (trimmed.startsWith('<svg') ||
        (trimmed.contains('<svg') && trimmed.contains('</svg>'))) {
      return trimmed;
    }

    String fullUrl = trimmed;
    if (trimmed.startsWith('/') &&
        !trimmed.startsWith('http://') &&
        !trimmed.startsWith('https://')) {
      fullUrl = 'https://signagexai.com$trimmed';
      print('Converting relative path to full URL: $trimmed -> $fullUrl');
    }

    if (!fullUrl.startsWith('http://') && !fullUrl.startsWith('https://')) {
      if (fullUrl.startsWith('/Users') ||
          fullUrl.startsWith('/tmp') ||
          fullUrl.startsWith('/var')) {
        return fullUrl;
      }
      // Otherwise, it might be a relative path we couldn't resolve
      return fullUrl;
    }

    final filename = _extractFilename(fullUrl);
    final directory = await _getDirectory();
    if (directory == null) {
      throw Exception('Unable to determine directory');
    }

    final filePath = '${directory.path}/$filename';
    final file = File(filePath);
    final exists = await file.exists();
    if (exists) {
      print('File already exists: $filePath');
      return filePath;
    }

    // Ensure URL is valid for parsing (fix illegal percent encoding).
    String downloadUrl = fullUrl;
    try {
      Uri.parse(fullUrl);
    } catch (_) {
      downloadUrl = fullUrl.replaceAllMapped(
          RegExp(r'%(?![0-9A-Fa-f]{2})'), (_) => '%25');
    }

    final dio = Dio();
    print('Downloading from URL: $downloadUrl to $filePath');
    try {
      await dio.download(
        downloadUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received, total);
        },
      );
      print('Download complete: $filePath');
      return filePath;
    } catch (e) {
      print('Error downloading $downloadUrl: $e');
      // If download fails, return the original URL so widget can try to handle it
      return fullUrl;
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
    if (Platform.isAndroid &&
        await Permission.manageExternalStorage.isGranted == false) {
      var result = await Permission.manageExternalStorage.request();
      if (result.isGranted) {
        print('External storage management permission granted');
      } else {
        print('External storage management permission denied');
        throw Exception('External storage management permission not granted');
      }
    }
  }

  String _extractFilename(String url, {String? mediaType}) {
    String decodedUrl;
    try {
      decodedUrl = Uri.decodeFull(url);
    } catch (_) {
      // URL has invalid percent encoding (e.g. illegal % sequence); use raw path.
      decodedUrl = url;
    }
    String filename = decodedUrl.split('/').last.split('?').first;
    // Sanitize: remove characters that are invalid in URIs or filenames.
    if (filename.isEmpty) {
      filename = 'file_${url.hashCode.abs()}';
    }
    filename = filename.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_');
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

  Future<void> reportAdProofOfPlay(AdProofOfPlayRequest request) async {
    final url = '$baseurl$adCampaignProofOfPlayPath';
    if (playerCode.isEmpty) {
      print('[AdPoP] Skipped: player_code is empty (POST $url)');
      return;
    }
    try {
      final body = request.toJson();
      print('[AdPoP] POST $url');
      print('[AdPoP] Payload: $body');
      final response = await ApiRepository().postData(
        adCampaignProofOfPlayPath,
        body,
        null,
      );
      print('[AdPoP] Response: $response');
      print('[AdPoP] Report sent successfully');
    } catch (e, st) {
      print('[AdPoP] HTTP/network error: $e');
      print('[AdPoP] Stack: $st');
    }
  }

  Future<Directory?> _getDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      // Use the application documents directory for Android and iOS
      return await getApplicationDocumentsDirectory();
    } else if (Platform.isMacOS) {
      // On macOS release (sandbox), use Documents so the video player can read files.
      // Downloads in the container can trigger "permission to view" errors with AVPlayer.
      return await getApplicationDocumentsDirectory();
    } else if (Platform.isWindows || Platform.isLinux) {
      try {
        return await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
      } catch (e) {
        print(
            'Error getting downloads directory, falling back to applicationDocumentsDirectory: $e');
        return await getApplicationDocumentsDirectory();
      }
    }
    return null;
  }

  Future<void> _resetLocalPlayerSession() async {
    _topic = '';
    globleTopic = '';
    storeState = null;
    _storedApiResponse = null;
    storedJsonObj = {};
    _campaignModel = null;
    _playListModel = null;
    _interactivityModel = null;
    _currentIndexOfCapmaign = 0;
  }

  Future<void> _checkPairingStatus({bool refresh = false}) async {
    if (_topic.isNotEmpty && !refresh) {
      debugPrint('Pairing skipped: player_code already set ($_topic)');
      return;
    }

    if (refresh && _topic.isNotEmpty) {
      debugPrint('Refreshing player registration for $_topic');
    }

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
        "player/connection/",
        requestBody,
        null,
      );
      final jsonResponse = jsonEncode(response);

      SharedPreferences prefs = await SharedPreferences.getInstance();
      bool isSaved = await prefs.setString('apiResponse', jsonResponse);
      print("check status ::::$isSaved");

      _storedApiResponse = Map<String, dynamic>.from(response as Map);
      _topic = response["player_code"] ?? "";

      if (_topic.isEmpty) {
        debugPrint("Warning: player_code is empty or null in API response");
        _state = MqttState.failure;
        notifyListeners();
        return;
      }

      globleTopic = _topic;

      // Process pairing status FIRST so state updates even if MQTT ops fail below
      if (response["paired"] == false) {
        print("this is state screeen ${response["paired"]}");
        storeState = false;
        await prefs.setBool('storeState', false);
        _state = MqttState.pairedScreen;
        _startPairingPollingTimer();
      } else if (response["paired"] == true) {
        storeState = true;
        await prefs.setBool('storeState', true);
        _stopPairingPollingTimer();
        if (_state != MqttState.downloading &&
            _state != MqttState.campaignScreen &&
            _state != MqttState.playlistScreen) {
          _state = MqttState.noContent;
        }
      } else {
        _state = MqttState.failure;
      }
      notifyListeners();

      // MQTT ops after state update — failures here don't block pairing state
      try {
        await _mqttClientService.connect();
      } catch (e) {
        debugPrint('MQTT connect during pairing failed: $e');
      }

      try {
        subsibeMessage(_topic);
      } catch (e) {
        debugPrint('Subscribe during pairing failed: $e');
      }
      await prefs.setString('deviceInfoMap', jsonEncode(deviceInfoMap));
      try {
        publishMessage(globleTopic, jsonEncode(deviceInfoMap));
      } catch (e) {
        debugPrint('Publish during pairing failed: $e');
      }

      // Reset retry counter on successful API call
      _pairingRetryCount = 0;
    } catch (error) {
      debugPrint("Error during pairing check: $error");

      _pairingRetryCount++;

      // Check if error is a 500 server error
      final errorString = error.toString();
      final isServerError = errorString.contains('500') ||
          errorString.contains('Error During Communication');

      if (isServerError && _pairingRetryCount >= _maxPairingRetries) {
        debugPrint(
            "Max retries ($_maxPairingRetries) reached for pairing check. Restarting app...");
        _pairingRetryCount = 0; // Reset counter
        // Restart the app to reset the flow
        await Future.delayed(const Duration(seconds: 2));
        await restartApp();
        return;
      }

      // Retry with exponential backoff
      if (_pairingRetryCount < _maxPairingRetries) {
        final delaySeconds = _pairingRetryCount * 2; // 2, 4, 6 seconds
        debugPrint(
            "Retrying pairing check in $delaySeconds seconds (attempt $_pairingRetryCount/$_maxPairingRetries)");
        await Future.delayed(Duration(seconds: delaySeconds));
        // Retry the pairing check
        _state = MqttState.connectionScreen;
        notifyListeners();
        await _checkPairingStatus();
        return;
      }

      // If not a server error or max retries not reached, just show connection screen
      _state = MqttState.connectionScreen;
      debugPrint("Error: $error");
    }

    // Reset retry counter on success
    _pairingRetryCount = 0;
    notifyListeners();
  }

  void subsibeMessage(String topic) {
    if (topic.isEmpty || topic.trim().isEmpty) {
      print('MQTT_LOGS:: Cannot subscribe - topic is empty');
      return;
    }
    _mqttClientService.subscribe(topic);
  }

  void publishMessage(String topic, String message) {
    if (topic.isEmpty || topic.trim().isEmpty) {
      print('MQTT_LOGS:: Cannot publish - topic is empty');
      return;
    }
    _mqttClientService.publish(topic, message);
  }

  Future<void> restartApp() async {
    try {
      await _channel.invokeMethod('com.example/restartApp');
    } on PlatformException catch (e) {
      print("Failed to restart app: ${e.message}");
    }
  }

  String? _msg;
  String? get msg => _msg;
  String? _key;
  String? get key => _key;
  double? tapX;
  double? tapY;

  // Retry counter for pairing status check
  int _pairingRetryCount = 0;
  static const int _maxPairingRetries = 3;

  Timer? _pairingPollingTimer;

  void _startPairingPollingTimer() {
    _pairingPollingTimer?.cancel();
    _pairingPollingTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_state == MqttState.pairedScreen) {
        debugPrint('MQTT_LOGS:: Polling pairing status...');
        await _checkPairingStatus(refresh: true);
      } else {
        _stopPairingPollingTimer();
      }
    });
  }

  void _stopPairingPollingTimer() {
    _pairingPollingTimer?.cancel();
    _pairingPollingTimer = null;
  }

  void setTapPosition(double x, double y) {
    tapX = x;
    tapY = y;
    // if(tapX==_interactivityModel!.data.interactivity[].regionX ||  tapY==_interactivityModel!.data.interactivity[].regionY){
    // print("i am in intractivity by region");

    // }
    notifyListeners();
  }

  void getKey(String keydata) {
    _key = keydata;
    notifyListeners();
    // Check if any key in the interactivity list matches _key (case-insensitive)
    bool keyFound = _interactivityModel?.data.interactivity.any(
            (interactivity) => interactivity.keyPress
                .any((key) => key.toUpperCase() == _key!.toUpperCase())) ??
        false;
    print("this is key data $keydata");
    if (keyFound) {
      print("I am in interactivity by key");
    } else {
      print("Key not found in interactivity");
    }
  }

  void _handleIncomingMessage(String message) async {
    print('Received message in ViewModel: $message');

    print('Received message in store state: $storeState');
    print('i am in recive msgss:');
// await restartApp();
    final jsonObj = jsonDecode(message);

    print('Saving JSON Object: $jsonObj');

    // Check if message has an action field
    if (jsonObj["action"] == null) {
      // Message doesn't have an action field - likely device info or other data
      // Just log it and return, don't process it as a command
      print('MQTT_LOGS:: Received message without action field - ignoring');
      return;
    }

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
      Map<String, dynamic> sendLog = {
        "action": "Action Reboot",
        "name": "Player ${deviceInfo!["hardware_details"]["model"]}",
        "type": "info",
        "dateTime": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
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
      Map<String, dynamic> sendLog = {
        "action": "Action Setup Player",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "dateTime": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      if (storeState != true) {
        await _checkPairingStatus(refresh: true);
      }
      // print("action mute${jsonObj["settings"]?["mute_audio"]}");
      if (jsonObj["settings"] != null &&
          jsonObj["settings"]["mute_audio"] == true) {
        Map<String, dynamic> sendLog = {
          "action": "player_logs",
          "log": "Mute Audio",
          "name": "Player ${deviceInfo!["hardware_details"]["model"]}",
          "type": "info",
          "date_time": DateTime.now().toIso8601String(),
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
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
      } else if (jsonObj["settings"] != null &&
          jsonObj["settings"]["mute_audio"] == false) {
        Map<String, dynamic> sendLog = {
          "action": "player_logs",
          "log": "Unmute Audio",
          "name": "Player $globleTopic}",
          "type": "info",
          "date_time": DateTime.now().toIso8601String(),
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
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
      } else if (jsonObj["settings"] != null &&
          jsonObj["settings"]["brightness"] != null &&
          jsonObj["settings"]["brightness"]['value'] != null) {
        Map<String, dynamic> sendLog = {
          "action": "player_logs",
          "log": "brightness",
          "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
          "type": "info",
          "date_time": DateTime.now().toIso8601String(),
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
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
      } else if (jsonObj["settings"] != null &&
          jsonObj["settings"]["volume"] != null) {
        Map<String, dynamic> sendLog = {
          "action": "player_logs",
          "log": "Volume",
          "name": "Player ${deviceInfo!["hardware_details"]["model"]}",
          "type": "info",
          "date_time": DateTime.now().toIso8601String(),
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
        if (Platform.isMacOS) {
          print("No Volue For Mac");
          var res = jsonObj["settings"]["volume"];
          deviceSettings.setVolumeForMac(res);
        } else if (Platform.isAndroid) {
          print("i am here for andorind");
          var value = jsonObj["settings"]["volume"];
          deviceSettings.setVolumeForAndroid(value);
        } else if (Platform.isWindows) {
          var res = jsonObj["settings"]["volume"];
          deviceSettings.adjustBrightnessForWindows(res);
        } else if (Platform.isLinux) {
          var res = jsonObj["settings"]["brightness"];
          deviceSettings.changeBrightnessForLinux(res);
        }
      }
      var data = {"success": true};
      publishMessage(globleTopic, jsonEncode(data));
    } else if (jsonObj["action"] == "action click") {
      print(" i am in action  click");
    } else if (jsonObj["action"] == "publish_playlist") {
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Publish Playlist",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
// Deserialize the JSON into the model
      // await _checkPairingStatus();
      _playListModel = playListModelFromJson(jsonEncode(jsonObj));
      // Ensure any listening UI updates immediately
      notifyListeners();
      // if (_playListModel!.data.playlist.isEmpty) {
      //   debugPrint("remove playlist and update screen");
      //   Map<String, dynamic> sendLog = {
      //     "action": "player_logs",
      //     "log": "Remove Campaign",
      //     "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      //     "type": "info",
      //     "date_time": DateTime.now().toIso8601String(),
      //   };

      //   _mqttClientService.publish(topic, jsonEncode(sendLog));
      //   SharedPreferences prefs = await SharedPreferences.getInstance();
      //   prefs.clear();
      //   await _checkPairingStatus();
      // }
      print("model data ${_playListModel!.data.playlist}");

      for (var playlist in _playListModel!.data.playlist) {
        // Check if the playlist contains any media
        if (playlist.media != null && playlist.media!.isNotEmpty) {
          for (var media in playlist.media!) {
            print("Media URL: ${media.mediaUrl}");

            // Start downloading for each media item
            _startDownloadingForPlaylist();
          }
        }
      }
    } else if (jsonObj["action"] == "publish_campaign") {
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Publish Campaign",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      _msg = jsonObj["action"];
      _campaignModel = normalizeCampaignResponse(
        campaignModelFromJson(jsonEncode(jsonObj)),
        jsonObj,
      );
      final campaigns = _campaignModel?.data?.playerCampaigns;
      final count = campaigns?.length ?? 0;
      for (var i = 0; i < count; i++) {
        final c = campaigns![i];
        print(
            '[CampaignList] $i: ${c.campaignName} '
            'zones=${c.zones?.length ?? 0} '
            'composition=${c.isCompositionLayout} '
            'alwaysPlay=${c.campaignSchedule?.alwaysPlay}');
      }
      // #region agent log
      _mqttAgentDebugLog(
        'mqtt_view_model.dart:publish_campaign',
        'rotation campaign list',
        {
          'count': count,
          'campaigns': campaigns
                  ?.map(
                    (c) => {
                      'name': c.campaignName,
                      'zones': c.zones?.length ?? 0,
                      'composition': c.isCompositionLayout,
                      'alwaysPlay': c.campaignSchedule?.alwaysPlay,
                    },
                  )
                  .toList() ??
              [],
        },
        'H',
      );
      // #endregion
      // Keep campaign index in bounds when campaign list changes (e.g. single campaign)
      if (count > 0) {
        _selectCompositionCampaignIndexIfPresent();
        if (_currentIndexOfCapmaign >= count) {
          _currentIndexOfCapmaign = 0;
        }
      }
      // Ensure any listening UI updates immediately
      notifyListeners();

      // Optional: soft-restart the Flutter widget tree so the whole UI reloads
      // (useful if some screens are not wired to rebuild correctly).
      //
      // Guarded to avoid restart loops if broker re-sends retained messages.
      try {
        final prefs = await SharedPreferences.getInstance();
        final payload = jsonEncode(jsonObj);
        final prev = prefs.getString('last_publish_campaign_payload');
        if (prev != payload) {
          await prefs.setString('last_publish_campaign_payload', payload);
          final ctx = boundaryKey.currentContext;
          if (ctx != null) {
            Phoenix.rebirth(ctx);
          } else {
            debugPrint('MQTT_LOGS:: Phoenix context not available for restart');
          }
        }
      } catch (e) {
        debugPrint('MQTT_LOGS:: Failed to restart app on publish_campaign: $e');
      }
      // Safely check media URL with proper null/empty checks
      String? mediaUrl = 'N/A';
      try {
        final campaigns = _campaignModel?.data?.playerCampaigns;
        if (campaigns != null && campaigns.isNotEmpty) {
          final zones = campaigns[0].zones;
          if (zones != null && zones.isNotEmpty) {
            final mediaItems = zones[0].mediaItems;
            if (mediaItems != null && mediaItems.isNotEmpty) {
              mediaUrl = mediaItems[0].mediaUrl ?? 'N/A';
            }
          }
        }
      } catch (e) {
        debugPrint('MQTT_LOGS:: Error checking media URL: $e');
        mediaUrl = 'N/A';
      }
      print("checking media on model $mediaUrl");
      // if (_campaignModel!.data.playerCampaigns.isEmpty) {
      //   debugPrint("remove playlist and update screen");
      //   Map<String, dynamic> sendLog = {
      //     "action": "player_logs",
      //     "log": "Remove Campaign",
      //     "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      //     "type": "info",
      //     "date_time": DateTime.now().toIso8601String(),
      //   };

      //   _mqttClientService.publish(topic, jsonEncode(sendLog));
      //   SharedPreferences prefs = await SharedPreferences.getInstance();
      //   prefs.clear();
      //   await _checkPairingStatus();
      // }

      print("i am in ccccccc");

      // await _checkPairingStatus();
      for (var campaign in _campaignModel?.data?.playerCampaigns ?? []) {
        for (var zone in campaign.zones ?? []) {
          for (var media in zone.mediaItems ?? []) {
            print("Media URL: ${media.mediaUrl}");
            _startDownloadingForCampaign();
          }
        }
      }
    } else if (jsonObj["action"] == "publish_interactivity") {
      _interactivityModel = interactivityModelFromJson(jsonEncode(jsonObj));
      print("i am in intractvity");
    } else if (jsonObj["action"] == "remove_playlist") {
      debugPrint("remove playlist and update screen");
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Remove Playlist",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await _resetLocalPlayerSession();

      await _checkPairingStatus();
    } else if (jsonObj["action"] == "action_delete") {
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Action Delete",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      debugPrint("Player deleted from dashboard – resetting local session");
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await _resetLocalPlayerSession();
      await _checkPairingStatus();
      await getStoredState();
    } else if (jsonObj["action"] == "remove_campaign") {
      debugPrint("remove playlist and update screen");
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Remove Campaign",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await _resetLocalPlayerSession();
      await _checkPairingStatus();
    }
    notifyListeners();
  }

  int _currentIndexOfCapmaign = 0;

  void _selectCompositionCampaignIndexIfPresent() {
    final campaigns = _campaignModel?.data?.playerCampaigns;
    if (campaigns == null || campaigns.isEmpty) return;

    if (_currentIndexOfCapmaign >= campaigns.length) {
      _currentIndexOfCapmaign = 0;
    }

    final current = campaigns[_currentIndexOfCapmaign];
    print(
        '[Campaign] Active campaign index $_currentIndexOfCapmaign '
        '(${current.campaignName}, composition=${current.isCompositionLayout}, '
        '${current.zones?.length ?? 0} zones)');

    // #region agent log
    _mqttAgentDebugLog(
      'mqtt_view_model.dart:_selectCompositionCampaignIndexIfPresent',
      'campaign index resolved',
      {
        'index': _currentIndexOfCapmaign,
        'totalCampaigns': campaigns.length,
        'compositionCount':
            campaigns.where((c) => c.isCompositionLayout).length,
        'regularCount':
            campaigns.where((c) => !c.isCompositionLayout).length,
        'campaignName': current.campaignName,
        'isComposition': current.isCompositionLayout,
      },
      'G',
    );
    // #endregion
  }
  Timer? _timerOfCampaign;

  int get currentIndexOfCapmaign => _currentIndexOfCapmaign;

  int get currentDurationOfCampaign {
    final currentCampaign =
        campaignModel?.data?.playerCampaigns?[_currentIndexOfCapmaign];
    if (currentCampaign == null) return 0;

    final campaignSchedule = currentCampaign.campaignSchedule;
    if (campaignSchedule == null) {
      print(
          'Current Index: $_currentIndexOfCapmaign, Duration: 15 seconds, '
          'Always Play: true (default, no schedule)');
      return 15;
    }

    int durationcampagin = 0;

    // Check if the item is in the schedule or should always play
    if ((campaignSchedule.alwaysPlay ?? false) ||
        (campaignSchedule.period != null &&
            campaignSchedule.period!.date != null &&
            campaignSchedule.period!.date!.start != null &&
            campaignSchedule.period!.date!.end != null &&
            _isPlaylistDateInRangeForCampagin(
                DateTime.parse(campaignSchedule.period!.date!.start!),
                DateTime.parse(campaignSchedule.period!.date!.end!)) &&
            _isCurrentDayAllowedForCampain(
              campaignSchedule.period!.days,
              DateTime.now(),
            ) &&
            campaignSchedule.period!.time != null &&
            campaignSchedule.period!.time!.from != null &&
            campaignSchedule.period!.time!.to != null &&
            _isTimeInRangeForCampaign(
              campaignSchedule.period!.time!.from!,
              campaignSchedule.period!.time!.to!,
            ))            ) {
      final durationValue = currentCampaign.campaignSettings?.duration;
      if (durationValue != null) {
        durationcampagin = int.tryParse(durationValue) ?? 0;
      }
      if (durationcampagin <= 0) {
        durationcampagin = 15;
      }
    }

    // Log the state
    print(
        "Current Index: $_currentIndexOfCapmaign, Duration: $durationcampagin seconds, Always Play: ${campaignSchedule.alwaysPlay}");

    // #region agent log
    _mqttAgentDebugLog(
      'mqtt_view_model.dart:currentDurationOfCampaign',
      'resolved campaign duration',
      {
        'campaignIndex': _currentIndexOfCapmaign,
        'durationSeconds': durationcampagin,
        'alwaysPlay': campaignSchedule.alwaysPlay,
        'rawDuration': currentCampaign.campaignSettings?.duration,
      },
      'F',
    );
    // #endregion

    return durationcampagin;
  }

  void startPlaylistTimerForCampaign() {
    _timerOfCampaign?.cancel();

    final duration = currentDurationOfCampaign;
    if (duration <= 0) {
      _updateIndexForCampain();
      print("Campaign not in schedule, skipping timer setup.");
    } else {
      _timerOfCampaign =
          Timer(Duration(seconds: duration), _updateIndexForCampain);
    }
  }

  void publishLogsForPlayList(String name) {
    Map<String, dynamic> sendLog = {
      "action": "Playlist",
      "name": "$name",
      "type": "info",
      "dateTime": DateTime.now().toIso8601String(),
    };

    _mqttClientService.publish(topic, jsonEncode(sendLog));
  }

  void publishLogsForCampaign(String name) {
    Map<String, dynamic> sendLog = {
      "action": "Campaign",
      "name": "$name",
      "type": "info",
      "dateTime": DateTime.now().toIso8601String(),
    };

    _mqttClientService.publish(topic, jsonEncode(sendLog));
  }

  void _updateIndexForCampain() {
    final campaigns = _campaignModel?.data?.playerCampaigns;
    final count = campaigns?.length ?? 0;

    // If all campaigns are unpublished/removed, stop the timer and move to noContent.
    if (count == 0) {
      debugPrint(
          'MQTT_LOGS:: _updateIndexForCampain skipped (no campaigns). Cancelling campaign timer.');
      _timerOfCampaign?.cancel();
      _timerOfCampaign = null;
      _currentIndexOfCapmaign = 0;
      _state = MqttState.noContent;
      notifyListeners();
      return;
    }

    final playableCampaigns = campaigns!;

    // Rotate through every published player campaign (compositions + solos).
    _currentIndexOfCapmaign = (_currentIndexOfCapmaign + 1) % count;

    final nextCampaign = playableCampaigns[_currentIndexOfCapmaign];
    print(
        '[Campaign] Rotating to index $_currentIndexOfCapmaign of $count '
        '(${nextCampaign.campaignName}, '
        'composition=${nextCampaign.isCompositionLayout})');

    // #region agent log
    _mqttAgentDebugLog(
      'mqtt_view_model.dart:_updateIndexForCampain',
      'campaign rotated',
      {
        'newIndex': _currentIndexOfCapmaign,
        'totalCampaigns': count,
        'campaignName': nextCampaign.campaignName,
        'isComposition': nextCampaign.isCompositionLayout,
      },
      'G',
    );
    // #endregion

    Map<String, dynamic> sendLog = {
      "action": "player_logs",
      "log": "Current Campaign",
      "name": (_currentIndexOfCapmaign < count)
          ? (playableCampaigns[_currentIndexOfCapmaign].campaignName ?? "")
          : "",
      "type": "info",
      "date_time": DateTime.now().toIso8601String(),
    };

    _mqttClientService.publish(topic, jsonEncode(sendLog));
    notifyListeners();
    startPlaylistTimerForCampaign();
  }

  void resetTimerForCapmpain() {
    _timerOfCampaign?.cancel();
    notifyListeners();
  }

  bool _isPlaylistDateInRangeForCampagin(DateTime startDate, DateTime endDate) {
    DateTime now = DateTime.now();
    return now.isAfter(startDate) &&
        now.isBefore(endDate.add(const Duration(days: 1)));
  }

  bool _isCurrentDayAllowedForCampain(dynamic days, DateTime now) {
    switch (now.weekday) {
      case 1:
        return days.monday ?? false;
      case 2:
        return days.tuesday ?? false;
      case 3:
        return days.wednesday ?? false;
      case 4:
        return days.thursday ?? false;
      case 5:
        return days.friday ?? false;
      case 6:
        return days.saturday ?? false;
      case 7:
        return days.sunday ?? false;
      default:
        return false;
    }
  }

  bool _isTimeInRangeForCampaign(String timeFrom, String timeTo) {
    DateTime currentTime = DateTime.now();
    DateTime fromTime = DateTime.now().copyWith(
      hour: int.parse(timeFrom.split(':')[0]),
      minute: int.parse(timeFrom.split(':')[1]),
    );

    DateTime toTime = DateTime.now().copyWith(
      hour: int.parse(timeTo.split(':')[0]),
      minute: int.parse(timeTo.split(':')[1]),
    );

    return currentTime.isAfter(fromTime) && currentTime.isBefore(toTime);
  }

  void _updateMessage() {
    notifyListeners();
  }

  void reloadApp(BuildContext context) {
    Phoenix.rebirth(context); // App restart
  }

  int _currentIndex = 0;
  Timer? _timer;

  int get currentIndex => _currentIndex;

  int get currentDuration {
    final currentPlaylist = playListModel!.data.playlist[_currentIndex];
    final playlistSchedule = currentPlaylist.playlistSchedule;

    int duration = 2;

    // Check if the item is in the schedule or should always play
    if (playlistSchedule!.alwaysPlay ||
        _isPlaylistDateInRange(
              playlistSchedule.period!.date.start,
              playlistSchedule.period!.date.end,
            ) &&
            _isCurrentDayAllowed(
              playlistSchedule.period!.days,
              DateTime.now(),
            ) &&
            _isTimeInRange(
              playlistSchedule.period!.time.from,
              playlistSchedule.period!.time.to,
            )) {
      duration = int.parse(currentPlaylist.playlistDefault!.duration);
    }

    // Log the state
    print(
        "Current Index: $_currentIndex, Duration: $duration seconds, Always Play: ${playlistSchedule.alwaysPlay}");

    return duration;
  }

  void startPlaylistTimer() {
    _timer?.cancel();
    print("this is duration$currentDuration");
    // If the duration is 0, directly update the index and skip the timer setup
    if (currentDuration == 2) {
      _updateIndex();
      print("Playlist item not in schedule, skipping timer setup.");
    } else {
      // Only start the timer if the duration is greater than 0
      _timer = Timer(Duration(seconds: currentDuration), _updateIndex);
    }
  }

  void _updateIndex() {
    _currentIndex = (_currentIndex + 1) % playListModel!.data.playlist.length;
    print(
        "current playlist ${_playListModel!.data.playlist[_currentIndex].name} ");

    Map<String, dynamic> sendLog = {
      "action": "player_logs",
      "log": "Current Playlist",
      "name": "${_playListModel!.data.playlist[_currentIndex].name}",
      "type": "info",
      "date_time": DateTime.now().toIso8601String(),
    };

    _mqttClientService.publish(topic, jsonEncode(sendLog));

    notifyListeners();
    startPlaylistTimer();
  }

  void resetTimer() {
    _timer?.cancel();
    notifyListeners();
  }

// Clean up timer
  @override
  void dispose() {
    _timerOfCampaign?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  bool _isPlaylistDateInRange(DateTime startDate, DateTime endDate) {
    DateTime now = DateTime.now();
    return now.isAfter(startDate) &&
        now.isBefore(endDate.add(const Duration(days: 1)));
  }

  bool _isCurrentDayAllowed(dynamic days, DateTime now) {
    switch (now.weekday) {
      case 1:
        return days.monday ?? false;
      case 2:
        return days.tuesday ?? false;
      case 3:
        return days.wednesday ?? false;
      case 4:
        return days.thursday ?? false;
      case 5:
        return days.friday ?? false;
      case 6:
        return days.saturday ?? false;
      case 7:
        return days.sunday ?? false;
      default:
        return false;
    }
  }

  bool _isTimeInRange(String timeFrom, String timeTo) {
    DateTime currentTime = DateTime.now();
    DateTime fromTime = DateTime.now().copyWith(
      hour: int.parse(timeFrom.split(':')[0]),
      minute: int.parse(timeFrom.split(':')[1]),
      second: int.parse(timeFrom.split(':')[2]),
    );

    DateTime toTime = DateTime.now().copyWith(
        hour: int.parse(timeTo.split(':')[0]),
        minute: int.parse(timeTo.split(':')[1]),
        second: int.parse(timeFrom.split(':')[2]));

    return currentTime.isAfter(fromTime) && currentTime.isBefore(toTime);
  }

  /// Check if restrictions allow the campaign/media to play
  bool checkRestrictions(List<Restriction>? restrictions) {
    const String reset = '\x1B[0m';
    const String red = '\x1B[31m';
    const String green = '\x1B[32m';
    const String yellow = '\x1B[33m';
    const String blue = '\x1B[34m';

    if (restrictions == null || restrictions.isEmpty) {
      print('$yellow⚠️  RESTRICTION: No restrictions provided → Allowed$reset');
      return true; // No restrictions means allowed
    }

    DateTime now = DateTime.now();
    bool allRestrictionsPass = true;

    print(
        '$blue🔍 RESTRICTION: Checking ${restrictions.length} restriction(s)...$reset');

    for (var restriction in restrictions) {
      if (restriction.type == null ||
          restriction.operator == null ||
          restriction.values == null) {
        print(
            '$yellow⚠️  RESTRICTION: Skipping invalid restriction (missing type/operator/values)$reset');
        continue; // Skip invalid restrictions
      }

      bool restrictionPass = false;

      // Only apply restrictions for "date" or "time" types
      if (restriction.type == "date") {
        restrictionPass = _checkDateRestriction(restriction, now);
      } else if (restriction.type == "time") {
        restrictionPass = _checkTimeRestriction(restriction, now);
      } else {
        // If type is not "date" or "time", treat as always play
        restrictionPass = true;
        print(
            "$yellow⚠️  RESTRICTION: Type '${restriction.type}' is not date/time → Treating as always play$reset");
      }

      // All restrictions must pass (AND logic)
      if (!restrictionPass) {
        allRestrictionsPass = false;
        print(
            '$red❌ RESTRICTION: Failed - type: ${restriction.type}, operator: ${restriction.operator}, values: ${restriction.values}$reset');
        break;
      } else {
        print(
            '$green✅ RESTRICTION: Passed - type: ${restriction.type}, operator: ${restriction.operator}, values: ${restriction.values}$reset');
      }
    }

    if (allRestrictionsPass) {
      print('$green✅ RESTRICTION: All restrictions PASSED$reset');
    } else {
      print('$red❌ RESTRICTION: At least one restriction FAILED$reset');
    }

    return allRestrictionsPass;
  }

  /// Check date restriction based on operator
  bool _checkDateRestriction(Restriction restriction, DateTime now) {
    if (restriction.values == null || restriction.values!.isEmpty) {
      return false;
    }

    final operator = _normalizeRestrictionOperator(restriction.operator);
    final values = restriction.values!;

    try {
      switch (operator) {
        case "is-between":
          if (values.length >= 2) {
            final startDate = DateTime.parse(values[0]);
            final endDate = DateTime.parse(values[1]);
            final startDateOnly =
                DateTime(startDate.year, startDate.month, startDate.day);
            final endDateOnly =
                DateTime(endDate.year, endDate.month, endDate.day);
            final nowDateOnly = DateTime(now.year, now.month, now.day);

            final shouldPlay = (nowDateOnly.isAfter(startDateOnly) ||
                    nowDateOnly.isAtSameMomentAs(startDateOnly)) &&
                (nowDateOnly.isBefore(endDateOnly) ||
                    nowDateOnly.isAtSameMomentAs(endDateOnly));

            print(
                "DATE_CHECK:: is-between - start: ${startDateOnly.toString().split(' ')[0]}, end: ${endDateOnly.toString().split(' ')[0]}, current: ${nowDateOnly.toString().split(' ')[0]}, shouldPlay: $shouldPlay");
            return shouldPlay;
          }
          return false;

        case "on":
          if (values.isNotEmpty) {
            final targetDate = DateTime.parse(values[0]);
            final targetDateOnly =
                DateTime(targetDate.year, targetDate.month, targetDate.day);
            final nowDateOnly = DateTime(now.year, now.month, now.day);

            final shouldPlay = nowDateOnly.isAtSameMomentAs(targetDateOnly) ||
                nowDateOnly.isAfter(targetDateOnly);

            print(
                "DATE_CHECK:: on - target: ${targetDateOnly.toString().split(' ')[0]}, current: ${nowDateOnly.toString().split(' ')[0]}, shouldPlay: $shouldPlay");
            return shouldPlay;
          }
          return false;

        case "is-before":
          if (values.isNotEmpty) {
            final targetDate = DateTime.parse(values[0]);
            return now.isBefore(targetDate);
          }
          return false;

        case "is-after":
          if (values.isNotEmpty) {
            final targetDate = DateTime.parse(values[0]);
            final targetDateOnly =
                DateTime(targetDate.year, targetDate.month, targetDate.day);
            final nowDateOnly = DateTime(now.year, now.month, now.day);

            final shouldPlay = nowDateOnly.isAfter(targetDateOnly) ||
                nowDateOnly.isAtSameMomentAs(targetDateOnly);

            print(
                "DATE_CHECK:: is-after - target: ${targetDateOnly.toString().split(' ')[0]}, current: ${nowDateOnly.toString().split(' ')[0]}, shouldPlay: $shouldPlay");
            return shouldPlay;
          }
          return false;

        case "not-on":
          if (values.isNotEmpty) {
            final targetDate = DateTime.parse(values[0]);
            final targetDateOnly =
                DateTime(targetDate.year, targetDate.month, targetDate.day);
            final nowDateOnly = DateTime(now.year, now.month, now.day);
            return !(nowDateOnly.isAtSameMomentAs(targetDateOnly));
          }
          return false;

        default:
          print("Unknown date restriction operator: $operator");
          return false;
      }
    } catch (e) {
      print("Error parsing date restriction: $e");
      return false;
    }
  }

  /// Check time restriction based on operator
  bool _checkTimeRestriction(Restriction restriction, DateTime now) {
    const String reset = '\x1B[0m';
    const String red = '\x1B[31m';
    const String cyan = '\x1B[36m';

    if (restriction.values == null || restriction.values!.isEmpty) {
      print("${red}TIME_CHECK:: No values provided for time restriction$reset");
      return false;
    }

    final operator = _normalizeRestrictionOperator(restriction.operator);
    final values = restriction.values!;

    print(
        "${cyan}TIME_CHECK:: Checking time restriction - operator: $operator, values: $values, current time: ${now.hour}:${now.minute.toString().padLeft(2, '0')}$reset");

    try {
      switch (operator) {
        case "is-between":
          if (values.length >= 2) {
            final startTime = _parseTimeString(values[0]);
            final endTime = _parseTimeString(values[1]);
            final currentTime =
                DateTime(now.year, now.month, now.day, now.hour, now.minute);
            final result = (currentTime.isAfter(startTime) ||
                    currentTime.isAtSameMomentAs(startTime)) &&
                (currentTime.isBefore(endTime) ||
                    currentTime.isAtSameMomentAs(endTime));
            print(
                "${cyan}TIME_CHECK:: is-between - start: ${startTime.hour}:${startTime.minute.toString().padLeft(2, '0')}, end: ${endTime.hour}:${endTime.minute.toString().padLeft(2, '0')}, current: ${currentTime.hour}:${currentTime.minute.toString().padLeft(2, '0')}, result: $result$reset");
            return result;
          }
          return false;

        case "on":
          if (values.isNotEmpty) {
            final targetTime = _parseTimeString(values[0]);
            final targetHour = targetTime.hour;
            final targetMinute = targetTime.minute;
            final currentHour = now.hour;
            final currentMinute = now.minute;

            final shouldPlay =
                currentHour == targetHour && currentMinute == targetMinute;

            print(
                "${cyan}TIME_CHECK:: on - target: ${targetHour.toString().padLeft(2, '0')}:${targetMinute.toString().padLeft(2, '0')}, current: ${currentHour.toString().padLeft(2, '0')}:${currentMinute.toString().padLeft(2, '0')}, result: $shouldPlay$reset");
            return shouldPlay;
          }
          return false;

        case "is-before":
          if (values.isNotEmpty) {
            final targetTime = _parseTimeString(values[0]);
            final currentTime =
                DateTime(now.year, now.month, now.day, now.hour, now.minute);
            final result = currentTime.isBefore(targetTime);
            print(
                "TIME_CHECK:: is-before - target: ${targetTime.hour}:${targetTime.minute.toString().padLeft(2, '0')}, current: ${currentTime.hour}:${currentTime.minute.toString().padLeft(2, '0')}, result: $result");
            return result;
          }
          return false;

        case "is-after":
          if (values.isNotEmpty) {
            final targetTime = _parseTimeString(values[0]);
            final currentTime =
                DateTime(now.year, now.month, now.day, now.hour, now.minute);
            final result = currentTime.isAfter(targetTime) ||
                currentTime.isAtSameMomentAs(targetTime);
            print(
                "${cyan}TIME_CHECK:: is-after - target: ${targetTime.hour}:${targetTime.minute.toString().padLeft(2, '0')}, current: ${currentTime.hour}:${currentTime.minute.toString().padLeft(2, '0')}, result: $result$reset");
            return result;
          }
          return false;

        case "not-on":
          if (values.isNotEmpty) {
            final targetTime = _parseTimeString(values[0]);
            final currentTime =
                DateTime(now.year, now.month, now.day, now.hour, now.minute);
            final result = !(currentTime.isAtSameMomentAs(targetTime));
            print(
                "TIME_CHECK:: not-on - target: ${targetTime.hour}:${targetTime.minute.toString().padLeft(2, '0')}, current: ${currentTime.hour}:${currentTime.minute.toString().padLeft(2, '0')}, result: $result");
            return result;
          }
          return false;

        default:
          print("TIME_CHECK:: Unknown time restriction operator: $operator");
          return false;
      }
    } catch (e) {
      print("TIME_CHECK:: Error parsing time restriction: $e");
      return false;
    }
  }

  /// Parse time string (HH:mm or HH:mm:ss) to DateTime
  DateTime _parseTimeString(String timeStr) {
    // Trim whitespace from the time string to handle cases like "07: 04"
    final trimmed = timeStr.trim();
    final parts = trimmed.split(':');
    if (parts.length < 2) {
      throw FormatException("Invalid time format: $timeStr");
    }
    // Trim whitespace from each part to handle cases like "07: 04"
    final hour = int.parse(parts[0].trim());
    final minute = int.parse(parts[1].trim());
    final second = parts.length > 2 ? int.parse(parts[2].trim()) : 0;
    return DateTime(DateTime.now().year, DateTime.now().month,
        DateTime.now().day, hour, minute, second);
  }

  /// Normalize operator strings coming from backend.
  /// Accepts variants like: isbetween / is-between / is_between, noton / not-on, etc.
  String _normalizeRestrictionOperator(String? op) {
    if (op == null) return '';
    final raw = op.trim().toLowerCase();
    final compact = raw
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('_', '')
        .replaceAll('-', '');

    switch (compact) {
      case 'isbetween':
        return 'is-between';
      case 'isbefore':
        return 'is-before';
      case 'isafter':
        return 'is-after';
      case 'noton':
        return 'not-on';
      default:
        // Best-effort: normalize underscores to hyphens.
        return raw.replaceAll('_', '-');
    }
  }

  Future<void> launchUrl(String url) async {
    if (await canLaunch(url)) {
      await launch(url);
    } else {
      throw 'Could not launch $url';
    }
  }
}
