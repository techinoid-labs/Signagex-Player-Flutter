import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:mqtt5_client/mqtt5_client.dart';
import 'package:mqtt5_client/mqtt5_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:typed_data/typed_data.dart';

import 'package:digital_signage/utils/debug_log.dart' as debug;
import 'package:digital_signage/utils/globle_variable.dart';

const String mqttBroker = 'signagexai.com';
const int mqttPort = 443;
const String mqttWebSocketPath = '/mqtt';

// Diagnostic-only file logger -- see debug_log.dart for why this exists
// (release-mode Windows exes are GUI-subsystem, print() output goes
// nowhere visible no matter how the exe is launched) and why it funnels
// through a shared write queue instead of writing directly.
Future<void> _debugLog(String message) =>
    debug.debugLog('MqttClientService', message);

class MqttClientService {
  late MqttServerClient _client;
  final ValueNotifier<String> receivedMessageNotifier =
      ValueNotifier<String>('');

  Function(String)? onMessageReceived;

  // Feeds the "connectivity" block of the resource_usage payload, mirroring
  // MqttClientHelper.getMqttStats() on the Android player.
  int successRequests = 0;
  int failedRequests = 0;
  final DateTime _serviceStartTime = DateTime.now();
  Duration _totalConnectedDuration = Duration.zero;
  DateTime? _connectedSince;

  int get timeConnectedPercent {
    final totalMs =
        DateTime.now().difference(_serviceStartTime).inMilliseconds;
    if (totalMs <= 0) return 0;
    var connectedMs = _totalConnectedDuration.inMilliseconds;
    if (_connectedSince != null) {
      connectedMs += DateTime.now().difference(_connectedSince!).inMilliseconds;
    }
    return ((connectedMs * 100) / totalMs).clamp(0, 100).round();
  }

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

  // W03: connect() and subscribe() used to each call _client.updates.listen()
  // on every invocation (duplicate-delivery bug, fixed by a boolean
  // "attached once" guard). But mqtt5_client replaces its subscriptions
  // manager -- and therefore the `updates` stream instance -- on every
  // connect() (verified directly against the mqtt5_client 4.5.3 source),
  // so a one-time-only boolean guard just traded "duplicate delivery" for
  // a worse bug: after any reconnect (this service's own connect() calls
  // _client.disconnect() then reconnects when already connected/
  // connecting, and mqtt5_client's own autoReconnect can trigger it too),
  // the *new* updates stream has no listener on it at all -- the old
  // subscription is still technically active, but on a stream object nothing
  // publishes to anymore. Messages (including publish_campaign and every
  // remote-view command) then silently stop arriving, while the socket
  // itself reconnects and looks perfectly healthy. Owning a real
  // StreamSubscription and re-attaching it -- cancelling the old one
  // first -- on every successful connect fixes both: never more than one
  // live listener, and never a stale one pointed at a replaced stream.
  StreamSubscription<List<MqttReceivedMessage<MqttMessage?>>?>?
      _updatesSubscription;

  // W03: serializes connect() calls -- a manual reconnect (e.g. from
  // _monitorConnectivity's connectivity-restore path) overlapping with
  // mqtt5_client's own autoReconnect, or two manual calls in quick
  // succession, used to interleave against the same _client instance with
  // no coordination at all.
  Future<void>? _connectingFuture;

  // ────────────────────────────────
  // Callbacks
  // ────────────────────────────────
  void _onConnected() {
    print('MQTT_LOGS:: Connected callback fired');
    print('MQTT_LOGS:: Connection state: ${_client.connectionStatus?.state}');
    _connectedSince = DateTime.now();
  }

