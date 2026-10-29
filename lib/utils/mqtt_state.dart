enum MqttState {
  initial,
  success,
  failure,
  noContent,
  campaignScreen,
  connectionScreen,
  noInternet,
  downloading,
  pairedScreen,
  playlistScreen,
  // PLAYER_STOP_REASON_CONTRACT: paired:false + action:"action_stop_player"
  // on a player/connection/ response. Distinct from pairedScreen (a
  // genuinely never-paired device) -- this player IS paired, just
  // temporarily stopped by the backend (licence/subscription/account
  // issue), so it must keep its cache and pairing state exactly as-is and
  // just stop showing content until the next poll comes back paired again.
  playerStopped,
}
