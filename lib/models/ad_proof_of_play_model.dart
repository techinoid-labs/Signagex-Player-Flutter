/// UTC timestamp matching API: `2026-05-22T20:27:05.000Z`
String formatProofOfPlayPlayedAt([DateTime? dateTime]) {
  final utc = (dateTime ?? DateTime.now()).toUtc();
  final y = utc.year.toString().padLeft(4, '0');
  final m = utc.month.toString().padLeft(2, '0');
  final d = utc.day.toString().padLeft(2, '0');
  final h = utc.hour.toString().padLeft(2, '0');
  final min = utc.minute.toString().padLeft(2, '0');
  final sec = utc.second.toString().padLeft(2, '0');
  final ms = utc.millisecond.toString().padLeft(3, '0');
  return '$y-$m-${d}T$h:$min:$sec.${ms}Z';
}

class AdProofOfPlayRequest {
  final String playerCode;
  final String adCampaignId;
  final String campaignId;
  final String adCampaignItemId;
  final String contentId;
  final String slotTimelineId;
  final String adZoneId;
  final int zoneId;
  final String zoneName;
  final String creativeName;
  final String creativeUrl;
  final String mediaType;
  final String status;
  final int durationSeconds;
  final int completionPercent;
  final String playedAt;
  final String? errorMessage;

  const AdProofOfPlayRequest({
    required this.playerCode,
    required this.adCampaignId,
    required this.campaignId,
    required this.adCampaignItemId,
    required this.contentId,
    required this.slotTimelineId,
    required this.adZoneId,
    required this.zoneId,
    required this.zoneName,
    required this.creativeName,
    required this.creativeUrl,
    required this.mediaType,
    required this.status,
    required this.durationSeconds,
    required this.completionPercent,
    required this.playedAt,
    this.errorMessage,
  });

  Map<String, dynamic> toJson() => {
        'player_code': playerCode,
        'ad_campaign_id': adCampaignId,
        'campaign_id': campaignId,
        'ad_campaign_item_id': adCampaignItemId,
        'content_id': contentId,
        'slot_timeline_id': slotTimelineId,
        'ad_zone_id': adZoneId,
        'zone_id': zoneId,
        'zone_name': zoneName,
        'creative_name': creativeName,
        'creative_url': creativeUrl,
        'media_type': mediaType,
        'status': status,
        'duration_seconds': durationSeconds,
        'completion_percent': completionPercent,
        'played_at': playedAt,
        'error_message': errorMessage ?? '',
      };

  // W17: round-trips through the exact same map toJson() already produces,
  // so a failed report can be persisted (SharedPreferences) and reconstructed
  // later for retry without a second, separately-maintained serialization.
  factory AdProofOfPlayRequest.fromJson(Map<String, dynamic> json) {
    return AdProofOfPlayRequest(
      playerCode: (json['player_code'] ?? '').toString(),
      adCampaignId: (json['ad_campaign_id'] ?? '').toString(),
      campaignId: (json['campaign_id'] ?? '').toString(),
      adCampaignItemId: (json['ad_campaign_item_id'] ?? '').toString(),
      contentId: (json['content_id'] ?? '').toString(),
      slotTimelineId: (json['slot_timeline_id'] ?? '').toString(),
      adZoneId: (json['ad_zone_id'] ?? '').toString(),
      zoneId: (json['zone_id'] as num?)?.toInt() ?? 0,
      zoneName: (json['zone_name'] ?? '').toString(),
      creativeName: (json['creative_name'] ?? '').toString(),
      creativeUrl: (json['creative_url'] ?? '').toString(),
      mediaType: (json['media_type'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
      completionPercent: (json['completion_percent'] as num?)?.toInt() ?? 0,
      playedAt: (json['played_at'] ?? '').toString(),
      errorMessage: (json['error_message'] as String?)?.isEmpty ?? true
          ? null
          : json['error_message'] as String,
    );
  }

  /// Identifies "the same reported play instance" for retry-queue dedup --
  /// slotTimelineId is the CMS's own per-scheduled-occurrence identifier;
  /// combined with status, two attempts to report the same outcome for the
  /// same slot instance collapse to one queued entry instead of piling up
  /// duplicates on every retry pass.
  String get dedupKey => '$slotTimelineId|$status';
}

bool isAdMediaType(String? mediaType) {
  final t = (mediaType ?? '').toLowerCase();
  return t == 'ad' ||
      t == 'ad_one' ||
      t == 'ad_slot' ||
      t.startsWith('ad/') ||
      t.startsWith('ad_');
}