  void _onDisconnected() {
    print('MQTT_LOGS:: Disconnected callback fired');
    print('MQTT_LOGS:: Connection state: ${_client.connectionStatus?.state}');
    print(
        'MQTT_LOGS:: Disconnection origin: ${_client.connectionStatus?.disconnectionOrigin}');
    print('MQTT_LOGS:: Auto-reconnect enabled: ${_client.autoReconnect}');
    if (_connectedSince != null) {
      _totalConnectedDuration +=
          DateTime.now().difference(_connectedSince!);
      _connectedSince = null;
    }
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

  // A laptop sleep/resume (or any drop severe enough that the broker's own
  // keepalive-timeout detection, not our own disconnect, is what notices)
  // used to leave the CMS stuck showing "offline" indefinitely -- not just
  // for the sleep duration itself. Every connect() call generated a BRAND
  // NEW client ID from the current timestamp, so on resume the app opened
  // an entirely new broker session and immediately published "online",
  // while the *old* (pre-sleep) session -- still registered under its own
  // timestamp ID, with its own Last Will still pending -- got detected as
  // dead by the broker on its own schedule and fired {"status":"offline"}
  // (retained) afterwards, silently overwriting the fresh "online" status.
  // Nothing corrected it until the next 30s heartbeat, and if it happened
  // again before that landed, it could look stuck for a lot longer.
  // Reconnecting with the SAME client ID every time means the broker
  // recognizes it as the same session and supersedes the old one outright,
  // instead of racing two independent sessions' Last Wills against each
  // other.
  String? _stableClientId;

  Future<String> _getStableClientId() async {
    if (_stableClientId != null) return _stableClientId!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('mqtt_stable_client_id');
    if (id == null || id.isEmpty) {
      final rand = Random();
      id = 'signagex_${List.generate(20, (_) => rand.nextInt(16).toRadixString(16)).join()}';
      await prefs.setString('mqtt_stable_client_id', id);
    }
    _stableClientId = id;
    return id;
  }

  // ────────────────────────────────
  // Connect - using wss://signagexai.com/mqtt
  // ────────────────────────────────
  Future<void> connect() {
    // W03: if a connect is already in flight, wait for that one instead of
    // starting a second, overlapping attempt against the same client.
    final inFlight = _connectingFuture;
    if (inFlight != null) return inFlight;
    final future = _connectInternal();
    _connectingFuture = future;
    future.whenComplete(() {
      if (identical(_connectingFuture, future)) _connectingFuture = null;
    });
    return future;
  }

  Future<void> _connectInternal() async {
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

      final clientId = await _getStableClientId();
      final connMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
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
          _debugLog('connect(): SUCCESS, will topic set for globleTopic="$globleTopic"');

          // W03: cancel any subscription from a previous connect before
          // attaching a new one -- the previous stream instance may
          // already be defunct (mqtt5_client replaces it on every
          // connect), and this guarantees exactly one live listener
          // either way.
          await _updatesSubscription?.cancel();
          _updatesSubscription = _client.updates
              .listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
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
      _debugLog('connect(): FAILED -- $e\n$st');
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

  // W03: "clean up subscriptions on dispose" -- call when this service is
  // being torn down for good (not on an ordinary reconnect, which is
  // handled entirely inside connect() above).
  Future<void> dispose() async {
    await _updatesSubscription?.cancel();
    _updatesSubscription = null;
    disconnect();
  }

  void subscribe(String topic) {
    if (topic.isEmpty || topic.trim().isEmpty) {
      print('MQTT_LOGS:: Cannot subscribe - topic is empty');
      return;
    }
    // Subscribe with the multi-level wildcard, matching the working Android
    // player's MqttClientHelper.subscribe ("$topic/#") -- subscribing to
    // the bare topic only receives messages published to that exact topic,
    // not to sub-topics like "$topic/remote" (where Remote View's
    // press_home/press_back/send_text/click commands actually arrive), so
    // this player was silently never receiving those at all.
    final wildcardTopic = '$topic/#';
    print('MQTT_LOGS:: Subscribing to the topic: $wildcardTopic');
    _client.subscribe(wildcardTopic, MqttQos.atMostOnce);
    _debugLog('subscribe($wildcardTopic)');

    // NOTE: _client.updates is listened to exactly once, guarded by
    // _updatesListenerAttached in connect()'s success branch -- do not add
    // another .listen() call here. See the comment on that field for why
    // (duplicate-delivery bug).
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
      successRequests++;
    } else {
      print('Cannot publish: MQTT client not connected.');
      failedRequests++;
    }
  }

  // The backend distinguishes messages by origin via this field -- the CMS
  // web dashboard tags its own outgoing messages "signagex_web", and expects
  // every message the player publishes back to be tagged "windows" so it can
  // resolve the MQTT round trip (pairing confirmation, remote actions, etc.)
  // against the right sender. Centralized here so every publish() call site
  // gets this right without having to remember to set it individually.
  String _withSenderTag(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic>) {
        decoded['sender'] = 'windows';
        return jsonEncode(decoded);
      }
    } catch (_) {}
    return message;
  }

  void publish(String topic, String message) {
    if (topic.isEmpty || topic.trim().isEmpty) {
      print('MQTT_LOGS:: Cannot publish - topic is empty');
      _debugLog('publish($topic): SKIPPED, topic is empty');
      return;
    }
    final taggedMessage = _withSenderTag(message);
    if (_client.connectionStatus?.state == MqttConnectionState.connected) {
      // Convert string to Uint8Buffer
      final Uint8Buffer buffer = Uint8Buffer();
      buffer.addAll(utf8.encode(taggedMessage));

      _client.publishMessage(
        topic,
        MqttQos.atMostOnce,
        buffer,
        retain: true,
      );
      print('MQTT_LOGS:: Published message to topic $topic: $taggedMessage');
      successRequests++;
      _debugLog('publish($topic): SENT, ${taggedMessage.length} bytes');
    } else {
      print('MQTT_LOGS:: Cannot publish - client not connected');
      failedRequests++;
      _debugLog(
          'publish($topic): FAILED -- client state is ${_client.connectionStatus?.state}, NOT actually sent');
    }
  }

  bool get isConnected =>
      _client.connectionStatus?.state == MqttConnectionState.connected;
}
