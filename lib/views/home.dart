import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../view_models/mqtt_view_model.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MQTT Code'),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Data received:',
                style: TextStyle(color: Colors.black, fontSize: 25)),
            Consumer<MqttViewModel>(
              builder: (context, mqttViewModel, child) {
                return Text(
                  mqttViewModel.receivedMessage,
                  style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 10),
                );
              },
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Provider.of<MqttViewModel>(context, listen: false).publishMessage("Hello MQTT");
              },
              child: Text("Publish Message"),
            ),
          ],
        ),
      ),
    );
  }
}
