import 'package:flutter/material.dart';

import '../view_models/mqtt_provider.dart';

class MqttButtons extends StatelessWidget {
  final MqttProvider mqttProvider;

  MqttButtons({required this.mqttProvider});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ElevatedButton(
          onPressed: () {
            mqttProvider.subscribe('806116');
          },
          child: Text('Subscribe'),
        ),
        ElevatedButton(
          onPressed: () {
            mqttProvider.publish('806116', 'Hello MQTT');
          },
          child: Text('Publish'),
        ),
        ElevatedButton(
          onPressed: () {
            mqttProvider.disconnect();
          },
          child: Text('Disconnect'),
        ),
      ],
    );
  }
}
