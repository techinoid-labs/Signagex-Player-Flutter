import 'dart:io';
import 'package:mqtt5_client/mqtt5_server_client.dart';
import 'package:digital_signage/utils/mqtt_state.dart';
import 'package:digital_signage/utils/player_recovery_policy.dart';
import 'package:digital_signage/services/mqtt_client_service.dart';
import 'package:flutter_test/flutter_test.dart';

class ConnectedMqtt extends MqttClientService {
  @override
  bool get isConnected => true;
}

void main() {
  test('Linux MQTT enforces a broker response deadline, including after reset', () async {
    final clients=<MqttServerClient>[];
    final service=MqttClientService(clientFactory:() {
      final client=MqttServerClient('localhost','test-${clients.length}');
      clients.add(client);
      return client;
    });
    await service.resetClient();
    expect(clients.length,2);
    for(final client in clients) {
      expect(client.keepAlivePeriod,Platform.isLinux ? 30 : 60);
      expect(client.disconnectOnNoResponsePeriod,Platform.isLinux ? 15 : 0);
    }
    expect(clients.first.autoReconnect,isFalse);
    expect(clients.last.autoReconnect,isTrue);
  });
  test('server outage retains cached campaign even after a connection state', () {
    for (final state in [MqttState.campaignScreen, MqttState.connectionScreen,
      MqttState.noInternet, MqttState.failure]) {
      expect(cachedStateAfterNetworkFailure(current: state, paired: true,
        hasCampaign: true, hasPlaylist: false), MqttState.campaignScreen);
    }
  });
  test('cached playlist survives outage; downloading is not interrupted', () {
    expect(cachedStateAfterNetworkFailure(current: MqttState.playlistScreen,
      paired: true, hasCampaign: false, hasPlaylist: true), MqttState.playlistScreen);
    expect(cachedStateAfterNetworkFailure(current: MqttState.downloading,
      paired: true, hasCampaign: true, hasPlaylist: false), MqttState.downloading);
  });
  test('network fallback does not bypass stop, unpair, or missing content', () {
    expect(cachedStateAfterNetworkFailure(current: MqttState.playerStopped,
      paired: true, hasCampaign: true, hasPlaylist: true), isNull);
    expect(cachedStateAfterNetworkFailure(current: MqttState.pairedScreen,
      paired: false, hasCampaign: true, hasPlaylist: true), isNull);
    expect(cachedStateAfterNetworkFailure(current: MqttState.connectionScreen,
      paired: true, hasCampaign: false, hasPlaylist: false), isNull);
  });
  test('connect on a healthy MQTT session completes without opening a socket', () async {
    final service = ConnectedMqtt();
    await service.connect().timeout(const Duration(milliseconds: 100));
    expect(service.isConnected, isTrue);
  });
}
