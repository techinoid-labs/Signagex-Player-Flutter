import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
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
  ConnectivityResult _connectivityResult = ConnectivityResult.none;
  late final Connectivity _connectivity;
  static const _channel = MethodChannel('com.example/network');

  MqttState get state => _state;

  Map<String, String?> macAddresses = {
    'wlan0': null,
    'eth0': null,
  };

  MqttViewModel(this._mqttClientService) {
    _mqttClientService.receivedMessageNotifier.addListener(_updateMessage);
    _connectivity = Connectivity();
    _initializeBasedOnPlatform();
    _mqttConnection();
    _monitorConnectivity();
  }

  // Monitor connectivity changes and reinitialize MQTT on connection recovery
void _monitorConnectivity() {
  _connectivity.onConnectivityChanged.listen((List<ConnectivityResult> results) {
    // Assuming you're only interested in the first result for now
    if (results.isNotEmpty) {
      ConnectivityResult result = results.first;
      _connectivityResult = result;
      if (_connectivityResult != ConnectivityResult.none) {
        _mqttConnection();
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
    } else if (Platform.isIOS || Platform.isMacOS) {
      await getDeviceIdentifiers();
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
      final uuid = await getDeviceIdentifiers();
      requestBody = {"platform": "ios", "uuid": uuid ?? "unknown"};
    } else {
      debugPrint("Unsupported platform");
      return;
    }

    print("Request body: $requestBody");

    try {
      final response = await ApiRepository.sendPostRequest(
        requestBody,
        port,
        "player/connection/",
        null,
      );
      debugPrint("This is the response from the API: $response");
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

  void publishMessage(String message) {
    _mqttClientService.publish(message);
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
