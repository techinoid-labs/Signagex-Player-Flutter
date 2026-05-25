import 'dart:convert';

import 'package:digital_signage/models/ad_proof_of_play_model.dart';

int? _asInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

String? _cleanMediaUrl(dynamic value) {
  if (value == null) return null;
  var s = value.toString().trim();
  if (s.isEmpty) return s;

  final isInlineSvg =
      s.contains('<svg') || (s.startsWith('<') && s.contains('</svg>'));
  if (!isInlineSvg) {
    s = s.replaceAll('"', '');
    s = s.replaceAll(RegExp(r'%22[, ]*$'), '');
    s = s.replaceAll(RegExp(r'%22$'), '');
    s = s.replaceAll(RegExp(r'[, ]+$'), '');
  }
  return s;
}

CampaignResponse campaignResponseFromJson(String str) =>
    CampaignResponse.fromJson(json.decode(str));

String campaignResponseToJson(CampaignResponse data) =>
    json.encode(data.toJson());

class CampaignResponse {
  String? action;
  String? sender;
  CampaignData? data;

  CampaignResponse({
    this.action,
    this.sender,
    this.data,
  });

  factory CampaignResponse.fromJson(Map<String, dynamic> json) =>
      CampaignResponse(
        action: json["action"],
        sender: json["sender"],
        data: json["data"] == null ? null : CampaignData.fromJson(json["data"]),
      );

  Map<String, dynamic> toJson() => {
        "action": action,
        "sender": sender,
        "data": data?.toJson(),
      };
}

// ============================================
// CAMPAIGN DATA
// ============================================

class CampaignData {
  bool? success;
  String? message;
  List<Campaign>? playerCampaigns;

  CampaignData({
    this.success,
    this.message,
    this.playerCampaigns,
  });

  factory CampaignData.fromJson(Map<String, dynamic> json) => CampaignData(
        success: json["success"],
        message: json["message"],
        playerCampaigns: json["playerCampaigns"] == null
            ? null
            : List<Campaign>.from(
                json["playerCampaigns"].map((x) => Campaign.fromJson(x))),
      );

  Map<String, dynamic> toJson() => {
        "success": success,
        "message": message,
        "playerCampaigns": playerCampaigns == null
            ? null
            : List<dynamic>.from(playerCampaigns!.map((x) => x.toJson())),
      };
}

// ============================================
// CORE CAMPAIGN MODEL
// ============================================

class Campaign {
  String? playbackType;
  String? campaignId;
  String? campaignName;
  Resolution? resolution;
  CampaignSchedule? campaignSchedule;
  CampaignSettings? campaignSettings;
  List<CampaignZone>? zones;
  bool? isPaused;

  Campaign({
    this.playbackType,
    this.campaignId,
    this.campaignName,
    this.resolution,
    this.campaignSchedule,
    this.campaignSettings,
    this.zones,
    this.isPaused,
  });

  factory Campaign.fromJson(Map<String, dynamic> json) => Campaign(
        playbackType: json["playback_type"],
        campaignId: json["campaign_id"],
        campaignName: json["campaign_name"],
        resolution: json["resolution"] == null
            ? null
            : Resolution.fromJson(json["resolution"]),
        campaignSchedule: json["campaign_schedule"] == null
            ? null
            : CampaignSchedule.fromJson(json["campaign_schedule"]),
        campaignSettings: json["campaign_settings"] == null
            ? null
            : CampaignSettings.fromJson(json["campaign_settings"]),
        zones: json["zones"] == null
            ? null
            : List<CampaignZone>.from(
                json["zones"].map((x) => CampaignZone.fromJson(x))),
        isPaused: json["is_paused"],
      );

  Map<String, dynamic> toJson() => {
        "playback_type": playbackType,
        "campaign_id": campaignId,
        "campaign_name": campaignName,
        "resolution": resolution?.toJson(),
        "campaign_schedule": campaignSchedule?.toJson(),
        "campaign_settings": campaignSettings?.toJson(),
        "zones": zones == null
            ? null
            : List<dynamic>.from(zones!.map((x) => x.toJson())),
        "is_paused": isPaused,
      };
}

