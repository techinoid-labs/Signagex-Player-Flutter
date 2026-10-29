import 'mqtt_state.dart';

/// An unreachable server is not an authoritative stop/unpair response.
MqttState? cachedStateAfterNetworkFailure({
  required MqttState current,
  required bool paired,
  required bool hasCampaign,
  required bool hasPlaylist,
}) {
  if (!paired || current == MqttState.playerStopped) return null;
  if (current == MqttState.downloading) return current;
  if (hasCampaign) return MqttState.campaignScreen;
  if (hasPlaylist) return MqttState.playlistScreen;
  return null;
}
