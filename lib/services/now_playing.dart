/// The `now_playing` report: what is on screen right now, published on the
/// player's own topic when it changes so the CMS "Playing Loop" shows it live
/// (backend mqtt-player.handler `now_playing`; Android NowPlaying.kt). The CMS
/// asks for the current state with `{"action":"request_now_playing"}`.
///
/// Linux reports at campaign level: the payload campaign key, its name, why it
/// is on screen and for how long. Child (media item) fields are null.
class NowPlaying {
  static const action = 'now_playing';
  static const requestAction = 'request_now_playing';
  static const interactivityPrefix = 'interactivity_';

  /// The key the CMS knows the item by (interactivity content is prefixed so
  /// it cannot collide with loop item ids, as on Android).
  static String keyFor(String campaignId, String? playbackType) =>
      playbackType == 'create_interactivity' &&
              !campaignId.startsWith(interactivityPrefix)
          ? '$interactivityPrefix$campaignId'
          : campaignId;

  static Map<String, dynamic> campaign({
    required String campaignId,
    String? name,
    String? playbackType,
    required String reason,
    required DateTime startedAt,
    int? durationSeconds,
    int? zoneCount,
    DateTime? sentAt,
  }) =>
      _message({
        'key': keyFor(campaignId, playbackType),
        'name': name,
        'reason': reason,
        'child_index': null,
        'child_id': null,
        'child_name': null,
        'media_url': null,
        'media_type': null,
        'started_at': startedAt.millisecondsSinceEpoch,
        'duration_s': durationSeconds,
        'zone_count': zoneCount,
      }, sentAt ?? DateTime.now());

  /// Nothing to show (no content, or every item outside its window).
  static Map<String, dynamic> noContent(DateTime startedAt, {DateTime? sentAt}) =>
      _message({
        'key': 'no_content',
        'name': null,
        'reason': 'no_content',
        'child_index': null,
        'child_id': null,
        'child_name': null,
        'media_url': null,
        'media_type': null,
        'started_at': startedAt.millisecondsSinceEpoch,
        'duration_s': null,
        'zone_count': null,
      }, sentAt ?? DateTime.now());

  static Map<String, dynamic> _message(Map<String, dynamic> data, DateTime sentAt) =>
      {
        'action': action,
        'sender': 'linux',
        'data': {...data, 'sent_at': sentAt.millisecondsSinceEpoch},
      };
}