// ============================================
// CAMPAIGN STRUCTURE MODELS
// ============================================

class Resolution {
  int? width;
  int? height;

  Resolution({
    this.width,
    this.height,
  });

  factory Resolution.fromJson(Map<String, dynamic> json) => Resolution(
        // Handle both string and int values for width/height
        width: _asInt(json["width"]),
        height: _asInt(json["height"]),
      );

  Map<String, dynamic> toJson() => {
        "width": width,
        "height": height,
      };
}

class CampaignSchedule {
  bool? alwaysPlay;
  Period? period;
  List<Restriction>? restrictions;

  CampaignSchedule({
    this.alwaysPlay,
    this.period,
    this.restrictions,
  });

  factory CampaignSchedule.fromJson(Map<String, dynamic> json) =>
      CampaignSchedule(
        alwaysPlay: json["always_play"],
        period: json["period"] == null ? null : Period.fromJson(json["period"]),
        restrictions: json["restrictions"] == null
            ? null
            : List<Restriction>.from(
                json["restrictions"].map((x) => Restriction.fromJson(x))),
      );

  Map<String, dynamic> toJson() => {
        "always_play": alwaysPlay,
        "period": period?.toJson(),
        "restrictions": restrictions == null
            ? null
            : List<dynamic>.from(restrictions!.map((x) => x.toJson())),
      };
}

class CampaignSettings {
  String? transition;
  String? duration;
  bool? loop;

  CampaignSettings({
    this.transition,
    this.duration,
    this.loop,
  });

  factory CampaignSettings.fromJson(Map<String, dynamic> json) =>
      CampaignSettings(
        transition: json["transition"],
        duration:
            json["duration"]?.toString(), // Convert int to String if needed
        loop: json["loop"],
      );

  Map<String, dynamic> toJson() => {
        "transition": transition,
        "duration": duration,
        "loop": loop,
      };
}

class CampaignZone {
  int? id;
  int? x;
  int? y;
  int? width;
  int? height;
  List<MediaItem>? mediaItems;

  CampaignZone({
    this.id,
    this.x,
    this.y,
    this.width,
    this.height,
    this.mediaItems,
  });

  factory CampaignZone.fromJson(Map<String, dynamic> json) => CampaignZone(
      id: _asInt(json["id"]),
      x: _asInt(json["x"]),
      y: _asInt(json["y"]),
      width: _asInt(json["width"]),
      height: _asInt(json["height"]),
      mediaItems: json["mediaItems"] == null
          ? null
          : List<MediaItem>.from(
              json["mediaItems"].map((x) => MediaItem.fromJson(x))));

  Map<String, dynamic> toJson() => {
        "id": id,
        "x": x,
        "y": y,
        "width": width,
        "height": height,
        "mediaItems": mediaItems == null
            ? null
            : List<dynamic>.from(mediaItems!.map((x) => x.toJson())),
      };
}

// ============================================
// MEDIA MODELS
// ============================================

class MediaItem {
  Settings? settings;
  Schedule? schedule;
  String? mediaType;
  String? mediaUrl;
  List<CampaignZone>? zones; // For nested campaigns
  String? id;

