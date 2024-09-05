import 'package:flutter/material.dart';

import '../services/mqtt_client_service.dart';

class MqttViewModel extends ChangeNotifier {
  final MqttClientService _mqttClientService;

  MqttViewModel(this._mqttClientService) {
    _mqttClientService.receivedMessageNotifier.addListener(_updateMessage);
    connect(); // Automatically connect when the ViewModel is initialized
  }

  String get receivedMessage => _mqttClientService.receivedMessageNotifier.value;

  MqttClientService get mqttClientService => _mqttClientService;

  Future<void> connect() async {
    await _mqttClientService.connect();
  }

  void publishMessage(String message) {
    _mqttClientService.publish(message);
  }

  void _updateMessage() {
    notifyListeners();
  }
}
