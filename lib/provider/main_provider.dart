import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../services/mqtt_client_service.dart';
import '../view_models/mqtt_view_model.dart';

class MqttProvider extends StatelessWidget {
  final Widget child;

  const MqttProvider({required this.child, Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<MqttViewModel>(
          create: (context) => MqttViewModel(MqttClientService()),
        ),
      ],
      child: child,
    );
  }
}