  MediaItem({
    this.settings,
    this.schedule,
    this.mediaType,
    this.mediaUrl,
    this.zones,
    this.id,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) {
    final mediaType = json["mediaType"];
    Settings? settings = json["settings"] == null
        ? null
        : Settings.fromJson(json["settings"]);
    if (isAdMediaType(mediaType?.toString()) ||
        idLooksLikeAdSlot(json['id']?.toString())) {
      settings = Settings.mergeAdFields(json, settings);
      for (final key in [
        'ad',
        'adSlot',
        'ad_slot',
        'adData',
        'proofOfPlay',
        'proof_of_play',
      ]) {
        if (json[key] is Map<String, dynamic>) {
          settings = Settings.mergeAdFields(
            json[key] as Map<String, dynamic>,
            settings,
          );
        }
      }
    }
    return MediaItem(
      settings: settings,
      schedule: json["schedule"] == null
          ? null
          : Schedule.fromJson(json["schedule"]),
      mediaType: mediaType,
      mediaUrl: _cleanMediaUrl(json["mediaUrl"]),
      zones: json["zones"] == null
          ? null
          : List<CampaignZone>.from(
              json["zones"].map((x) => CampaignZone.fromJson(x))),
      id: json["id"],
    );
  }

  Map<String, dynamic> toJson() => {
        "settings": settings?.toJson(),
        "schedule": schedule?.toJson(),
        "mediaType": mediaType,
        "mediaUrl": mediaUrl,
        "zones": zones == null
            ? null
            : List<dynamic>.from(zones!.map((x) => x.toJson())),
        "id": id,
      };
}

class Settings {
  int? duration;
  String? transition;
  String? ratio;
  int? volume;
  bool? loop;
  int? otherMediaDefaultVolume;
  bool? isPaused;

  // Text-related fields
  String? html;
  String? text;
  int? fontSize;
  String? fontFamily;
  String? fill;
  int? strokeWidth;
  int? shadowBlur;

  // Content-related fields
  String? kind; // "image", "video/mp4", etc.
  String? contentId;

  // Shape-related fields
  int? rotation;

  // Sticker-related fields
  String? remoteSrc;

  // Ad campaign fields
  String? adCampaignId;
  String? adCampaignItemId;
  String? slotTimelineId;
  String? adZoneId;
  String? zoneName;
  String? creativeName;
  String? creativeUrl;
  String? creativeMediaType;

  Settings({
    this.duration,
    this.transition,
    this.ratio,
    this.volume,
    this.loop,
    this.otherMediaDefaultVolume,
    this.isPaused,
    this.html,
    this.text,
    this.fontSize,
    this.fontFamily,
    this.fill,
    this.strokeWidth,
    this.shadowBlur,
    this.kind,
    this.contentId,
    this.rotation,
    this.remoteSrc,
    this.adCampaignId,
    this.adCampaignItemId,
    this.slotTimelineId,
    this.adZoneId,
    this.zoneName,
    this.creativeName,
    this.creativeUrl,
    this.creativeMediaType,
  });

  static String? _jsonString(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final v = json[key];
      if (v != null && v.toString().isNotEmpty) {
        return v.toString();
      }
    }
    return null;
  }

  /// Merges ad proof-of-play fields from media item root or nested settings.
  factory Settings.mergeAdFields(
    Map<String, dynamic> json,
    Settings? base,
  ) {
    final nested = base ?? (json["settings"] is Map<String, dynamic>
        ? Settings.fromJson(json["settings"] as Map<String, dynamic>)
        : null);
    return Settings(
      duration: nested?.duration ?? _asInt(json["duration"]),
      transition: nested?.transition ?? json["transition"],
      ratio: nested?.ratio ?? json["ratio"],
      volume: nested?.volume ?? _asInt(json["volume"]),
      loop: nested?.loop ?? json["loop"],
      otherMediaDefaultVolume: nested?.otherMediaDefaultVolume ??
          _asInt(json["other_media_default_volume"]),
      isPaused: nested?.isPaused ?? json["is_paused"],
      html: nested?.html ?? json["html"],
      text: nested?.text ?? json["text"],
      fontSize: nested?.fontSize ?? _asInt(json["fontSize"]),
      fontFamily: nested?.fontFamily ?? json["fontFamily"],
      fill: nested?.fill ?? json["fill"],
      strokeWidth: nested?.strokeWidth ?? _asInt(json["strokeWidth"]),
      shadowBlur: nested?.shadowBlur ?? _asInt(json["shadowBlur"]),
      kind: nested?.kind ?? json["kind"],
      contentId: nested?.contentId ??
          _jsonString(json, ['content_id', 'contentId']),
      rotation: nested?.rotation ?? _asInt(json["rotation"]),
      remoteSrc: nested?.remoteSrc ?? json["remoteSrc"],
      adCampaignId: nested?.adCampaignId ??
          _jsonString(json, ['ad_campaign_id', 'adCampaignId']),
      adCampaignItemId: nested?.adCampaignItemId ??
          _jsonString(json, ['ad_campaign_item_id', 'adCampaignItemId']),
      slotTimelineId: nested?.slotTimelineId ??
          _jsonString(json, ['slot_timeline_id', 'slotTimelineId']),
      adZoneId: nested?.adZoneId ??
          _jsonString(json, ['ad_zone_id', 'adZoneId']),
      zoneName: nested?.zoneName ??
          _jsonString(json, ['zone_name', 'zoneName']),
      creativeName: nested?.creativeName ??
          _jsonString(json, ['creative_name', 'creativeName']),
      creativeUrl: nested?.creativeUrl ??
          _cleanMediaUrl(
            json["creative_url"] ??
                json["creativeUrl"] ??
                json["mediaUrl"],
          ),
      creativeMediaType: nested?.creativeMediaType ??
          _jsonString(json, [
            'creative_media_type',
            'creativeMediaType',
            'media_type',
            'mediaType',
          ]),
    );
  }

