/// On-demand playback (CMS "How to play it → Play on demand").
///
/// Content published with `play_mode: on_demand` is downloaded like any other
/// item but stays out of the normal rotation. The CMS plays it with
/// `{"action":"play_on_demand","data":{"campaign_id","repeat","mode"}}` and
/// stops it with `{"action":"stop_on_demand"}` (both not retained), as on
/// Android (PlayerViewModel.playOnDemand / stopOnDemand).
///
/// While one is active it is the only playable item, so the rotation keeps it
/// on screen. `repeat` is how many loops it plays; 0 means until stopped or
/// local midnight. Pure state, so the rules are unit-tested.
class OnDemandState {
  String? _campaignId;
  int? _playsLeft; // null = until stopped / midnight
  DateTime? _until;
  String _mode = 'play';

  String? get campaignId => _campaignId;
  String get mode => _mode;
  bool get active => _campaignId != null;

  bool isFor(String? campaignId) =>
      _campaignId != null && campaignId != null && campaignId == _campaignId;

  /// Starts playing [campaignId]. Returns false for a blank id.
  bool start(String? campaignId, int repeat, String mode, DateTime now) {
    final id = (campaignId ?? '').trim();
    if (id.isEmpty) return false;
    _campaignId = id;
    _mode = const {'play', 'queue', 'playqueue'}.contains(mode) ? mode : 'play';
    if (repeat <= 0) {
      _playsLeft = null;
      _until = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    } else {
      _playsLeft = repeat;
      _until = null;
    }
    return true;
  }

  void stop() {
    _campaignId = null;
    _playsLeft = null;
    _until = null;
    _mode = 'play';
  }

  /// One loop of the on-demand item started.
  void countPlay() {
    if (_playsLeft != null && _playsLeft! > 0) _playsLeft = _playsLeft! - 1;
  }

  /// Ends it once its loops are used up or midnight passed. Call before the
  /// rotation picks the next item. Returns true if it just ended.
  bool expireIfDone(DateTime now) {
    if (_campaignId == null) return false;
    final done = (_playsLeft != null && _playsLeft! <= 0) ||
        (_until != null && !now.isBefore(_until!));
    if (done) stop();
    return done;
  }

  /// Whether a campaign may be picked by the rotation right now: while an
  /// on-demand item is active, only that one; otherwise every item except
  /// on-demand ones.
  bool allows(String? campaignId, bool isOnDemand) =>
      _campaignId != null ? isFor(campaignId) : !isOnDemand;
}
