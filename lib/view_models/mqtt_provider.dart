import 'package:flutter/material.dart';

import 'package:mqtt_client/mqtt_client.dart';

import '../services/mqtt_client_service.dart';

class MqttProvider with ChangeNotifier {
  final MqttClientService _mqttClientService;
  bool _isConnected = false;

  MqttProvider(this._mqttClientService);

  bool get isConnected => _isConnected;

  Future<void> init() async {
    _mqttClientService.client.onConnected = _onConnected;
    _mqttClientService.client.onDisconnected = _onDisconnected;

    await _mqttClientService.connect();
  }

  void _onConnected() {
    _isConnected = true;
    notifyListeners();
  }

  void _onDisconnected() {
    _isConnected = false;
    notifyListeners();
  }

  Future<void> subscribe(String topic) async {
    if (_isConnected) {
      _mqttClientService.subscribe(topic, MqttQos.atMostOnce);
    }
  }

  Future<void> publish(String topic, String message) async {
    if (_isConnected) {
      _mqttClientService.publish(topic, message, MqttQos.exactlyOnce);
    }
  }

  Future<void> disconnect() async {
    _mqttClientService.disconnect();
  }
}
