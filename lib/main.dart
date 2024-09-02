import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:digital_signage/views/home.dart';

import '../view_models/mqtt_provider.dart';

import 'services/mqtt_client_service.dart';
import 'utils/constants.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final mqttClientService = MqttClientService(mqttBroker, mqttPort);
  final mqttProvider = MqttProvider(mqttClientService);

  await mqttProvider.init();

  runApp(
    ChangeNotifierProvider(
      create: (_) => mqttProvider,
      child: MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MQTT Client',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: HomeScreen(),
    );
  }
}
