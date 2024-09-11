import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:geolocator/geolocator.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/api_repository/api_repository.dart';
import '../services/mqtt_client_service.dart';
import '../utils/constants.dart';

enum MqttState {
  initial,
  success,
  failure,
  noContent,
  connectionScreen,
  noInternet,
  pairedScreen,
}

class MqttViewModel extends ChangeNotifier {
  final MqttClientService _mqttClientService;
  MqttState _state = MqttState.initial;
  Map<String, dynamic> devicesinfo = deviceInfoMap;

  Map<String, dynamic>? _deviceInfo;

  Map<String, dynamic>? get deviceInfo => _deviceInfo;
  static const _channel = MethodChannel('com.example/device_info');

  MqttState get state => _state;
  String topic = "";

  Map<String, String?> macAddresses = {
    'wlan0': null,
    'eth0': null,
  };

  MqttViewModel(this._mqttClientService) {
    _mqttClientService.receivedMessageNotifier.addListener(_updateMessage);
    _fetchCurrentLocation();
    _initializeBasedOnPlatform();
    // _mqttConnection();
    _monitorConnectivity();
  }

  // Monitor connectivity changes and reinitialize MQTT on connection recovery
  void _monitorConnectivity() {
    InternetConnectionChecker().onStatusChange.listen((status) {
      final hasConnection = status == InternetConnectionStatus.connected;
      if (hasConnection) {
        _mqttConnection();
      } else {
        _state = MqttState.noInternet;
        notifyListeners();
      }
    });
  }

  Future<void> checkAndRequestPermissions() async {
    final status = await Permission.location.status;
    if (!status.isGranted) {
      await Permission.location.request();
    }
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
    } else {
      print("No MAC addresses found.");
    }
  }

  static Future<Map<String, dynamic>?> getListOfMacAddresses() async {
    final String? macAddressesJson =
        await _channel.invokeMethod('getListOfMacAddresses');
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
      devicesinfo!["platform"] = "iOS";

      print("datataatata${devicesinfo["uuid"] = identifier}");
      getDeviceInfo();
    } else if (Platform.isMacOS) {
      await getDeviceIdentifiersForMac();
    } else if (Platform.isWindows) {
      await getMotherboardSerialForMac();
    } else if (Platform.isLinux) {
      await getMotherboardSeriaForLinux();
    }
  }

  Future<void> getDeviceInfoAndroid() async {
    try {
      final String? result = await _channel.invokeMethod('getSystemData');
      if (result != null) {
        print("Device Info from Android: $result");
        // Parse the result if needed
        final Map<String, dynamic> deviceInfo = jsonDecode(result);
        devicesinfo["device_info"] = deviceInfo;
        notifyListeners();
      } else {
        print("Failed to get device info");
      }
    } on PlatformException catch (e) {
      print("Failed to get device info: '${e.message}'.");
    }
  }

  // Method to check and request location permissions
  Future<void> _checkAndRequestPermissions() async {
    final locationStatus = await Permission.location.status;
    if (!locationStatus.isGranted) {
      final result = await Permission.location.request();
      if (result.isDenied) {
        // Handle the case when the user denies the permission
        print('Location permission denied');
        return;
      }
    }
  }

  // Method to fetch the current location
  Future<void> _fetchCurrentLocation() async {
    try {
      // Check and request location permissions
      await _checkAndRequestPermissions();

      // Get the current position
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // Update devicesinfo with latitude and longitude
      devicesinfo["latitude"] = position.latitude;
      devicesinfo["longitude"] = position.longitude;

      print(
          'Current Location: Latitude: ${position.latitude}, Longitude: ${position.longitude}');
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
        print("this is dzzata$deviceInfoMap");
      } else {
        _deviceInfo = null;
      }

      notifyListeners();
    } on PlatformException catch (e) {
      print("Failed to get device info: '${e.message}'.");
    }
  }

  Future<String?> getMotherboardSerialForMac() async {
    try {
      const platform = MethodChannel('com.example/motherboard_serial');

      final String? serial =
          await platform.invokeMethod('getMotherboardSerial');
      print("this is serial Port of Window$serial");
      return serial;
    } on PlatformException catch (e) {
      print("Failed to get motherboard serial number: '${e.message}'.");
      return null;
    }
  }

  Future<String?> getMotherboardSeriaForLinux() async {
    try {
      const platform = MethodChannel('com.example/motherboard_serial');

      final String? serial =
          await platform.invokeMethod('getMotherboardSerial');
      return serial;
    } on PlatformException catch (e) {
      print("Failed to get motherboard serial number: '${e.message}'.");
      return null;
    }
  }

  static Future<String?> getDeviceIdentifiersForMac() async {
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
      await _checkPairingStatus();
    } catch (error) {
      _state = MqttState.noInternet;
      notifyListeners();
      debugPrint("Error during MQTT reinitialization: $error");
    }
  }

  Future<void> _checkPairingStatus() async {
    Map<String, dynamic> requestBody;

    if (Platform.isAndroid) {
      requestBody = {
        "platform": "android",
        "macAddress": [
          {"mac": macAddresses['wlan0'], "interface": "wlan0"},
          {"mac": macAddresses['eth0'], "interface": "eth0"}
        ]
      };
    } else if (Platform.isIOS || Platform.isMacOS) {
      final uuid = Platform.isIOS
          ? await getDeviceIdentifiers()
          : await getDeviceIdentifiersForMac();
      requestBody = {"platform": "ios", "uuid": uuid ?? "unknown"};
    } else {
      debugPrint("Unsupported platform");
      return;
    }

    debugPrint("Request body: $requestBody");

    try {
      final response = await ApiRepository.sendPostRequest(
        requestBody,
        port,
        "player/connection/",
        null,
      );
      topic = response["player_code"];
      debugPrint("This is the response from the$topic API: $response");
      subsibeMessage(topic);
      publishMessage(jsonEncode(deviceInfoMap));
      if (response["paired"] == false) {
        _state = MqttState.noContent;
      } else if (response["paired"] == true) {
        _state = MqttState.pairedScreen;
      } else {
        _state = MqttState.failure;
      }
    } catch (error) {
      _state = MqttState.failure;
      debugPrint("Error: $error");
    }

    notifyListeners();
  }

  void subsibeMessage(String topic) {
    _mqttClientService.subscribe(topic);
  }

  void publishMessage(String message) {
    _mqttClientService.publish(topic,message);
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
