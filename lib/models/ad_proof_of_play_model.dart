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

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
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
    };
    if (status == 'failed') {
      json['error_message'] = errorMessage ?? 'pending';
    }
    return json;
  }
}

/// Server requires at least [ad_campaign_id] on proof-of-play payloads.
bool canReportAdProofOfPlay(AdProofOfPlayRequest request) {
  return request.adCampaignId.trim().isNotEmpty;
}

/// Resolves API [error_message] for failed proof-of-play (e.g. `"pending"`).
String resolveAdProofOfPlayErrorMessage({
  String? errorMessage,
  String? skipReason,
  bool? skipPlayback,
}) {
  final reason = (skipReason ?? '').trim();
  if (reason.isNotEmpty) return reason;

  final message = (errorMessage ?? '').trim();
  if (message.isNotEmpty) {
    switch (message) {
      case 'outside_date_range':
      case 'outside_time_range':
      case 'no_flight_schedule':
      case 'empty_slot_skip_playback':
      case 'no_settings':
      case 'restrictions_failed':
      case 'campaign_not_allowed':
      case 'no_schedule_configured':
      case 'no_creative_url':
        return 'pending';
      default:
        return message;
    }
  }

  if (skipPlayback == true) return 'pending';
  return 'pending';
}

bool isAdMediaType(String? mediaType) {
  final t = (mediaType ?? '').toLowerCase();
  return t == 'ad' ||
      t == 'ad_one' ||
      t == 'ad_slot' ||
      t.startsWith('ad/') ||
      t.startsWith('ad_');
}
