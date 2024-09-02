import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:digital_signage/widgets/connection_indicator.dart';
import 'package:digital_signage/widgets/mqtt_button.dart';

import '../view_models/mqtt_provider.dart';


class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final mqttProvider = Provider.of<MqttProvider>(context, listen: false);
      mqttProvider.init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mqttProvider = Provider.of<MqttProvider>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('MQTT Client')),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MqttStatusIndicator(isConnected: mqttProvider.isConnected),
          const SizedBox(height: 20),
          MqttButtons(mqttProvider: mqttProvider),
        ],
      ),
    );
  }
}
