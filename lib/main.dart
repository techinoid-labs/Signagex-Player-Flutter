import 'package:flutter/material.dart';

import 'package:digital_signage/provider/main_provider.dart';
import 'package:digital_signage/views/home.dart';

void main() {
  runApp(MqttProvider(
    child: MaterialApp(
      home: HomeScreen(),
    ),
  ));
}