  factory Settings.fromJson(Map<String, dynamic> json) => Settings(
        duration: _asInt(json["duration"]),
        transition: json["transition"],
        ratio: json["ratio"],
        volume: _asInt(json["volume"]),
        loop: json["loop"] ?? false,
        otherMediaDefaultVolume: _asInt(json["other_media_default_volume"]),
        isPaused: json["is_paused"],
        html: json["html"],
        text: json["text"],
        fontSize: _asInt(json["fontSize"]),
        fontFamily: json["fontFamily"],
        fill: json["fill"],
        strokeWidth: _asInt(json["strokeWidth"]),
        shadowBlur: _asInt(json["shadowBlur"]),
        kind: json["kind"],
        contentId: json["content_id"],
        rotation: _asInt(json["rotation"]),
        remoteSrc: json["remoteSrc"],
        adCampaignId: json["ad_campaign_id"],
        adCampaignItemId: json["ad_campaign_item_id"],
        slotTimelineId: json["slot_timeline_id"],
        adZoneId: json["ad_zone_id"],
        zoneName: json["zone_name"],
        creativeName: json["creative_name"],
        creativeUrl: _cleanMediaUrl(json["creative_url"]),
        creativeMediaType:
            json["creative_media_type"] ?? json["media_type"],
      );

  Map<String, dynamic> toJson() => {
        "duration": duration,
        "transition": transition,
        "ratio": ratio,
        "volume": volume,
        "loop": loop ?? false,
        "other_media_default_volume": otherMediaDefaultVolume,
        "is_paused": isPaused,
        "html": html,
        "text": text,
        "fontSize": fontSize,
        "fontFamily": fontFamily,
        "fill": fill,
        "strokeWidth": strokeWidth,
        "shadowBlur": shadowBlur,
        "kind": kind,
        "content_id": contentId,
        "rotation": rotation,
        "remoteSrc": remoteSrc,
        "ad_campaign_id": adCampaignId,
        "ad_campaign_item_id": adCampaignItemId,
        "slot_timeline_id": slotTimelineId,
        "ad_zone_id": adZoneId,
        "zone_name": zoneName,
        "creative_name": creativeName,
        "creative_url": creativeUrl,
        "creative_media_type": creativeMediaType,
      };
}

bool isAdPlaybackCreativeId(String? id) {
  final s = (id ?? '').toLowerCase();
  return s.endsWith('_creative');
}

bool idLooksLikeAdSlot(String? id) {
  if (isAdPlaybackCreativeId(id)) return false;
  final s = (id ?? '').toLowerCase();
  return s.contains('adslot') || s.contains('ad_slot');
}

bool hasAdProofMetadata(Settings? settings) {
  if (settings == null) return false;
  return (settings.adCampaignId?.isNotEmpty ?? false) ||
      (settings.adZoneId?.isNotEmpty ?? false) ||
      (settings.slotTimelineId?.isNotEmpty ?? false) ||
      (settings.adCampaignItemId?.isNotEmpty ?? false);
}

