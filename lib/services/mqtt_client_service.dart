import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';
import 'package:typed_data/typed_data.dart';

import 'package:digital_signage/utils/globle_variable.dart';

const String mqttBroker = 'signagexai.com';
const int mqttPort = 443;
const String mqttWebSocketPath = '/mqtt';

class MqttClientService {
  late MqttServerClient _client;
  final ValueNotifier<String> receivedMessageNotifier =
      ValueNotifier<String>('');

  Function(String)? onMessageReceived;

  MqttClientService() {
    _initializeClient();
  }

  void _initializeClient() {
    final fullUri = 'wss://$mqttBroker:$mqttPort$mqttWebSocketPath';
    _client = MqttServerClient.withPort(
      fullUri,
      'flutter_client_${DateTime.now().millisecondsSinceEpoch}',
      mqttPort,
    );

    _client.useWebSocket = true;
    _client.useAlternateWebSocketImplementation = true;
    _client.secure = false;

    _client.websocketProtocols = ['mqtt'];

    _client.keepAlivePeriod = 60;
    _client.logging(on: true);

    _client.autoReconnect = true;
    _client.resubscribeOnAutoReconnect = true;

    _client.onConnected = _onConnected;
    _client.onDisconnected = _onDisconnected;
    _client.onSubscribed = _onSubscribed;
    _client.onAutoReconnect = _onAutoReconnect;
    _client.onAutoReconnected = _onAutoReconnected;
  }

  // ────────────────────────────────
  // Callbacks
  // ────────────────────────────────
  void _onConnected() {
    print('MQTT_LOGS:: Connected callback fired');
    print('MQTT_LOGS:: Connection state: ${_client.connectionStatus?.state}');
  }

  void _onDisconnected() {
    print('MQTT_LOGS:: Disconnected callback fired');
    print('MQTT_LOGS:: Connection state: ${_client.connectionStatus?.state}');
    print(
        'MQTT_LOGS:: Disconnection origin: ${_client.connectionStatus?.disconnectionOrigin}');
    print('MQTT_LOGS:: Auto-reconnect enabled: ${_client.autoReconnect}');
  }

  void _onSubscribed(MqttSubscription subscription) {
    print('MQTT_LOGS:: Subscribed to topic: ${subscription.topic.rawTopic}');
  }

  void _onAutoReconnect() {
    print('MQTT_LOGS:: Auto-reconnecting...');
  }

  void _onAutoReconnected() {
    print('MQTT_LOGS:: Auto-reconnected successfully');
  }

  // ────────────────────────────────
  // Connect - using wss://signagexai.com/mqtt
  // ────────────────────────────────
  Future<void> connect() async {
    try {
      print(
          'MQTT_LOGS:: Connecting to wss://$mqttBroker:$mqttPort$mqttWebSocketPath');
      print('MQTT_LOGS:: Using mqtt5_client package with WSS');

      try {
        if (_client.connectionStatus?.state == MqttConnectionState.connected ||
            _client.connectionStatus?.state == MqttConnectionState.connecting) {
          _client.disconnect();
          await Future.delayed(const Duration(milliseconds: 500));
        }
      } catch (e) {}

      final connMessage = MqttConnectMessage()
          .withClientIdentifier(
              'flutter_client_${DateTime.now().millisecondsSinceEpoch}')
          .startClean();

      // Matches the working Android player's presence protocol: a Last Will
      // registered with the broker so it auto-publishes {"status":"offline"}
      // to <topic>/player_status the moment this client drops off
      // ungracefully (crash, power loss, network cut) -- this is what the
      // dashboard's Online/Offline actually reads. Without a will (the
      // previous state of this file), the backend had no way to ever learn
      // the player went offline except our own graceful disconnect, which
      // explains the stuck "Online" + "Sync Issue" combination reported in
      // the CMS.
      if (globleTopic.isNotEmpty) {
        final willPayload = Uint8Buffer();
        willPayload.addAll(utf8.encode(jsonEncode({'status': 'offline'})));
        connMessage
            .will()
            .withWillTopic('$globleTopic/player_status')
            .withWillPayload(willPayload)
            .withWillQos(MqttQos.atLeastOnce)
            .withWillRetain();
      }

      _client.connectionMessage = connMessage;

      print(
          'MQTT_LOGS:: Connecting via WSS to wss://$mqttBroker:$mqttPort$mqttWebSocketPath');
      print('MQTT_LOGS:: Client ID: ${connMessage.payload.clientIdentifier}');
      print('MQTT_LOGS:: WebSocket enabled: ${_client.useWebSocket}');
      print('MQTT_LOGS:: Secure: ${_client.secure}');

      // Connect with timeout
      await _client.connect().timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          print('MQTT_LOGS:: Connection timeout after 60 seconds');
          _client.disconnect();
          throw TimeoutException('Connection timeout - broker did not respond');
        },
      );

