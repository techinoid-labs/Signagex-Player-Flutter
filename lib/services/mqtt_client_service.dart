import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'package:digital_signage/utils/globle_variable.dart';

const String mqttBroker = 'broker.emqx.io';
const int mqttPort = 1883;

class MqttClientService {
  late MqttServerClient _client;
  final ValueNotifier<String> receivedMessageNotifier =
      ValueNotifier<String>('');
  // final PlaylistViewModel playlistViewModel = PlaylistViewModel();
  Function(String)? onMessageReceived;
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

    print('MQTT_LOGS:: client connecting....');
    _client.connectionMessage = connMessage;

    try {
      await _client.connect();
      if (_client.connectionStatus!.state == MqttConnectionState.connected) {
        print('MQTT_LOGS:: client connected');
      } else {
        print(
            'MQTT_LOGS::ERROR  client connection failed - disconnecting, status is ${_client.connectionStatus}');
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
      _handleReceivedMessage(c);
    });
  }

  void _handleReceivedMessage(List<MqttReceivedMessage<MqttMessage?>>? messages) {
    if (messages == null || messages.isEmpty) return;

    final recMess = messages[0].payload as MqttPublishMessage;
    final payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
    
    // Call the callback if it is set
    if (onMessageReceived != null) {
      onMessageReceived!(payload);  // Pass the message payload to the callback
    }

    receivedMessageNotifier.value = payload;
    print('MQTT_LOGS:: New data arrived payload is $payload');
    print('MQTT_LOGS:: New data arrived: topic ...$globleTopic.... <${messages[0].topic}>, payload is $payload');

    try {
      final jsonObj = jsonDecode(payload);
     
    } catch (e) {
      print('Failed to decode JSON: $e');
    }
  }
  void publish(String topic, String message) {
    var pubTopic = topic;
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);

    if (_client.connectionStatus?.state == MqttConnectionState.connected) {
      _client.publishMessage(pubTopic, MqttQos.atMostOnce, builder.payload!,
          retain: true);
      print('MQTT_LOGS:: Published message: $message');
    }
  }
}
