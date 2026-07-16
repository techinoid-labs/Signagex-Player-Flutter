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

  Future<void>? _connectFuture;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage?>>?>?
      _updatesSubscription;

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
  // Overlapping calls share one in-flight attempt instead of racing a
  // second connection (which previously caused duplicate listeners/crashes).
  Future<void> connect({String? playerCode}) {
    final inFlight = _connectFuture;
    if (inFlight != null) {
      print('MQTT_LOGS:: connect() already in progress, awaiting it instead '
          'of starting a second connection');
      return inFlight;
    }
    final future = _connectInternal(playerCode);
    _connectFuture = future;
    future.whenComplete(() {
      if (identical(_connectFuture, future)) {
        _connectFuture = null;
      }
    });
    return future;
  }

  Future<void> _connectInternal(String? playerCode) async {
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

      if (playerCode != null && playerCode.isNotEmpty) {
        final willPayload = Uint8Buffer()
          ..addAll(utf8.encode(jsonEncode({'status': 'offline'})));
        connMessage
            .will()
            .withWillTopic('$playerCode/player_status')
            .withWillQos(MqttQos.atLeastOnce)
            .withWillRetain()
            .withWillPayload(willPayload);
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

          await _updatesSubscription?.cancel();
          _updatesSubscription = _client.updates
              .listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
            _handleReceivedMessage(c);
          });

          if (playerCode != null && playerCode.isNotEmpty) {
            _publishOnlineStatus(playerCode);
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

  void _publishOnlineStatus(String playerCode) {
    try {
      final buffer = Uint8Buffer()
        ..addAll(utf8.encode(jsonEncode({'status': 'online'})));
      _client.publishMessage(
        '$playerCode/player_status',
        MqttQos.atLeastOnce,
        buffer,
        retain: true,
      );
      print('MQTT_LOGS:: Published online status to $playerCode/player_status');
    } catch (e) {
      print('MQTT_LOGS:: Failed to publish online status: $e');
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
    // Message listener is registered once in connect()/_connectInternal(),
    // not here — registering it again on every subscribe() call created
    // duplicate listeners that each delivered every incoming message once.
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
