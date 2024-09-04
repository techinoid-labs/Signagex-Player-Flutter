import 'dart:convert';

import 'package:flutter/material.dart';

import '../view_models/mqtt_provider.dart';

class MqttButtons extends StatelessWidget {
  final MqttProvider mqttProvider;

  MqttButtons({required this.mqttProvider});
  Map<String, dynamic> body = {
    "success": "true",
    "action": 'jvjhjgvfj',
    "paired": "false",
    "player_code": "playerCode",
    "mac_address": "macAddressArray",
    "sender": 'norwinsol_web'
  };
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ElevatedButton(
          onPressed: () {
            mqttProvider.subscribe('85a1d2');
          },
          child: Text('Subscribe'),
        ),
        ElevatedButton(
          onPressed: () {
            mqttProvider.publish('85a1d2', jsonEncode(body));
          },
          child: Text('Publish'),
        ),
        ElevatedButton(
          onPressed: () {
            mqttProvider.disconnect();
          },
          child: Text('Disconnect'),
        ),
        ElevatedButton(
          onPressed: () {
            mqttProvider.connect(); // Connect or reconnect
          },
          child: Text('Connect'),
        ),
      ],
    );
  }
}