      int attempts = 0;
      const maxAttempts = 100;

      while (attempts < maxAttempts) {
        final connectionState = _client.connectionStatus?.state;

        if (connectionState == MqttConnectionState.connected) {
          print('MQTT_LOGS:: Successfully connected!');
          print('MQTT_LOGS:: Connection status: ${_client.connectionStatus}');

          _client.updates.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
            _handleReceivedMessage(c);
          });

          // Explicit "online" companion to the will registered above --
          // the will only fires on an *unexpected* drop, so we still need
          // to say "online" ourselves right after every successful connect
          // (including reconnects) for the dashboard to flip back from
          // whatever it last saw.
          if (globleTopic.isNotEmpty) {
            publish(
              '$globleTopic/player_status',
              jsonEncode({'status': 'online'}),
            );
          }

          return;
        } else if (connectionState == MqttConnectionState.faulted ||
            connectionState == MqttConnectionState.disconnected) {
          print('MQTT_LOGS:: Connection failed!');
          print('MQTT_LOGS:: State: $connectionState');
          print('MQTT_LOGS:: Connection status: ${_client.connectionStatus}');
          _client.disconnect();
          throw Exception('Failed to connect: State=$connectionState');
        }

        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }

      final finalState = _client.connectionStatus?.state;
      print('MQTT_LOGS:: Connection timeout, state: $finalState');
      _client.disconnect();
      throw Exception('Connection timeout: State=$finalState');
    } catch (e, st) {
      print('MQTT_LOGS:: Connection exception: $e');
      print('MQTT_LOGS:: Exception type: ${e.runtimeType}');
      if (_client.connectionStatus != null) {
        print('MQTT_LOGS:: Connection status: ${_client.connectionStatus}');
      }
      print('MQTT_LOGS:: Stack trace: $st');
      try {
        _client.disconnect();
      } catch (_) {}
      rethrow;
    }
  }

  void disconnect() {
    if (_client.connectionStatus?.state == MqttConnectionState.connected) {
      _client.disconnect();
      print('MQTT_LOGS:: Disconnected');
    }
  }

  void subscribe(String topic) {
    if (topic.isEmpty || topic.trim().isEmpty) {
      print('MQTT_LOGS:: Cannot subscribe - topic is empty');
      return;
    }
    print('MQTT_LOGS:: Subscribing to the topic: $topic');
    _client.subscribe(topic, MqttQos.atMostOnce);

    _client.updates.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
      _handleReceivedMessage(c);
    });
  }

  void _handleReceivedMessage(
      List<MqttReceivedMessage<MqttMessage?>>? messages) {
    if (messages == null || messages.isEmpty) return;

    final recMess = messages[0].payload as MqttPublishMessage;

    final payloadBytes = recMess.payload.message;
    if (payloadBytes == null) return;
    final payload = utf8.decode(payloadBytes.toList());

    if (onMessageReceived != null) {
      onMessageReceived!(payload);
    }

    receivedMessageNotifier.value = payload;
    print('MQTT_LOGS:: New data arrived payload is $payload');
    print(
        'MQTT_LOGS:: New data arrived: topic ...$globleTopic.... <${messages[0].topic}>, payload is $payload');

    try {
      jsonDecode(payload);
    } catch (e) {
      print('Failed to decode JSON: `$e');
    }
  }

  void publishMessage(String topic, Uint8List payload) {
    if (_client.connectionStatus!.state == MqttConnectionState.connected) {
      final Uint8Buffer buffer = Uint8Buffer();
      buffer.addAll(payload);

      _client.publishMessage(
        topic,
        MqttQos.atLeastOnce,
        buffer,
        retain: false,
      );

      print('Message published to topic: $topic');
    } else {
      print('Cannot publish: MQTT client not connected.');
    }
  }

  void publish(String topic, String message) {
    if (topic.isEmpty || topic.trim().isEmpty) {
      print('MQTT_LOGS:: Cannot publish - topic is empty');
      return;
    }
    if (_client.connectionStatus?.state == MqttConnectionState.connected) {
      // Convert string to Uint8Buffer
      final Uint8Buffer buffer = Uint8Buffer();
      buffer.addAll(utf8.encode(message));

      _client.publishMessage(
        topic,
        MqttQos.atMostOnce,
        buffer,
        retain: true,
      );
      print('MQTT_LOGS:: Published message to topic $topic: $message');
    } else {
      print('MQTT_LOGS:: Cannot publish - client not connected');
    }
  }

  bool get isConnected =>
      _client.connectionStatus?.state == MqttConnectionState.connected;
}