extension MediaItemAdExtensions on MediaItem {
  /// Synthetic item from [playbackMedia]; must not re-enter ad-slot resolution.
  bool get isAdPlaybackCreative => isAdPlaybackCreativeId(id);

  bool get isAd {
    if (isAdPlaybackCreative) return false;
    return isAdMediaType(mediaType) ||
        idLooksLikeAdSlot(id) ||
        hasAdProofMetadata(settings);
  }

  static bool _isRemoteUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final u = url.toLowerCase();
    return u.startsWith('http://') || u.startsWith('https://');
  }

  /// Remote HTTPS URL for proof-of-play (never a local download path).
  String get adRemoteCreativeUrl {
    final fromSettings = settings?.creativeUrl;
    if (_isRemoteUrl(fromSettings)) return fromSettings!;
    if (_isRemoteUrl(mediaUrl)) return mediaUrl!;
    return fromSettings ?? mediaUrl ?? '';
  }

  String get adCreativeUrl {
    final remote = adRemoteCreativeUrl;
    if (remote.isNotEmpty) return remote;
    return mediaUrl ?? '';
  }

  String get adCreativeMediaType {
    final fromSettings = settings?.creativeMediaType ?? settings?.kind;
    if (fromSettings != null &&
        fromSettings.isNotEmpty &&
        !isAdMediaType(fromSettings)) {
      return fromSettings;
    }
    final url = adCreativeUrl.toLowerCase();
    if (url.endsWith('.mp4') || url.endsWith('.mov')) return 'video/mp4';
    if (url.endsWith('.webm')) return 'video/webm';
    if (url.endsWith('.jpg') ||
        url.endsWith('.jpeg') ||
        url.endsWith('.png') ||
        url.endsWith('.gif') ||
        url.endsWith('.webp')) {
      return 'image/jpeg';
    }
    return mediaType ?? 'image/jpeg';
  }

  String get adCreativeName =>
      settings?.creativeName ??
      adCreativeUrl.split('/').last.split('?').first;

  AdProofOfPlayRequest toProofOfPlayRequest({
    required String playerCode,
    required String campaignId,
    required int zoneId,
    required String status,
    int? completionPercent,
    String? errorMessage,
    DateTime? playedAt,
  }) {
    final s = settings;
    final durationSeconds = s?.duration ?? 0;
    final resolvedCompletion = completionPercent ??
        (status == 'completed' ? 100 : 0);

    return AdProofOfPlayRequest(
      playerCode: playerCode,
      adCampaignId: s?.adCampaignId ?? '',
      campaignId: campaignId,
      adCampaignItemId: s?.adCampaignItemId ?? id ?? '',
      contentId: s?.contentId ?? '',
      slotTimelineId: s?.slotTimelineId ?? '',
      adZoneId: s?.adZoneId ?? '',
      zoneId: zoneId,
      zoneName: s?.zoneName ?? 'Zone $zoneId',
      creativeName: adCreativeName,
      creativeUrl: adRemoteCreativeUrl,
      mediaType: adCreativeMediaType,
      status: status,
      durationSeconds: durationSeconds > 0 ? durationSeconds : 0,
      completionPercent: resolvedCompletion,
      playedAt: formatProofOfPlayPlayedAt(playedAt),
      errorMessage: errorMessage,
    );
  }

  /// Media item used for playback (image/video/web) inside an ad slot.
  /// Uses a distinct id so playback path does not re-trigger ad-slot logic.
  MediaItem get playbackMedia {
    if (!isAd) return this;
    final playbackType = adCreativeMediaType;
    return MediaItem(
      id: '${id ?? 'ad'}_creative',
      settings: settings,
      schedule: schedule,
      zones: zones,
      mediaType: playbackType,
      mediaUrl: adCreativeUrl,
    );
  }
}

class Schedule {
  bool? alwaysPlay;
  Period? period;
  List<Restriction>? restrictions;

  Schedule({
    this.alwaysPlay,
    this.period,
    this.restrictions,
  });

