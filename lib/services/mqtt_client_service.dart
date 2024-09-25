import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'package:digital_signage/utils/globle_variable.dart';

const String mqttBroker = 'broker.emqx.io';
const int mqttPort = 1883;

class MqttClientService {
  late MqttServerClient _client;
  final ValueNotifier<String> receivedMessageNotifier =
      ValueNotifier<String>('');

  MqttClientService() {
    _initializeClient();
  }

  void _initializeClient() {
    _client = MqttServerClient.withPort(mqttBroker,
        'uniqueClientID_${DateTime.now().millisecondsSinceEpoch}', mqttPort);

    _client.logging(on: true);
    _client.onConnected = onConnected;
    _client.onDisconnected = onDisconnected;
    _client.onUnsubscribed = onUnsubscribed;
    _client.onSubscribed = onSubscribed;
    _client.onSubscribeFail = onSubscribeFail;
    _client.pongCallback = pong;
    _client.keepAlivePeriod = 60;
    _client.setProtocolV311();
  }

  void onConnected() {
    print('MQTT_LOGS:: Connected');
  }

  void onDisconnected() {
    print('MQTT_LOGS:: Disconnected');
  }

  void onSubscribed(String topic) {
    print('MQTT_LOGS:: Subscribed topic: $topic');
  }

  void onSubscribeFail(String topic) {
    print('MQTT_LOGS:: Failed to subscribe $topic');
  }

  void onUnsubscribed(String? topic) {
    print('MQTT_LOGS:: Unsubscribed topic: $topic');
  }

  void pong() {
    print('MQTT_LOGS:: Ping response client callback invoked');
  }

  Future<void> connect() async {
    final connMessage = MqttConnectMessage()
        .withWillTopic('willtopic')
        .withWillMessage('Will message')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);

    print('MQTT_LOGS::Mosquitto client connecting....');
    _client.connectionMessage = connMessage;

    try {
      await _client.connect();
      if (_client.connectionStatus!.state == MqttConnectionState.connected) {
        print('MQTT_LOGS::Mosquitto client connected');
      } else {
        print(
            'MQTT_LOGS::ERROR Mosquitto client connection failed - disconnecting, status is ${_client.connectionStatus}');
        _client.disconnect();
      }
    } catch (e) {
      print('Exception: $e');
      _client.disconnect();
    }
  }

  void disconnect() {
    if (_client.connectionStatus?.state == MqttConnectionState.connected) {
      _client.disconnect();
      print('MQTT_LOGS:: Disconnected');
    }
  }

  void subscribe(String topic) {
    print('MQTT_LOGS:: Subscribing to the topic: $topic');
    _client.subscribe(topic, MqttQos.atMostOnce);

    _client.updates?.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
      final recMess = c![0].payload as MqttPublishMessage;
      final pt =
          MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
      receivedMessageNotifier.value = pt;
      print(
          'MQTT_LOGS:: New data arrived: topic ...$globleTopic.... <${c[0].topic}>, payload is $pt');
      final jsonObj = jsonDecode(pt);

      if (jsonObj["action"] == "action_reboot") {
        print("action rebooot");
        if (Platform.isMacOS) {
          _rebootDeviceForMacOS();
        } else if (Platform.isAndroid) {
          print("i am here for andorind");
          rebootDeviceForAndroid();
        } else if (Platform.isWindows) {
          rebootDeviceForWindows();
        } else if (Platform.isLinux) {
          rebootDeviceForLinux();
        }
      }
    });
  }

  Future<String> rebootDeviceForLinux() async {
    print("Attempting to restart the device...");

    // Execute the reboot command
    final result = await Process.run('pkexec', ['systemctl', 'reboot']);

    print('Exit code: ${result.exitCode}');
    print('Stdout: ${result.stdout}');
    print('Stderr: ${result.stderr}');

    if (result.exitCode != 0) {
      return 'Error: ${result.stderr}';
    }

    return 'Reboot command executed successfully';
  }

  Future<void> rebootDeviceForWindows() async {
    try {
      publish(globleTopic, "success");
      final result = await Process.run(
          'powershell', ['-Command', 'Restart-Computer -Force']);

      if (result.exitCode != 0) {
        print('Error: ${result.stderr}');
      } else {
        print('Device is rebooting...');
      }
    } catch (e) {
      print('An error occurred: $e');
    }
  }

  Future<void> rebootDeviceForAndroid() async {
    print("reboot$globleTopic");
    try {
      publish(globleTopic, "success");
      await platform.invokeMethod('rebootDevice');
    } on PlatformException catch (e) {
      print("Failed to reboot device: ${e.message}");
    }
  }

  Future<void> _rebootDeviceForMacOS() async {
    try {
      publish(globleTopic, "success");
      final String result = await platformMacOS.invokeMethod('rebootDevice');
      print(result);
    } on PlatformException catch (e) {
      print("Failed to reboot the device: '${e.message}'.");
    }
  }

  void publish(String topic, String message) {
    var pubTopic = topic;
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);

    if (_client.connectionStatus?.state == MqttConnectionState.connected) {
      _client.publishMessage(pubTopic, MqttQos.atMostOnce, builder.payload!);
      print('MQTT_LOGS:: Published message: $message');
    }
  }
}
