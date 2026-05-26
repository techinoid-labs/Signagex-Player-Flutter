import 'dart:convert';

import 'package:digital_signage/models/ad_proof_of_play_model.dart';

int? _asInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

String? _jsonStringField(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final v = json[key];
    if (v != null && v.toString().isNotEmpty) {
      return v.toString();
    }
  }
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

  factory CampaignData.fromJson(Map<String, dynamic> json) {
    final rawList = json["playerCampaigns"] ?? json["player_campaigns"];
    List<Campaign>? campaigns;
    if (rawList is List) {
      campaigns = List<Campaign>.from(
        rawList.map((x) => Campaign.fromJson(x as Map<String, dynamic>)),
      );
    }
    return CampaignData(
      success: json["success"],
      message: json["message"],
      playerCampaigns: campaigns,
    );
  }

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

  /// Full multi-zone layouts published with `composition_*` campaign id.
  bool get isCompositionLayout {
    final id = (campaignId ?? '').trim();
    if (id.startsWith('composition_')) return true;
    return (playbackType ?? '').toLowerCase() == 'composition';
  }

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

  /// Reads SignageX layout blob from media root or `settings.composition`.
  static Map<String, dynamic>? compositionMapFromJson(
    Map<String, dynamic> json,
  ) {
    final root = json['composition'];
    if (root is Map<String, dynamic>) return root;
    final settings = json['settings'];
    if (settings is Map<String, dynamic>) {
      final nested = settings['composition'];
      if (nested is Map<String, dynamic>) return nested;
    }
    return null;
  }

  static String? compositionIdFromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final id = (map['id'] ?? map['composition_id'] ?? '').toString().trim();
    if (id.isEmpty) return null;
    return id.startsWith('composition_') ? id : 'composition_$id';
  }

  static MediaItem? _mediaItemFromCompositionObject(
    Map<String, dynamic> obj,
    int index,
  ) {
    final type =
        (obj['type'] ?? obj['mediaType'] ?? 'content').toString().toLowerCase();
    final props = obj['properties'];
    final propMap =
        props is Map<String, dynamic> ? props : <String, dynamic>{};

    String mediaType;
    String? mediaUrl;
    Settings settings;

    switch (type) {
      case 'text':
        mediaType = 'text';
        mediaUrl = null;
        settings = Settings(
          text: propMap['text']?.toString() ?? obj['name']?.toString(),
          html: propMap['html']?.toString(),
          fontSize: _asInt(propMap['fontSize']),
          fontFamily: propMap['fontFamily']?.toString(),
          fill: propMap['fill']?.toString(),
          strokeWidth: _asInt(propMap['strokeWidth']),
          shadowBlur: _asInt(propMap['shadowBlur']),
          duration: _asInt(propMap['duration']),
        );
        break;
      case 'sticker':
        mediaType = 'sticker';
        mediaUrl = propMap['mediaUrl']?.toString();
        settings = Settings(
          remoteSrc: propMap['remoteSrc']?.toString() ??
              propMap['download_url']?.toString(),
          rotation: _asInt(propMap['rotation']),
          duration: _asInt(propMap['duration']),
        );
        break;
      case 'shape':
        mediaType = 'shape';
        mediaUrl = propMap['svg']?.toString() ??
            propMap['mediaUrl']?.toString() ??
            obj['mediaUrl']?.toString();
        settings = Settings(
          fill: propMap['fill']?.toString(),
          strokeWidth: _asInt(propMap['strokeWidth']),
          duration: _asInt(propMap['duration']),
        );
        break;
      default:
        final kind = (propMap['kind'] ?? obj['name'] ?? '').toString();
        mediaType = 'content';
        mediaUrl = _cleanMediaUrl(
          propMap['download_url'] ?? propMap['mediaUrl'] ?? obj['mediaUrl'],
        );
        settings = Settings(
          kind: kind,
          contentId: propMap['content_id']?.toString(),
          iframeSrc: propMap['iframeSrc']?.toString() ??
              propMap['iframe_src']?.toString(),
          duration: _asInt(propMap['duration']),
        );
        break;
    }

    return MediaItem(
      id: obj['id']?.toString() ?? 'composition_obj_$index',
      mediaType: mediaType,
      mediaUrl: mediaUrl,
      settings: settings,
      schedule: Schedule(alwaysPlay: true),
    );
  }

  /// Converts `composition.objects[]` (SignageX editor) into positioned zones.
  static List<CampaignZone>? zonesFromCompositionMap(
    Map<String, dynamic>? composition,
  ) {
    if (composition == null) return null;

    final fromZones = _zonesFromCampaignMap(composition);
    if (fromZones != null) return fromZones;

    final objects = composition['objects'];
    if (objects is! List || objects.isEmpty) return null;

    final zones = <CampaignZone>[];
    var zoneIndex = 0;
    for (final raw in objects) {
      if (raw is! Map<String, dynamic>) continue;
      zoneIndex++;
      final media = _mediaItemFromCompositionObject(raw, zoneIndex);
      if (media == null) continue;
      zones.add(
        CampaignZone(
          id: zoneIndex,
          x: _asInt(raw['x']),
          y: _asInt(raw['y']),
          width: _asInt(raw['width']),
          height: _asInt(raw['height']),
          mediaItems: [media],
        ),
      );
    }
    return zones.isEmpty ? null : zones;
  }

  static List<CampaignZone>? _zonesFromCampaignMap(Map<String, dynamic> map) {
    final zonesRaw = map['zones'];
    if (zonesRaw is List && zonesRaw.isNotEmpty) {
      return List<CampaignZone>.from(
        zonesRaw.map((x) => CampaignZone.fromJson(x as Map<String, dynamic>)),
      );
    }
    final playerCampaigns = map['playerCampaigns'];
    if (playerCampaigns is List && playerCampaigns.isNotEmpty) {
      final first = playerCampaigns.first;
      if (first is Map<String, dynamic>) {
        return _zonesFromCampaignMap(first);
      }
    }
    return null;
  }

  /// Parses nested layout zones for campaign/composition media items.
  static List<CampaignZone>? parseNestedZones(Map<String, dynamic> json) {
    final compositionMap = compositionMapFromJson(json);
    if (compositionMap != null) {
      final fromComposition = zonesFromCompositionMap(compositionMap);
      if (fromComposition != null) return fromComposition;
    }

    final fromData = json['data'];
    if (fromData is Map<String, dynamic>) {
      final nested = _zonesFromCampaignMap(fromData);
      if (nested != null) return nested;
    }

    final zonesRaw = json['zones'];
    if (zonesRaw is List && zonesRaw.isNotEmpty) {
      return List<CampaignZone>.from(
        zonesRaw.map((x) => CampaignZone.fromJson(x as Map<String, dynamic>)),
      );
    }

    final composition = json['composition'];
    if (composition is Map<String, dynamic>) {
      final nested = zonesFromCompositionMap(composition);
      if (nested != null) return nested;
    }

    for (final key in [
      'layout',
      'layoutData',
      'layout_data',
      'compositionLayout',
      'composition_layout',
      'playerCampaign',
      'player_campaign',
      'compositionCampaign',
      'composition_campaign',
      'nestedCampaign',
      'nested_campaign',
    ]) {
      final nested = json[key];
      if (nested is Map<String, dynamic>) {
        final zones = _zonesFromCampaignMap(nested);
        if (zones != null) return zones;
      }
    }

    final layers = json['layers'];
    if (layers is List && layers.isNotEmpty) {
      final first = layers.first;
      if (first is Map<String, dynamic> &&
          (first.containsKey('mediaItems') || first.containsKey('x'))) {
        return List<CampaignZone>.from(
          layers.map((x) => CampaignZone.fromJson(x as Map<String, dynamic>)),
        );
      }
    }

    final nestedMediaItems = json['mediaItems'];
    final type = (json['mediaType'] ?? '').toString().toLowerCase();
    if (nestedMediaItems is List &&
        nestedMediaItems.isNotEmpty &&
        (type == 'composition' || type == 'campaign')) {
      return [
        CampaignZone(
          id: _asInt(json['id']) ?? 1,
          x: 0,
          y: 0,
          width: _asInt(json['width']),
          height: _asInt(json['height']),
          mediaItems: List<MediaItem>.from(
            nestedMediaItems.map(
              (x) => MediaItem.fromJson(x as Map<String, dynamic>),
            ),
          ),
        ),
      ];
    }

    return null;
  }

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
    if ((mediaType?.toString().toLowerCase() == 'composition')) {
      settings = Settings.mergeCompositionFields(json, settings);
      final rootCompId = compositionCampaignIdFromJson(json, settings);
      if (rootCompId != null) {
        settings = Settings(
          duration: settings?.duration,
          transition: settings?.transition,
          ratio: settings?.ratio,
          volume: settings?.volume,
          loop: settings?.loop,
          otherMediaDefaultVolume: settings?.otherMediaDefaultVolume,
          isPaused: settings?.isPaused,
          html: settings?.html,
          text: settings?.text,
          fontSize: settings?.fontSize,
          fontFamily: settings?.fontFamily,
          fill: settings?.fill,
          strokeWidth: settings?.strokeWidth,
          shadowBlur: settings?.shadowBlur,
          kind: settings?.kind,
          contentId: settings?.contentId,
          rotation: settings?.rotation,
          remoteSrc: settings?.remoteSrc,
          iframeSrc: settings?.iframeSrc,
          compositionCampaignId: rootCompId,
          adCampaignId: settings?.adCampaignId,
          adCampaignItemId: settings?.adCampaignItemId,
          slotTimelineId: settings?.slotTimelineId,
          adZoneId: settings?.adZoneId,
          zoneName: settings?.zoneName,
          creativeName: settings?.creativeName,
          creativeUrl: settings?.creativeUrl,
          creativeMediaType: settings?.creativeMediaType,
        );
      }
    }

    return MediaItem(
      settings: settings,
      schedule: json["schedule"] == null
          ? null
          : Schedule.fromJson(json["schedule"]),
      mediaType: mediaType,
      mediaUrl: _cleanMediaUrl(json["mediaUrl"]),
      zones: parseNestedZones(json),
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

  // Web app iframe (content with kind web-app-iframe)
  String? iframeSrc;

  /// Links a composition media slot to a full composition campaign.
  String? compositionCampaignId;

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
    this.iframeSrc,
    this.compositionCampaignId,
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

  /// Merges composition link fields from media item root or nested settings.
  factory Settings.mergeCompositionFields(
    Map<String, dynamic> json,
    Settings? base,
  ) {
    final nested = base ??
        (json['settings'] is Map<String, dynamic>
            ? Settings.fromJson(json['settings'] as Map<String, dynamic>)
            : null);
    final compId = compositionCampaignIdFromJson(json, nested);
    if (compId == null) return nested ?? Settings();
    return Settings(
      duration: nested?.duration,
      transition: nested?.transition,
      ratio: nested?.ratio,
      volume: nested?.volume,
      loop: nested?.loop,
      otherMediaDefaultVolume: nested?.otherMediaDefaultVolume,
      isPaused: nested?.isPaused,
      html: nested?.html,
      text: nested?.text,
      fontSize: nested?.fontSize,
      fontFamily: nested?.fontFamily,
      fill: nested?.fill,
      strokeWidth: nested?.strokeWidth,
      shadowBlur: nested?.shadowBlur,
      kind: nested?.kind,
      contentId: nested?.contentId ??
          _jsonString(json, ['content_id', 'contentId']),
      rotation: nested?.rotation,
      remoteSrc: nested?.remoteSrc,
      iframeSrc: nested?.iframeSrc,
      compositionCampaignId: compId,
      adCampaignId: nested?.adCampaignId,
      adCampaignItemId: nested?.adCampaignItemId,
      slotTimelineId: nested?.slotTimelineId,
      adZoneId: nested?.adZoneId,
      zoneName: nested?.zoneName,
      creativeName: nested?.creativeName,
      creativeUrl: nested?.creativeUrl,
      creativeMediaType: nested?.creativeMediaType,
    );
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
      iframeSrc: nested?.iframeSrc ??
          _jsonString(json, ['iframeSrc', 'iframe_src']),
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
        iframeSrc: json["iframeSrc"] ?? json["iframe_src"],
        compositionCampaignId: compositionCampaignIdFromJson(json, null),
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
        "iframeSrc": iframeSrc,
        "composition_campaign_id": compositionCampaignId,
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

/// Composition campaigns extracted from publish payload (not always top-level).
List<Campaign> globalCompositionCampaigns = [];

void setGlobalCompositionCampaigns(List<Campaign> campaigns) {
  globalCompositionCampaigns = List<Campaign>.from(campaigns);
}

String? compositionCampaignIdFromJson(
  Map<String, dynamic> json,
  Settings? settings,
) {
  final direct = _jsonStringField(json, [
    'composition_campaign_id',
    'compositionCampaignId',
    'composition_id',
    'compositionId',
    'layout_id',
    'layoutId',
  ]);
  if (direct != null && direct.isNotEmpty) return direct;

  final compMap = MediaItem.compositionMapFromJson(json);
  final fromComposition = MediaItem.compositionIdFromMap(compMap);
  if (fromComposition != null) return fromComposition;

  final nested = settings?.compositionCampaignId?.trim();
  if (nested != null && nested.isNotEmpty) return nested;

  final mediaUrl = (json['mediaUrl'] ?? settings?.creativeUrl ?? '')
      .toString()
      .trim();
  if (mediaUrl.startsWith('composition_')) return mediaUrl;

  final contentId = _jsonStringField(json, ['content_id', 'contentId']) ??
      settings?.contentId?.trim();
  if (contentId != null && contentId.isNotEmpty) {
    return 'composition_$contentId';
  }
  return null;
}

bool _isCompositionCampaignMap(Map<String, dynamic> map) {
  final id = (map['campaign_id'] ?? map['campaignId'] ?? '').toString();
  if (id.startsWith('composition_')) return true;
  final pt = (map['playback_type'] ?? map['playbackType'] ?? '')
      .toString()
      .toLowerCase();
  return pt == 'composition';
}

Campaign? _campaignFromCompositionMediaMap(Map<String, dynamic> json) {
  final zones = MediaItem.parseNestedZones(json);
  if (zones == null || zones.isEmpty) return null;

  final compMap = MediaItem.compositionMapFromJson(json);
  final compId = compositionCampaignIdFromJson(json, null) ??
      MediaItem.compositionIdFromMap(compMap) ??
      'composition_${json['id'] ?? 'embedded'}';

  Map<String, dynamic>? resolutionMap;
  final res = json['resolution'];
  if (res is Map<String, dynamic>) {
    resolutionMap = res;
  } else if (compMap != null) {
    resolutionMap = {
      'width': compMap['width'],
      'height': compMap['height'],
    };
  } else {
    final layout = json['composition'] ?? json['layout'];
    if (layout is Map<String, dynamic>) {
      final layoutRes = layout['resolution'];
      if (layoutRes is Map<String, dynamic>) resolutionMap = layoutRes;
    }
  }

  return Campaign(
    playbackType: 'campaign',
    campaignId: compId,
    campaignName: (compMap?['name'] ??
            json['composition_name'] ??
            json['campaign_name'] ??
            json['name'] ??
            'Composition')
        .toString(),
    resolution: resolutionMap == null
        ? null
        : Resolution.fromJson(resolutionMap),
    campaignSchedule: json['campaign_schedule'] is Map<String, dynamic>
        ? CampaignSchedule.fromJson(
            json['campaign_schedule'] as Map<String, dynamic>,
          )
        : CampaignSchedule(alwaysPlay: true),
    zones: zones,
  );
}

void _collectCompositionCampaignsFromJson(
  dynamic node,
  List<Campaign> out,
) {
  if (node is Map<String, dynamic>) {
    if (_isCompositionCampaignMap(node)) {
      out.add(Campaign.fromJson(node));
    }

    final mt = (node['mediaType'] ?? node['media_type'] ?? '')
        .toString()
        .toLowerCase();
    if (mt == 'composition') {
      final embedded = _campaignFromCompositionMediaMap(node);
      if (embedded != null) {
        out.add(embedded);
      }
    }

    for (final value in node.values) {
      _collectCompositionCampaignsFromJson(value, out);
    }
  } else if (node is List) {
    for (final item in node) {
      _collectCompositionCampaignsFromJson(item, out);
    }
  }
}

int _campaignZoneCount(Campaign c) => c.zones?.length ?? 0;

List<Campaign> _dedupeCampaignsById(List<Campaign> campaigns) {
  final byId = <String, Campaign>{};
  for (final c in campaigns) {
    final id = c.campaignId?.trim();
    if (id == null || id.isEmpty) continue;
    final existing = byId[id];
    if (existing == null ||
        _campaignZoneCount(c) > _campaignZoneCount(existing)) {
      byId[id] = c;
    }
  }
  return byId.values.toList();
}

List<Campaign> _mergeCompositionPlaceholders(List<Campaign> campaigns) {
  // Use global registry for linking (includes extracted compositions)
  final compositions = globalCompositionCampaigns.isNotEmpty
      ? globalCompositionCampaigns
      : campaigns.where((c) => c.isCompositionLayout).toList();
  if (compositions.isEmpty) return campaigns;

  return campaigns.map((campaign) {
    final zones = campaign.zones;
    if (zones == null) return campaign;

    var changed = false;
    final updatedZones = zones.map((zone) {
      final items = zone.mediaItems;
      if (items == null) return zone;

      final updatedItems = items.map((media) {
        if ((media.mediaType ?? '').toLowerCase() != 'composition') {
          return media;
        }
        if (media.zones != null && media.zones!.isNotEmpty) return media;

        var linked = findLinkedCompositionCampaign(media, compositions);
        if (linked == null && compositions.length == 1) {
          linked = compositions.first;
        }
        if (linked?.zones == null || linked!.zones!.isEmpty) return media;

        changed = true;
        return MediaItem(
          id: media.id,
          settings: media.settings,
          schedule: media.schedule,
          mediaType: media.mediaType,
          mediaUrl: media.mediaUrl,
          zones: linked.zones,
        );
      }).toList();

      if (!changed) return zone;
      return CampaignZone(
        id: zone.id,
        x: zone.x,
        y: zone.y,
        width: zone.width,
        height: zone.height,
        mediaItems: updatedItems,
      );
    }).toList();

    return changed
        ? Campaign(
            playbackType: campaign.playbackType,
            campaignId: campaign.campaignId,
            campaignName: campaign.campaignName,
            resolution: campaign.resolution,
            campaignSchedule: campaign.campaignSchedule,
            campaignSettings: campaign.campaignSettings,
            zones: updatedZones,
            isPaused: campaign.isPaused,
          )
        : campaign;
  }).toList();
}

/// Normalizes publish_campaign payloads: extracts embedded compositions and dedupes.
CampaignResponse normalizeCampaignResponse(
  CampaignResponse model,
  Map<String, dynamic> raw,
) {
  final data = raw['data'];
  if (data is! Map<String, dynamic>) return model;

  // Extract compositions for linking (but don't add them as top-level campaigns)
  final extracted = <Campaign>[];
  _collectCompositionCampaignsFromJson(data, extracted);

  for (final key in [
    'compositions',
    'compositionCampaigns',
    'composition_campaigns',
    'compositionLayouts',
    'composition_layouts',
  ]) {
    final list = data[key];
    if (list is List) {
      for (final item in list) {
        if (item is Map<String, dynamic> && _isCompositionCampaignMap(item)) {
          extracted.add(Campaign.fromJson(item));
        }
      }
    }
  }

  // Get original campaigns from model
  final originalCampaigns = model.data?.playerCampaigns ?? const <Campaign>[];

  // Check if we have regular (non-composition) campaigns
  final hasRegularCampaigns =
      originalCampaigns.any((c) => !c.isCompositionLayout);

  // Register all compositions (extracted + original) for linking
  final allCompositions = <Campaign>[
    ...extracted,
    ...originalCampaigns.where((c) => c.isCompositionLayout),
  ];
  final dedupedCompositions = _dedupeCampaignsById(allCompositions);
  setGlobalCompositionCampaigns(dedupedCompositions);

  // If we have regular campaigns, don't add extracted compositions as top-level
  // They will be rendered inside their zones via linking
  final campaignsToUse = hasRegularCampaigns
      ? originalCampaigns.where((c) => !c.isCompositionLayout).toList()
      : (originalCampaigns.isEmpty ? extracted : originalCampaigns);

  final deduped = _dedupeCampaignsById(campaignsToUse);

  // Inject composition zones into composition media items
  final withEmbedded = _mergeCompositionPlaceholders(deduped);

  return CampaignResponse(
    action: model.action,
    sender: model.sender,
    data: CampaignData(
      success: model.data?.success,
      message: model.data?.message,
      playerCampaigns: withEmbedded,
    ),
  );
}

Campaign? findLinkedCompositionCampaign(
  MediaItem media,
  List<Campaign>? campaigns,
) {
  final all = <Campaign>[
    ...globalCompositionCampaigns,
    ...?(campaigns ?? const <Campaign>[]),
  ];
  if (all.isEmpty) return null;

  final linkId = media.settings?.compositionCampaignId?.trim();
  if (linkId != null && linkId.isNotEmpty) {
    for (final c in all) {
      if (c.campaignId == linkId) return c;
    }
    // Match composition_<uuid> when link is bare uuid.
    if (!linkId.startsWith('composition_')) {
      final prefixed = 'composition_$linkId';
      for (final c in all) {
        if (c.campaignId == prefixed) return c;
      }
    }
  }

  final contentId = media.settings?.contentId?.trim();
  if (contentId != null && contentId.isNotEmpty) {
    final prefixed = 'composition_$contentId';
    for (final c in all) {
      if (c.campaignId == prefixed || c.campaignId == contentId) return c;
    }
  }

  final compositions = all.where((c) => c.isCompositionLayout).toList();
  if (compositions.length == 1) return compositions.first;
  return null;
}

MediaItem resolveCompositionMediaItem(
  MediaItem media,
  List<Campaign>? campaigns,
) {
  final type = (media.mediaType ?? '').toLowerCase();
  if (type != 'composition') return media;
  if (media.zones != null && media.zones!.isNotEmpty) return media;

  final linked = findLinkedCompositionCampaign(media, campaigns);
  final zones = linked?.zones;
  if (zones == null || zones.isEmpty) return media;

  return MediaItem(
    id: media.id,
    settings: media.settings,
    schedule: media.schedule,
    mediaType: media.mediaType,
    mediaUrl: media.mediaUrl,
    zones: zones,
  );
}

bool mediaItemIsWebAppIframe(MediaItem media) {
  final kind = (media.settings?.kind ?? '').toLowerCase();
  return kind.contains('web-app') || kind.contains('web_app');
}

String mediaItemWebAppIframeUrl(MediaItem media) {
  final iframe = media.settings?.iframeSrc?.trim();
  if (iframe != null && iframe.isNotEmpty) return iframe;
  final url = media.mediaUrl?.trim() ?? '';
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  return '';
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
    final fallback = mediaType ?? '';
    if (isAdMediaType(fallback)) return 'image/jpeg';
    return fallback.isNotEmpty ? fallback : 'image/jpeg';
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