  factory Schedule.fromJson(Map<String, dynamic> json) => Schedule(
        alwaysPlay: json["always_play"],
        period: json["period"] == null ? null : Period.fromJson(json["period"]),
        restrictions: json["restrictions"] == null
            ? null
            : List<Restriction>.from(
                json["restrictions"].map((x) => Restriction.fromJson(x))),
      );

  Map<String, dynamic> toJson() => {
        "always_play": alwaysPlay,
        "period": period?.toJson(),
        "restrictions": restrictions == null
            ? null
            : List<dynamic>.from(restrictions!.map((x) => x.toJson())),
      };
}

// ============================================
// TIME/SCHEDULING MODELS
// ============================================

class Period {
  Days? days;
  Time? time;
  Date? date;

  Period({
    this.days,
    this.time,
    this.date,
  });

  factory Period.fromJson(Map<String, dynamic> json) => Period(
        days: json["days"] == null ? null : Days.fromJson(json["days"]),
        time: json["time"] == null ? null : Time.fromJson(json["time"]),
        date: json["date"] == null ? null : Date.fromJson(json["date"]),
      );

  Map<String, dynamic> toJson() => {
        "days": days?.toJson(),
        "time": time?.toJson(),
        "date": date?.toJson(),
      };
}

class Days {
  bool? monday;
  bool? tuesday;
  bool? wednesday;
  bool? thursday;
  bool? friday;
  bool? saturday;
  bool? sunday;

  Days({
    this.monday,
    this.tuesday,
    this.wednesday,
    this.thursday,
    this.friday,
    this.saturday,
    this.sunday,
  });

  factory Days.fromJson(Map<String, dynamic> json) => Days(
        monday: json["monday"],
        tuesday: json["tuesday"],
        wednesday: json["wednesday"],
        thursday: json["thursday"],
        friday: json["friday"],
        saturday: json["saturday"],
        sunday: json["sunday"],
      );

  Map<String, dynamic> toJson() => {
        "monday": monday,
        "tuesday": tuesday,
        "wednesday": wednesday,
        "thursday": thursday,
        "friday": friday,
        "saturday": saturday,
        "sunday": sunday,
      };
}

class Time {
  String? from;
  String? to;

  Time({
    this.from,
    this.to,
  });

  factory Time.fromJson(Map<String, dynamic> json) => Time(
        from: json["from"],
        to: json["to"],
      );

  Map<String, dynamic> toJson() => {
        "from": from,
        "to": to,
      };
}

class Date {
  String? start;
  String? end;

  Date({
    this.start,
    this.end,
  });

  factory Date.fromJson(Map<String, dynamic> json) => Date(
        start: json["start"],
        end: json["end"],
      );

  Map<String, dynamic> toJson() => {
        "start": start,
        "end": end,
      };
}

// ============================================
// RESTRICTION MODEL
// ============================================

class Restriction {
  String? type; // "date" or "time"
  String? operator; // "is-between", "on", "is-before", "is-after", "not-on"
  List<String>? values; // Array of values (1 or 2 depending on operator)

  Restriction({
    this.type,
    this.operator,
    this.values,
  });

  factory Restriction.fromJson(Map<String, dynamic> json) => Restriction(
        type: json["type"],
        operator: json["operator"],
        values: json["values"] == null
            ? null
            : List<String>.from(json["values"].map((x) => x.toString())),
      );

  Map<String, dynamic> toJson() => {
        "type": type,
        "operator": operator,
        "values":
            values == null ? null : List<dynamic>.from(values!.map((x) => x)),
      };
}

// ============================================
// LEGACY SUPPORT - Keep old class names for backward compatibility
// ============================================

// Alias for backward compatibility
typedef CampaignModel = CampaignResponse;
typedef Data = CampaignData;
typedef PlayerCampaign = Campaign;
typedef Zone = CampaignZone;

// Legacy factory functions
CampaignModel campaignModelFromJson(String str) =>
    CampaignResponse.fromJson(json.decode(str));

String campaignModelToJson(CampaignModel data) => json.encode(data.toJson());
