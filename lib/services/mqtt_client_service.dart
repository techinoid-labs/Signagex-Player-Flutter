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

  /// Guards against overlapping connect() calls racing each other and
  /// opening two live connections with two different client IDs — every
  /// caller in-flight shares this single attempt instead of starting a
  /// fresh one on top of it.
  Future<void>? _connectFuture;

  /// _client.updates is only safe to read once a connection has actually
  /// been established (it throws a null-check crash before that). We
  /// cancel and re-listen on every successful connect so there's never
  /// more than one active subscription, without ever touching .updates
  /// before the client is ready for it.
  StreamSubscription<List<MqttReceivedMessage<MqttMessage?>>?>?
      _updatesSubscription;

  /// The player code of the most recent connect, kept so presence can be
  /// republished after an automatic reconnect -- see _onAutoReconnected.
  String? _playerCode;

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
    // Republishing presence is the whole point of this callback, and it was
    // missing.
    //
    // The connect message registers a Last Will of {"status":"offline"},
    // RETAINED, on <playerCode>/player_status. When the connection dies --
    // which is what a laptop going to sleep does to it -- the broker
    // publishes that will, and because it is retained it becomes the
    // standing value of the topic. The CMS reads it and shows the screen
    // offline, correctly.
    //
    // Coming back is the part that never happened. resubscribeOnAutoReconnect
    // restores the SUBSCRIPTIONS, but nothing republishes the online status,
    // so the retained "offline" stayed the last word on that topic
    // indefinitely. Only restarting the app fixed it, because a fresh
    // connect runs _publishOnlineStatus -- which is exactly the reported
    // behaviour: sleep the Mac, the CMS says offline, and it stays offline
    // until the player is launched again.
    final code = _playerCode;
    if (code != null && code.isNotEmpty) {
      _publishOnlineStatus(code);
    }
  }

  // ────────────────────────────────
  // Connect - using wss://signagexai.com/mqtt
  // ────────────────────────────────
  /// [playerCode] configures MQTT presence tracking, matching the Android
  /// app: a retained Last Will of {"status":"offline"} on
  /// `{playerCode}/player_status`, published automatically by the broker
  /// if this client disconnects ungracefully, plus an explicit retained
  /// {"status":"online"} publish to the same topic once connected. Without
  /// this, the CMS's online/offline indicator never hears from the player
  /// at all — the player_logs/heartbeat messages are a separate mechanism
  /// the CMS's presence tracking doesn't watch.
  Future<void> connect({String? playerCode}) {
    final inFlight = _connectFuture;
    if (inFlight != null) {
      print('MQTT_LOGS:: connect() already in progress, awaiting it instead '
          'of starting a second connection');
      return inFlight;
    }
    final future = _connectInternal(playerCode);
    _connectFuture = future;
    // whenComplete() returns a NEW future that completes with the SAME error
    // as the one it wraps. That derived future was discarded, so every
    // failed connect produced an unhandled async error nobody was listening
    // to -- even though the caller dutifully catches the original future
    // returned below.
    //
    // An unhandled async error reaches PlatformDispatcher.onError, and on
    // the Windows build (where onError returned "not handled") the engine
    // tore the process down over it with STATUS_FAIL_FAST_EXCEPTION every
    // time a connect timed out -- the watchdog then restarted it, which is
    // what the "app keeps reopening" loop actually was. main.dart now
    // reports these as handled, but the orphan should not exist either way:
    // it turns every failed connect into engine-level error traffic for no
    // reason, and any zone that treats an uncaught error as fatal would do
    // the same thing here.
    //
    // catchError only silences the ORPHAN. The real error still propagates
    // to whoever awaits the future returned below.
    unawaited(future.whenComplete(() {
      if (identical(_connectFuture, future)) {
        _connectFuture = null;
      }
    }).catchError((Object _) {}));
    return future;
  }

  Future<void> _connectInternal(String? playerCode) async {
    if (playerCode != null && playerCode.isNotEmpty) {
      _playerCode = playerCode;
    }
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

      // Was 60 seconds, which is what made the "stuck on no internet"
      // report so much worse than it needed to be: the first attempt sat
      // for a full minute before reporting
      //   TimeoutException: Connection timeout - broker did not respond
      // while a plain HTTPS request to the same host from the same machine
      // at the same moment returned HTTP 200. So the network was fine and
      // the player still showed a no-internet screen for 60 seconds before
      // it could even begin to recover, and each retry cost another full
      // minute.
      //
      // 20s is well beyond a healthy WSS handshake -- a successful
      // connection completes in under a second -- while letting a failed
      // attempt be retried three times in the span the old value allowed
      // one.
      await _client.connect().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          print('MQTT_LOGS:: Connection timeout after 20 seconds');
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

  /// Throws the current client away and builds a brand-new one, so the next
  /// connect() starts from the same state a freshly-launched process would.
  ///
  /// Directly motivated by a captured failure: after the first connect timed
  /// out, retrying against this same _client made no progress, yet killing
  /// the process and relaunching it connected in UNDER A SECOND -- same
  /// machine, same network, seconds apart. The difference between those two
  /// paths is precisely this object: connect() reuses one _client for the
  /// life of the service (_initializeClient runs only in the constructor),
  /// so whatever state a timed-out attempt leaves behind -- a half-open
  /// WebSocket, mqtt5_client's own autoReconnect machinery spinning, a
  /// broker-side session still holding our client id -- is carried into
  /// every subsequent retry forever.
  ///
  /// Retrying the operation was never going to fix a poisoned object. This
  /// makes the retry path reproduce what actually worked.
  Future<void> resetClient() async {
    print('MQTT_LOGS:: resetClient(): discarding MQTT client and rebuilding');
    try {
      await _updatesSubscription?.cancel();
    } catch (_) {}
    _updatesSubscription = null;
    try {
      // Stop it resurrecting the dead socket while we are replacing it.
      _client.autoReconnect = false;
      _client.disconnect();
    } catch (_) {}
    // Drop any in-flight connect bookkeeping; it refers to the old client.
    _connectFuture = null;
    _initializeClient();
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
    // Message handling is wired up once per successful connect() (see
    // _connectInternal) — no listener registration here, so repeated
    // subscribe() calls don't pile up duplicate handlers for the same
    // message.
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
