import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:digital_signage/view_models/mqtt_view_model.dart';
import 'package:digital_signage/views/player_pairing_screen.dart';

class DigivisionView extends StatelessWidget {
  const DigivisionView({super.key});

  @override
  Widget build(BuildContext context) {
    final topic = context.select<MqttViewModel, String>((model) => model.topic);
    return PlayerPairingScreen(code: topic);
  }
}
