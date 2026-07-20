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
import 'package:image/image.dart' as img;
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
import 'package:digital_signage/utils/agent_debug_log.dart';
import 'package:digital_signage/utils/globle_variable.dart';
import 'package:digital_signage/view_models/system_apply_settings_vm.dart';

import '../data/api_repository/api_repository.dart';
import '../services/mqtt_client_service.dart';
import '../utils/constants.dart';

class _RemoteViewFrame {
  final Uint8List bytes;
  final double scaleX;
  final double scaleY;
  _RemoteViewFrame({required this.bytes, required this.scaleX, required this.scaleY});
}

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

  Timer? _pairingRevalidationTimer;

  // The very first connect() (app startup) fires before pairing has
  // discovered a player code, so it can't set LWT/publish online status
  // (both need the topic). Once _checkPairingStatus() learns the topic,
  // reconnect exactly once so those get set up correctly — guarded so the
  // 30s periodic re-validation timer doesn't tear down and rebuild the
  // MQTT connection on every check afterward.
  bool _connectedWithPlayerCode = false;

  Timer? _remoteViewTimer;
  bool _remoteViewActive = false;
  bool _remoteViewCaptureInFlight = false;
  double _remoteViewScaleX = 1.0;
  double _remoteViewScaleY = 1.0;
  static const _remoteViewChannel = MethodChannel('com.example/remoteView');

  bool get isAdCampaignUpdate {
    if (isAdCampaignUpdateMessage(_campaignModel?.data?.message)) return true;
    if (campaignPayloadContainsAdSlots(_campaignModel)) return true;
    final data = storedJsonObj['data'];
    if (data is Map) {
      if (isAdCampaignUpdateMessage(data['message']?.toString())) return true;
    }
    if (storedPayloadContainsAdSlots(storedJsonObj)) return true;
    return false;
  }

  InteractivityModel? _interactivityModel;

  InteractivityModel? get interactivityModel => _interactivityModel;

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
      return jsonResponse;
    } else {
      print('No stored response found.');
      return null;
    }
  }

  Future<void> loadDeviceInfoFromSharedPreferences() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? jsonString = prefs.getString('deviceInfoMap');
    // Was prefs.clear() — wiped the ENTIRE SharedPreferences store (pairing
    // state, apiResponse, storeState, everything) on every single app
    // launch just for reading this one key, which is why the player never
    // remembered its pairing across restarts. Only remove the key actually
    // being consumed here.
    await prefs.remove('deviceInfoMap');
    if (jsonString != null) {
      // Was `deviceInfoMap = Map<String, dynamic>.from(...)`, which
      // reassigns the global to a brand-new object. `devicesinfo` (used
      // everywhere else, including all the platform-specific device-info
      // population code) is bound to the ORIGINAL object at field-init
      // time — reassigning here silently breaks that alias forever, so
      // nothing written via devicesinfo[...] afterward ever reaches what
      // actually gets published. Mutate the existing map in place instead
      // so the alias stays intact.
      deviceInfoMap
        ..clear()
        ..addAll(Map<String, dynamic>.from(jsonDecode(jsonString)));
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

        // Compress the image further
        final compressedImageBytes = await _compressImage(imageBytes);
        debugPrint("Compressed image size: ${compressedImageBytes.length}");

        // Convert to Base64 string
        final base64String = base64Encode(compressedImageBytes);

        // Publish the Base64-encoded string
        // Map<String, dynamic> sendLog = {
        //   "action": "screenShot",
        //   "name": "screenshot",
        //   "type": "screenShot",
        //   "dateTime": DateTime.now()
        //       .toIso8601String(), // Current date and time in ISO 8601 format
        // };

        // _mqttClientService.publish(topic, jsonEncode(sendLog));
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

    _pairingRevalidationTimer?.cancel();
    _pairingRevalidationTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_topic.isNotEmpty) {
        _checkPairingStatus();
      }
    });

    InternetConnectionChecker().onStatusChange.listen((status) async {
      final hasConnection = status == InternetConnectionStatus.connected;

      if (hasConnection) {
        print("this is data $storedJsonObj");

        if (storedJsonObj["action"] == "publish_playlist") {
          await _mqttClientService.connect(playerCode: _topic);

          if (_topic.isNotEmpty) {
            subsibeMessage(_topic);
          }
          if (globleTopic.isNotEmpty) {
            publishMessage(globleTopic, jsonEncode(deviceInfoMap));
          }
          _playListModel = playListModelFromJson(jsonEncode(storedJsonObj));

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
        } else if (storedJsonObj["action"] == "publish_campaign") {
          await _mqttClientService.connect(playerCode: _topic);

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
        } else {
          print("elssssssssssssssssssssse caseeeeeee}");
          _mqttConnection();
        }
      } else {
        if (storedJsonObj["action"] == "publish_playlist") {
          _playListModel = playListModelFromJson(jsonEncode(storedJsonObj));
          print(_mediaList);
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
        print("System Info: $systemInfo");
        devicesinfo["android_version"] = systemInfo["os_version"];
        devicesinfo["platform"] = "macos";
        devicesinfo["device_resolution"] = systemInfo["device_resolution"];
        devicesinfo["time_zone"] = systemInfo["time_zone"];
        devicesinfo["cpu_information"] = systemInfo["cpu_information"];
        devicesinfo["memory_information"] = systemInfo["memory_information"];
        devicesinfo["storage_info"] = systemInfo["storage_info"];
        devicesinfo["device_model"] = systemInfo["device_model"];
        // hardware_details.brand/model are what CMS actually displays as
        // Manufacturer/Model — getSystemInformation() on the native side
        // already returns device_model (e.g. "MacBookPro15,1"), this was
        // just never mapped into hardware_details the way Android does.
        devicesinfo["hardware_details"]["brand"] = "Apple";
        devicesinfo["hardware_details"]["model"] = systemInfo["device_model"];
        devicesinfo["hardware_details"]["device_id"] = systemInfo["uuid"];

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
      await _mqttClientService.connect(playerCode: _topic);
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

    // Map<String, dynamic> sendLog = {
    //   "action": "player_logs",
    //   "log": "Download Playlist",
    //   "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
    //   "type": "info",
    //   "date_time": DateTime.now().toIso8601String(),
    // };
    // _mqttClientService.publish(topic, jsonEncode(sendLog));
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
            // Map<String, dynamic> errorLog = {
            //   "action": "player_logs",
            //   "log": "Download Playlist",
            //   "name":
            //       "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
            //   "type": "error",
            //   "date_time": DateTime.now().toIso8601String(),
            // };

            // _mqttClientService.publish(topic, jsonEncode(errorLog));
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

    // Map<String, dynamic> sendLog = {
    //   "action": "player_logs",
    //   "log": "Download Campaign",
    //   "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
    //   "type": "info",
    //   "date_time": DateTime.now().toIso8601String(),
    // };

    // _mqttClientService.publish(topic, jsonEncode(sendLog));

    // Collect ALL downloadable media items (including nested sub-zones inside campaign media).
    final downloadTargets = _collectCampaignMediaItemsForDownload(
      _campaignModel?.data?.playerCampaigns ?? const [],
    );
    _downloadCount = downloadTargets.length;

    print("Total files to download: $_downloadCount");

    if (_downloadCount > 0) {
      _state = MqttState.downloading;
      notifyListeners();
    } else {
      // Zero downloadable files doesn't mean there's no content — webapp/
      // text/shape media types are deliberately excluded from
      // _collectCampaignMediaItemsForDownload above (nothing to download,
      // they load their URL directly in-app). A campaign made entirely of
      // those types legitimately has zero files to fetch and is already
      // ready to display, same as after the download loop below finishes.
      _state = MqttState.campaignScreen;
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
        // Map<String, dynamic> sendLog = {
        //   "action": "player_logs",
        //   "log": "Download Campaign",
        //   "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        //   "type": "error",
        //   "date_time": DateTime.now().toIso8601String(),
        // };

        // _mqttClientService.publish(topic, jsonEncode(sendLog));
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
    if (!canReportAdProofOfPlay(request)) {
      print(
          '[AdPoP] Skipped: ad_campaign_id is missing (zone=${request.zoneId})');
      return;
    }
    final creativeUrl = request.creativeUrl.trim();
    if (creativeUrl.isNotEmpty &&
        !creativeUrl.toLowerCase().startsWith('http')) {
      print(
          '[AdPoP] Skipped: creative_url must be remote HTTPS, got: $creativeUrl');
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
        "player/connection/",
        requestBody,
        null,
      );
      final jsonResponse = jsonEncode(response);

      SharedPreferences prefs = await SharedPreferences.getInstance();
      bool isSaved = await prefs.setString('apiResponse', jsonResponse);
      print("check status ::::$isSaved");

      _topic = response["player_code"] ?? "";

      if (_topic.isEmpty) {
        debugPrint("Warning: player_code is empty or null in API response");
        _state = MqttState.failure;
        notifyListeners();
        return;
      }

      globleTopic = _topic;
      if (!_connectedWithPlayerCode) {
        await _mqttClientService.connect(playerCode: _topic);
        _connectedWithPlayerCode = true;
      }
      subsibeMessage(_topic);
      await prefs.setString('deviceInfoMap', jsonEncode(deviceInfoMap));
      publishMessage(globleTopic, jsonEncode(deviceInfoMap));

      // await captureAndSendScreenshot(globleTopic);
      // Reset retry counter on successful connection
      _pairingRetryCount = 0;

      if (response["paired"] == false) {
        print("this is state screeen ${response["paired"]}");
        await prefs.setBool('storeState', response["paired"]);

        _state = MqttState.pairedScreen;

        if (_campaignModel != null ||
            _playListModel != null ||
            storedJsonObj.isNotEmpty) {
          debugPrint(
              'MQTT_LOGS:: Player no longer paired — clearing cached content');
          _campaignModel = null;
          _playListModel = null;
          _interactivityModel = null;
          storedJsonObj = {};
          await prefs.clear();
        }
      } else if (response["paired"] == true) {
        // Start capturing screenshots every second
        // Timer.periodic(Duration(seconds: 1), (timer) async {
        //   await captureAndSendScreenshot(globleTopic);
        // });

        // Periodic re-validation (see _pairingRevalidationTimer) calls this
        // same method every 30s — don't let it clobber active playback
        // state back to "no content" while a campaign/playlist is actually
        // showing or downloading.
        if (_state != MqttState.downloading &&
            _state != MqttState.campaignScreen &&
            _state != MqttState.playlistScreen) {
          _state = MqttState.noContent;
        }
      } else {
        _state = MqttState.failure;
      }
      notifyListeners();
    } catch (error) {
      debugPrint("Error during pairing check: $error");

      // Don't restart or retry if already paired - just log the error
      if (_state == MqttState.pairedScreen) {
        debugPrint("Device is already paired. Skipping retry and restart.");
        return;
      }

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
    _mqttClientService.subscribe('$topic/remote');
  }

  /// Starts periodic screenshot capture for remote view: publishes
  /// `{action:"image", img_url:<base64>, sender:"macos"}` to
  /// `{playerCode}/remote` roughly once a second while active. CMS sends
  /// click/scroll/send_text/press_home commands back on the same topic,
  /// handled in the action dispatch below and injected via the native
  /// com.example/remoteView channel (CGEvent-based on macOS).
  void _startRemoteView() {
    if (_remoteViewActive) {
      debugPrint('MQTT_LOGS:: Remote view already active, ignoring duplicate start');
      return;
    }
    _remoteViewActive = true;
    _remoteViewScaleX = 1.0;
    _remoteViewScaleY = 1.0;
    debugPrint('MQTT_LOGS:: Remote view started');
    _remoteViewTimer?.cancel();
    _captureAndPublishRemoteViewFrame();
    _remoteViewTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _captureAndPublishRemoteViewFrame();
    });
  }

  void _stopRemoteView() {
    _remoteViewActive = false;
    _remoteViewTimer?.cancel();
    _remoteViewTimer = null;
    debugPrint('MQTT_LOGS:: Remote view stopped');
  }

  Future<void> _captureAndPublishRemoteViewFrame() async {
    if (!_remoteViewActive) return;
    if (_topic.isEmpty || !_mqttClientService.isConnected) return;
    // CMS toggles start/stop rapidly (to avoid unbounded base64 streaming),
    // so an in-flight capture finishing just after stop_remote_view arrives
    // must not still publish a stray frame.
    if (_remoteViewCaptureInFlight) return;
    _remoteViewCaptureInFlight = true;

    try {
      Uint8List? imageBytes;
      if (Platform.isMacOS) {
        imageBytes = await _captureScreenshotForMac();
      } else {
        return;
      }
      if (imageBytes == null) return;

      // Self-window captures on Retina displays come back at
      // backingScaleFactor-multiplied pixel dimensions, so this needs the
      // same shrink-to-budget treatment as Linux (for a different reason —
      // DPI multiplier instead of raw screen resolution). Routing through
      // _compressImage/FlutterImageCompress instead would hardcode
      // scale=1.0 even while resizing, silently breaking click coordinate
      // mapping the moment the image actually shrinks.
      final Uint8List compressedBytes;
      final resized = _resizeAndCompressForRemoteView(imageBytes);
      if (resized != null) {
        compressedBytes = resized.bytes;
        _remoteViewScaleX = resized.scaleX;
        _remoteViewScaleY = resized.scaleY;
      } else {
        compressedBytes = imageBytes;
        _remoteViewScaleX = 1.0;
        _remoteViewScaleY = 1.0;
      }
      final base64Image = base64Encode(compressedBytes);

      final payload = jsonEncode({
        'action': 'image',
        'img_url': base64Image,
        'sender': 'macos',
      });

      if (!_remoteViewActive) {
        debugPrint('MQTT_LOGS:: Remote view stopped mid-capture, discarding frame');
        return;
      }

      _mqttClientService.publishMessage('$_topic/remote', utf8.encode(payload));
    } catch (e) {
      debugPrint('MQTT_LOGS:: Failed to capture/publish remote view frame: $e');
    } finally {
      _remoteViewCaptureInFlight = false;
    }
  }

  Future<Uint8List?> _captureScreenshotForMac() async {
    try {
      final result = await _remoteViewChannel.invokeMethod('captureScreenshot');
      if (result is Uint8List) return result;
      return null;
    } on PlatformException catch (e) {
      debugPrint('MQTT_LOGS:: macOS screenshot capture failed: ${e.message}');
      return null;
    }
  }

  /// Shrinks a captured frame's actual pixel dimensions (not just JPEG
  /// quality) so the published payload reliably fits under whatever
  /// max-message-size the broker/CMS enforces, and reports the scale
  /// factor needed to map received click coordinates back to real screen
  /// pixels.
  _RemoteViewFrame? _resizeAndCompressForRemoteView(
    Uint8List bytes, {
    int maxBytes = 15 * 1024,
  }) {
    const tiers = [
      (width: 640, quality: 45),
      (width: 480, quality: 40),
      (width: 320, quality: 35),
      (width: 240, quality: 30),
    ];
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      Uint8List? smallestSoFar;
      double smallestScaleX = 1.0, smallestScaleY = 1.0;
      for (final tier in tiers) {
        if (decoded.width <= tier.width && smallestSoFar == null) {
          final jpgBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: tier.quality));
          smallestSoFar = jpgBytes;
          smallestScaleX = 1.0;
          smallestScaleY = 1.0;
          if (jpgBytes.length <= maxBytes) break;
          continue;
        }
        final resized = img.copyResize(decoded, width: tier.width);
        final jpgBytes = Uint8List.fromList(img.encodeJpg(resized, quality: tier.quality));
        smallestSoFar = jpgBytes;
        smallestScaleX = decoded.width / resized.width;
        smallestScaleY = decoded.height / resized.height;
        if (jpgBytes.length <= maxBytes) break;
      }
      if (smallestSoFar == null) return null;
      return _RemoteViewFrame(bytes: smallestSoFar, scaleX: smallestScaleX, scaleY: smallestScaleY);
    } catch (e) {
      return null;
    }
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
      // Map<String, dynamic> sendLog = {
      //   "action": "Action Reboot",
      //   "name": "Player ${deviceInfo!["hardware_details"]["model"]}",
      //   "type": "info",
      //   "dateTime": DateTime.now().toIso8601String(),
      // };

      // _mqttClientService.publish(topic, jsonEncode(sendLog));
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
      // Map<String, dynamic> sendLog = {
      //   "action": "Action Setup Player",
      //   "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      //   "type": "info",
      //   "dateTime": DateTime.now().toIso8601String(),
      // };

      // _mqttClientService.publish(topic, jsonEncode(sendLog));
      if (storeState != null) {
        if (storeState == false) {
          await _checkPairingStatus();
        }
      }
      // print("action mute${jsonObj["settings"]?["mute_audio"]}");
      if (jsonObj["settings"] != null &&
          jsonObj["settings"]["mute_audio"] == true) {
        // Map<String, dynamic> sendLog = {
        //   "action": "player_logs",
        //   "log": "Mute Audio",
        //   "name": "Player ${deviceInfo!["hardware_details"]["model"]}",
        //   "type": "info",
        //   "date_time": DateTime.now().toIso8601String(),
        // };

        // _mqttClientService.publish(topic, jsonEncode(sendLog));
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
      }
      // Independent `if`s below (not `else if`) — CMS resends the whole
      // current settings object on any single change, so an else-if chain
      // here meant only the first truthy field in the payload ever got
      // applied and every other setting silently no-oped whenever it
      // arrived alongside an earlier one.
      if (jsonObj["settings"] != null &&
          jsonObj["settings"]["mute_audio"] == false) {
        // Map<String, dynamic> sendLog = {
        //   "action": "player_logs",
        //   "log": "Unmute Audio",
        //   "name": "Player $globleTopic}",
        //   "type": "info",
        //   "date_time": DateTime.now().toIso8601String(),
        // };

        // _mqttClientService.publish(topic, jsonEncode(sendLog));
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
      }
      if (jsonObj["settings"] != null &&
          jsonObj["settings"]["brightness"] != null &&
          jsonObj["settings"]["brightness"]['value'] != null) {
        // Map<String, dynamic> sendLog = {
        //   "action": "player_logs",
        //   "log": "brightness",
        //   "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        //   "type": "info",
        //   "date_time": DateTime.now().toIso8601String(),
        // };

        // _mqttClientService.publish(topic, jsonEncode(sendLog));
        if (Platform.isMacOS) {
          var value = jsonObj["settings"]["brightness"]['value'];
          deviceSettings.setBrightnessForMac((value as num).toDouble());
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
      if (jsonObj["settings"] != null &&
          jsonObj["settings"]["volume"] != null) {
        // Map<String, dynamic> sendLog = {
        //   "action": "player_logs",
        //   "log": "Volume",
        //   "name": "Player ${deviceInfo!["hardware_details"]["model"]}",
        //   "type": "info",
        //   "date_time": DateTime.now().toIso8601String(),
        // };

        // _mqttClientService.publish(topic, jsonEncode(sendLog));
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
      if (jsonObj["settings"] != null &&
          jsonObj["settings"]["screen_rotation"] != null) {
        if (Platform.isMacOS) {
          final rotation = jsonObj["settings"]["screen_rotation"].toString();
          deviceSettings.applyScreenRotationForMac(rotation);
        }
      }
      var data = {"success": true};
      publishMessage(globleTopic, jsonEncode(data));
    } else if (jsonObj["action"] == "action click") {
      print(" i am in action  click");
    } else if (jsonObj["action"] == "start_remote_view") {
      debugPrint("MQTT_LOGS:: start_remote_view received");
      _startRemoteView();
    } else if (jsonObj["action"] == "stop_remote_view") {
      debugPrint("MQTT_LOGS:: stop_remote_view received");
      _stopRemoteView();
    } else if (jsonObj["action"] == "low_res") {
      // Observed on the Linux branch: CMS can send this without ever
      // sending start_remote_view first — treat it as an equivalent
      // start trigger.
      _startRemoteView();
    } else if (jsonObj["action"] == "click") {
      final x = (jsonObj["x"] as num?)?.toDouble();
      final y = (jsonObj["y"] as num?)?.toDouble();
      if (x != null && y != null && Platform.isMacOS) {
        deviceSettings.moveCursorAndClickForMac(
          x * _remoteViewScaleX,
          y * _remoteViewScaleY,
        );
      }
    } else if (jsonObj["action"] == "scroll") {
      final hold = jsonObj["hold"];
      final release = jsonObj["release"];
      if (hold is Map && release is Map && Platform.isMacOS) {
        final startX = (hold["x"] as num?)?.toDouble();
        final startY = (hold["y"] as num?)?.toDouble();
        final endX = (release["x"] as num?)?.toDouble();
        final endY = (release["y"] as num?)?.toDouble();
        if (startX != null && startY != null && endX != null && endY != null) {
          deviceSettings.dragForMac(
            startX * _remoteViewScaleX,
            startY * _remoteViewScaleY,
            endX * _remoteViewScaleX,
            endY * _remoteViewScaleY,
          );
        }
      }
    } else if (jsonObj["action"] == "send_text") {
      final text = jsonObj["message"]?.toString();
      if (text != null && text.isNotEmpty && Platform.isMacOS) {
        deviceSettings.typeTextForMac(text);
      }
    } else if (jsonObj["action"] == "press_home") {
      if (Platform.isMacOS) {
        deviceSettings.pressHomeForMac();
      }
    } else if (jsonObj["action"] == "publish_playlist") {
      // Map<String, dynamic> sendLog = {
      //   "action": "player_logs",
      //   "log": "Publish Playlist",
      //   "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      //   "type": "info",
      //   "date_time": DateTime.now().toIso8601String(),
      // };

      // _mqttClientService.publish(topic, jsonEncode(sendLog));
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
      // Map<String, dynamic> sendLog = {
      //   "action": "player_logs",
      //   "log": "Publish Campaign",
      //   "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      //   "type": "info",
      //   "date_time": DateTime.now().toIso8601String(),
      // };

      // _mqttClientService.publish(topic, jsonEncode(sendLog));
      _msg = jsonObj["action"];
      _campaignModel = normalizeCampaignResponse(
        campaignModelFromJson(jsonEncode(jsonObj)),
        jsonObj,
      );
      // Keep campaign index in bounds when campaign list changes (e.g. single campaign)
      final campaigns = _campaignModel?.data?.playerCampaigns;
      final count = campaigns?.length ?? 0;
      if (count > 0) {
        _selectCompositionCampaignIndexIfPresent();
        if (_currentIndexOfCapmaign >= count) {
          _currentIndexOfCapmaign = 0;
        }
        // #region agent log
        final parsedCampaigns = campaigns!;
        final compCampaigns =
            parsedCampaigns.where((c) => c.isCompositionLayout).toList();
        int? zone2CompositionLayers;
        for (final c in parsedCampaigns) {
          for (final z in c.zones ?? const <CampaignZone>[]) {
            if (z.id != 2) continue;
            for (final m in z.mediaItems ?? const <MediaItem>[]) {
              if ((m.mediaType ?? '').toLowerCase() == 'composition') {
                zone2CompositionLayers = m.zones?.length ?? 0;
              }
            }
          }
        }
        final regularCamps =
            parsedCampaigns.where((c) => !c.isCompositionLayout).toList();
        final selectedCamp = _currentIndexOfCapmaign < count
            ? parsedCampaigns[_currentIndexOfCapmaign]
            : null;
        final compositionLayerTypes = <Map<String, dynamic>>[];
        for (final c in parsedCampaigns) {
          for (final z in c.zones ?? const <CampaignZone>[]) {
            for (final m in z.mediaItems ?? const <MediaItem>[]) {
              if ((m.mediaType ?? '').toLowerCase() != 'composition') continue;
              for (final lz in m.zones ?? const <CampaignZone>[]) {
                for (final lm in lz.mediaItems ?? const <MediaItem>[]) {
                  compositionLayerTypes.add({
                    'zoneId': lz.id,
                    'mediaId': lm.id,
                    'type': lm.mediaType,
                    'svgLen': (lm.mediaUrl ?? '').length,
                    'hasUrl': (lm.mediaUrl ?? '').isNotEmpty,
                    'hasRemoteSrc': (lm.settings?.remoteSrc ?? '').isNotEmpty,
                    'hasHtml': (lm.settings?.html ?? '').isNotEmpty,
                    'fill': lm.settings?.fill,
                    'alwaysPlay': lm.schedule?.alwaysPlay,
                    'nestedCompId': lm.settings?.compositionCampaignId,
                    'nestedZones': lm.zones?.length ?? 0,
                  });
                }
              }
            }
          }
        }
        agentDebugLog(
          location: 'mqtt_view_model.dart:publish_campaign',
          message: 'campaigns_parsed',
          hypothesisId: 'H2',
          runId: 'post-fix',
          data: {
            'count': count,
            'regularCount': regularCamps.length,
            'selectedIndex': _currentIndexOfCapmaign,
            'selectedCampaign': selectedCamp != null
                ? {
                    'id': selectedCamp.campaignId,
                    'name': selectedCamp.campaignName,
                    'isComposition': selectedCamp.isCompositionLayout,
                    'zones': selectedCamp.zones?.length ?? 0,
                  }
                : null,
            'zone2CompositionLayers': zone2CompositionLayers,
            'compositionLayerTypes': compositionLayerTypes,
            'registryLayerTypes': globalCompositionCampaigns
                .expand((c) => c.zones ?? const <CampaignZone>[])
                .expand((z) => z.mediaItems ?? const <MediaItem>[])
                .map((m) => {
                      'id': m.id,
                      'type': m.mediaType,
                      'svgLen': (m.mediaUrl ?? '').length,
                    })
                .toList(),
            'debugLogPath': debugLogFilePath(),
            'globalCompositionCount': globalCompositionCampaigns.length,
            'allCampaigns': parsedCampaigns
                .map((c) => {
                      'id': c.campaignId,
                      'name': c.campaignName,
                      'zones': c.zones?.length ?? 0,
                      'isComposition': c.isCompositionLayout,
                    })
                .toList(),
          },
        );
        // #endregion
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
      // Map<String, dynamic> sendLog = {
      //   "action": "player_logs",
      //   "log": "Remove Playlist",
      //   "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      //   "type": "info",
      //   "date_time": DateTime.now().toIso8601String(),
      // };

      // _mqttClientService.publish(topic, jsonEncode(sendLog));
      SharedPreferences prefs = await SharedPreferences.getInstance();
      prefs.clear();

      await _checkPairingStatus();
    } else if (jsonObj["action"] == "action_delete") {
      // Map<String, dynamic> sendLog = {
      //   "action": "player_logs",
      //   "log": "Action Delete",
      //   "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      //   "type": "info",
      //   "date_time": DateTime.now().toIso8601String(),
      // };

      // _mqttClientService.publish(topic, jsonEncode(sendLog));
      debugPrint("remove playlist and update screen");
      SharedPreferences prefs = await SharedPreferences.getInstance();
      prefs.clear();
      await _checkPairingStatus();
      await getStoredState();
    } else if (jsonObj["action"] == "remove_campaign") {
      debugPrint("remove playlist and update screen");
      // Map<String, dynamic> sendLog = {
      //   "action": "player_logs",
      //   "log": "Remove Campaign",
      //   "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      //   "type": "info",
      //   "date_time": DateTime.now().toIso8601String(),
      // };

      // _mqttClientService.publish(topic, jsonEncode(sendLog));
      SharedPreferences prefs = await SharedPreferences.getInstance();
      prefs.clear();
      await _checkPairingStatus();
    }
    notifyListeners();
  }

  int _currentIndexOfCapmaign = 0;

  void _selectCompositionCampaignIndexIfPresent() {
    final campaigns = _campaignModel?.data?.playerCampaigns;
    if (campaigns == null || campaigns.isEmpty) return;

    // Compositions rotate in the same list as any other campaign now (see
    // normalizeCampaignResponse) — no longer skipped in favor of "regular"
    // campaigns just because both were published together. Just keep the
    // current index in bounds.
    if (_currentIndexOfCapmaign >= campaigns.length) {
      _currentIndexOfCapmaign = 0;
    }
  }

  Timer? _timerOfCampaign;

  int get currentIndexOfCapmaign => _currentIndexOfCapmaign;

  int get currentDurationOfCampaign {
    final currentCampaign =
        campaignModel?.data?.playerCampaigns?[_currentIndexOfCapmaign];
    if (currentCampaign == null) return 0;

    final campaignSchedule = currentCampaign.campaignSchedule;
    if (campaignSchedule == null) return 0;

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
            ))) {
      final durationValue = currentCampaign.campaignSettings?.duration;
      if (durationValue != null) {
        durationcampagin = int.tryParse(durationValue) ?? 0;
      }
    }

    // Log the state
    print(
        "Current Index: $_currentIndexOfCapmaign, Duration: $durationcampagin seconds, Always Play: ${campaignSchedule.alwaysPlay}");

    return durationcampagin;
  }

  void startPlaylistTimerForCampaign() {
    _timerOfCampaign?.cancel();

    // If the duration is 0, directly update the index and skip the timer setup
    if (currentDurationOfCampaign == 0) {
      _updateIndexForCampain();
      print("Playlist item not in schedule, skipping timer setup.");
    } else {
      // Only start the timer if the duration is greater than 0
      _timerOfCampaign = Timer(
          Duration(seconds: currentDurationOfCampaign), _updateIndexForCampain);
    }
  }

  void publishLogsForPlayList(String name) {
    // Map<String, dynamic> sendLog = {
    //   "action": "Playlist",
    //   "name": "$name",
    //   "type": "info",
    //   "dateTime": DateTime.now().toIso8601String(),
    // };

    // _mqttClientService.publish(topic, jsonEncode(sendLog));
  }

  void publishLogsForCampaign(String name) {
    // Map<String, dynamic> sendLog = {
    //   "action": "Campaign",
    //   "name": "$name",
    //   "type": "info",
    //   "dateTime": DateTime.now().toIso8601String(),
    // };

    // _mqttClientService.publish(topic, jsonEncode(sendLog));
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

    // Rotate through all campaigns, including compositions — they play in
    // rotation the same as any other campaign now (see
    // normalizeCampaignResponse), rather than being skipped whenever a
    // "regular" campaign was also published alongside them.
    _currentIndexOfCapmaign = (_currentIndexOfCapmaign + 1) % count;
    // Map<String, dynamic> sendLog = {
    //   "action": "player_logs",
    //   "log": "Current Campaign",
    //   "name": (_currentIndexOfCapmaign < count)
    //       ? (campaigns![_currentIndexOfCapmaign].campaignName ?? "")
    //       : "",
    //   "type": "info",
    //   "date_time": DateTime.now().toIso8601String(),
    // };

    // _mqttClientService.publish(topic, jsonEncode(sendLog));
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

    // Map<String, dynamic> sendLog = {
    //   "action": "player_logs",
    //   "log": "Current Playlist",
    //   "name": "${_playListModel!.data.playlist[_currentIndex].name}",
    //   "type": "info",
    //   "date_time": DateTime.now().toIso8601String(),
    // };

    // _mqttClientService.publish(topic, jsonEncode(sendLog));

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
    _pairingRevalidationTimer?.cancel();
    _remoteViewTimer?.cancel();
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
