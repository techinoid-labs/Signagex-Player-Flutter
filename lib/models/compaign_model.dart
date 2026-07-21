import 'dart:convert';

import 'package:digital_signage/models/ad_proof_of_play_model.dart';
import 'package:digital_signage/utils/agent_debug_log.dart';
import 'package:digital_signage/utils/constants.dart';

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
    if (v == null) continue;
    final s = v.toString().trim();
    if (s.isEmpty || s.toLowerCase() == 'null') continue;
    return s;
  }
  return null;
}

String? _cleanMediaUrl(dynamic value) {
  if (value == null) return null;
  var s = value.toString().trim();
  if (s.isEmpty) return s;

  if (MediaItem.isRawBase64ImagePayload(s)) return s;

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

String _mimeFromKind(String? kind) {
  final k = (kind ?? '').toLowerCase();
  if (k.contains('jpeg') || k.contains('jpg')) return 'image/jpeg';
  if (k.contains('gif')) return 'image/gif';
  if (k.contains('webp')) return 'image/webp';
  return 'image/png';
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

  factory CampaignZone.fromJson(Map<String, dynamic> json) {
    final mediaRaw = json["mediaItems"] ?? json["media_items"];
    return CampaignZone(
      id: _asInt(json["id"]),
      x: _asInt(json["x"]),
      y: _asInt(json["y"]),
      width: _asInt(json["width"]),
      height: _asInt(json["height"]),
      mediaItems: mediaRaw == null
          ? null
          : List<MediaItem>.from(
              (mediaRaw as List).map((x) => MediaItem.fromJson(x))),
    );
  }

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
    final properties = json['properties'];
    if (properties is Map<String, dynamic>) {
      final fromProps = properties['composition'];
      if (fromProps is Map<String, dynamic>) return fromProps;
    }
    final settings = json['settings'];
    if (settings is Map<String, dynamic>) {
      final nested = settings['composition'];
      if (nested is Map<String, dynamic>) return nested;
    }
    return null;
  }

  /// True for raw base64 image blobs (no `data:` prefix).
  static bool isRawBase64ImagePayload(String? value) {
    if (value == null) return false;
    final s = value.trim();
    if (s.length < 80) return false;
    if (s.startsWith('data:image') ||
        s.startsWith('http://') ||
        s.startsWith('https://') ||
        s.startsWith('file://') ||
        s.contains('<svg') ||
        s.contains('\n') && s.contains(' ')) {
      return false;
    }
    final sample = s.length > 128 ? s.substring(0, 128) : s;
    return RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(sample);
  }

  /// Wraps raw base64 as a `data:image/...;base64,...` URI for widgets.
  static String? normalizeImageMediaUrl(String? raw, {String? kind}) {
    if (raw == null || raw.isEmpty) return raw;
    final s = raw.trim();
    if (s.startsWith('data:image')) return s;
    if (s.startsWith('http://') ||
        s.startsWith('https://') ||
        s.startsWith('file://') ||
        RegExp(r'^[A-Za-z]:[/\\]').hasMatch(s)) {
      return s;
    }
    if (isRawBase64ImagePayload(s)) {
      return 'data:${_mimeFromKind(kind)};base64,$s';
    }
    return s;
  }

  static Map<String, dynamic> _objectJsonForCompositionDetect(
    Map<String, dynamic> obj,
    Map<String, dynamic> propMap,
  ) {
    final merged = Map<String, dynamic>.from(obj);
    if (propMap.isNotEmpty) {
      merged['properties'] = propMap;
      if (propMap['composition'] is Map<String, dynamic>) {
        merged['composition'] = propMap['composition'];
      }
      merged['settings'] = propMap;
    }
    return merged;
  }

  static bool objectLooksLikeNestedComposition(
    Map<String, dynamic> obj,
    Map<String, dynamic> propMap,
  ) {
    final type = (obj['type'] ?? obj['mediaType'] ?? obj['media_type'] ?? '')
        .toString()
        .toLowerCase();
    if (type == 'composition' || type == 'campaign') return true;

    final merged = _objectJsonForCompositionDetect(obj, propMap);
    if (compositionMapFromJson(merged) != null) return true;
    if (compositionCampaignIdFromJson(merged, null) != null) return true;

    final kind =
        (propMap['kind'] ?? obj['name'] ?? '').toString().toLowerCase();
    if (kind.contains('composition')) return true;

    final contentType =
        (propMap['content_type'] ?? propMap['contentType'] ?? '')
            .toString()
            .toLowerCase();
    if (contentType == 'composition' || contentType.contains('composition')) {
      return true;
    }

    final nestedCompId = propMap['composition_id'] ??
        propMap['compositionId'] ??
        propMap['nested_composition_id'] ??
        propMap['nestedCompositionId'] ??
        obj['composition_id'] ??
        obj['compositionId'];
    if (nestedCompId != null && nestedCompId.toString().trim().isNotEmpty) {
      return true;
    }

    final rawUrl = propMap['mediaUrl'] ??
        propMap['media_url'] ??
        obj['mediaUrl'] ??
        obj['media_url'];
    if (isRawBase64ImagePayload(rawUrl?.toString()) &&
        propMap['composition'] is Map<String, dynamic>) {
      return true;
    }

    return false;
  }

  static bool _zonesHaveNestedComposition(List<CampaignZone>? zones) {
    if (zones == null) return false;
    for (final z in zones) {
      for (final m in z.mediaItems ?? const <MediaItem>[]) {
        if ((m.mediaType ?? '').toLowerCase() == 'composition') return true;
      }
    }
    return false;
  }

  static String? compositionIdFromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final id = (map['id'] ?? map['composition_id'] ?? '').toString().trim();
    if (id.isEmpty) return null;
    return id.startsWith('composition_') ? id : 'composition_$id';
  }

  static Map<String, dynamic> _mergeShapeProps(
    Map<String, dynamic> obj,
    Map<String, dynamic> propMap,
  ) {
    final merged = Map<String, dynamic>.from(propMap);
    for (final key in [
      'fill',
      'stroke',
      'strokeColor',
      'strokeWidth',
      'stroke_width',
      'svg',
      'path',
      'd',
      'shapeType',
      'shape',
      'type',
      'objectType',
      'width',
      'height',
      'radius',
      'rx',
      'ry',
      'mediaUrl',
      'media_url',
      'points',
    ]) {
      if (obj[key] != null && !merged.containsKey(key)) {
        merged[key] = obj[key];
      }
    }
    return merged;
  }

  /// Builds inline SVG for editor shapes (rect, circle, path, etc.) when no URL is set.
  static String? svgFromShapeProperties(
    Map<String, dynamic> props, {
    int? width,
    int? height,
  }) {
    final existing = props['svg']?.toString() ?? '';
    if (existing.contains('<svg')) return existing;

    final url = _cleanMediaUrl(props['mediaUrl'] ?? props['media_url']);
    if (url != null && url.isNotEmpty && url.contains('<svg')) return url;

    final w = width ?? _asInt(props['width']) ?? 100;
    final h = height ?? _asInt(props['height']) ?? 100;
    final fill = props['fill']?.toString() ?? '#cccccc';
    final stroke =
        props['stroke']?.toString() ?? props['strokeColor']?.toString() ?? '';
    final strokeWidth =
        _asInt(props['strokeWidth'] ?? props['stroke_width']) ?? 0;
    final path = props['path']?.toString() ?? props['d']?.toString() ?? '';
    final points = props['points']?.toString() ?? '';

    final shapeType = (props['shapeType'] ??
            props['shape'] ??
            props['objectType'] ??
            props['type'] ??
            'rect')
        .toString()
        .toLowerCase();

    final strokeAttr = stroke.isNotEmpty && stroke != 'transparent'
        ? ' stroke="$stroke" stroke-width="$strokeWidth"'
        : (strokeWidth > 0 ? ' stroke-width="$strokeWidth"' : '');

    if (path.isNotEmpty) {
      return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" '
          'viewBox="0 0 $w $h"><path d="$path" fill="$fill"$strokeAttr/></svg>';
    }
    if (points.isNotEmpty) {
      return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" '
          'viewBox="0 0 $w $h"><polygon points="$points" fill="$fill"$strokeAttr/></svg>';
    }

    switch (shapeType) {
      case 'circle':
        final r = (w < h ? w : h) / 2;
        return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" '
            'viewBox="0 0 $w $h"><circle cx="${w / 2}" cy="${h / 2}" r="$r" '
            'fill="$fill"$strokeAttr/></svg>';
      case 'ellipse':
        return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" '
            'viewBox="0 0 $w $h"><ellipse cx="${w / 2}" cy="${h / 2}" '
            'rx="${w / 2}" ry="${h / 2}" fill="$fill"$strokeAttr/></svg>';
      case 'line':
        return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" '
            'viewBox="0 0 $w $h"><line x1="0" y1="0" x2="$w" y2="$h" '
            'stroke="${stroke.isNotEmpty ? stroke : fill}" stroke-width="${strokeWidth > 0 ? strokeWidth : 2}"/></svg>';
      case 'triangle':
        final p = '0,$h ${w / 2},0 $w,$h';
        return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" '
            'viewBox="0 0 $w $h"><polygon points="$p" fill="$fill"$strokeAttr/></svg>';
      case 'rect':
      case 'rectangle':
      default:
        return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" '
            'viewBox="0 0 $w $h"><rect width="$w" height="$h" fill="$fill"$strokeAttr/></svg>';
    }
  }

  static MediaItem? _mediaItemFromCompositionObject(
    Map<String, dynamic> obj,
    int index,
  ) {
    final type =
        (obj['type'] ?? obj['mediaType'] ?? obj['media_type'] ?? 'content')
            .toString()
            .toLowerCase();
    if (type == 'svg' || type == 'icon' || type == 'svg+xml') {
      return _mediaItemFromCompositionObject(
        {...obj, 'type': 'shape'},
        index,
      );
    }
    final props = obj['properties'];
    final propMap = props is Map<String, dynamic> ? props : <String, dynamic>{};

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
        final inlineSvg = propMap['svg']?.toString() ?? '';
        mediaUrl = _cleanMediaUrl(
          propMap['mediaUrl'] ??
              propMap['download_url'] ??
              propMap['downloadUrl'] ??
              propMap['url'] ??
              propMap['svgUrl'] ??
              (inlineSvg.startsWith('<svg') ? inlineSvg : null),
        );
        settings = Settings(
          remoteSrc: propMap['remoteSrc']?.toString() ??
              propMap['remote_src']?.toString() ??
              propMap['download_url']?.toString() ??
              propMap['downloadUrl']?.toString() ??
              propMap['url']?.toString() ??
              propMap['svgUrl']?.toString(),
          html: propMap['html']?.toString() ??
              (inlineSvg.startsWith('<svg') ? inlineSvg : null),
          rotation: _asInt(propMap['rotation']),
          duration: _asInt(propMap['duration']),
        );
        break;
      case 'composition':
      case 'campaign':
        mediaType = 'composition';
        Map<String, dynamic>? compMap;
        if (propMap['composition'] is Map<String, dynamic>) {
          compMap = propMap['composition'] as Map<String, dynamic>;
        } else if (obj['composition'] is Map<String, dynamic>) {
          compMap = obj['composition'] as Map<String, dynamic>;
        }
        final nestedZones = zonesFromCompositionMap(compMap) ??
            zonesFromCompositionMap(propMap);
        final compId = compositionCampaignIdFromJson(
              _objectJsonForCompositionDetect(obj, propMap),
              null,
            ) ??
            MediaItem.compositionIdFromMap(
              compMap is Map<String, dynamic> ? compMap : null,
            );
        settings = Settings(
          compositionCampaignId: compId,
          duration: _asInt(propMap['duration']),
        );
        var thumbUrl = _cleanMediaUrl(
          propMap['mediaUrl'] ?? propMap['media_url'] ?? obj['mediaUrl'],
        );
        if (nestedZones != null && nestedZones.isNotEmpty) {
          thumbUrl = null;
        } else if (isRawBase64ImagePayload(thumbUrl)) {
          thumbUrl = normalizeImageMediaUrl(
            thumbUrl,
            kind: propMap['kind']?.toString(),
          );
        }
        return MediaItem(
          id: obj['id']?.toString() ?? 'composition_obj_$index',
          mediaType: mediaType,
          mediaUrl: thumbUrl,
          settings: settings,
          schedule: Schedule(alwaysPlay: true),
          zones: nestedZones,
        );
      case 'shape':
        final mergedShape = _mergeShapeProps(obj, propMap);
        final zoneW = _asInt(obj['width']) ?? 100;
        final zoneH = _asInt(obj['height']) ?? 100;
        final builtSvg = svgFromShapeProperties(
          mergedShape,
          width: zoneW,
          height: zoneH,
        );
        mediaType = 'shape';
        mediaUrl = _cleanMediaUrl(
          builtSvg ??
              propMap['mediaUrl'] ??
              obj['mediaUrl'] ??
              propMap['svgUrl'] ??
              propMap['url'],
        );
        settings = Settings(
          fill: mergedShape['fill']?.toString(),
          strokeWidth: _asInt(mergedShape['strokeWidth']),
          kind: (mergedShape['shapeType'] ??
                  mergedShape['shape'] ??
                  mergedShape['type'])
              ?.toString(),
          duration: _asInt(mergedShape['duration']),
        );
        break;
      default:
        final looksNested = objectLooksLikeNestedComposition(obj, propMap);
        // #region agent log
        agentDebugLog(
          location: 'compaign_model.dart:_mediaItemFromCompositionObject',
          message: 'composition_object_parse',
          hypothesisId: 'H7',
          runId: 'post-fix',
          data: {
            'objectId': obj['id']?.toString(),
            'objectType': type,
            'looksNested': looksNested,
            'hasCompMap': propMap['composition'] != null,
            'contentId': propMap['content_id'] ?? obj['content_id'],
            'urlLen': (propMap['mediaUrl'] ?? obj['mediaUrl'] ?? '')
                .toString()
                .length,
            'isBase64': isRawBase64ImagePayload(
              (propMap['mediaUrl'] ?? obj['mediaUrl'])?.toString(),
            ),
          },
        );
        // #endregion
        if (looksNested) {
          return _mediaItemFromCompositionObject(
            {...obj, 'type': 'composition'},
            index,
          );
        }
        final kind = (propMap['kind'] ?? obj['name'] ?? '').toString();
        if (kind.toLowerCase().contains('sticker')) {
          return _mediaItemFromCompositionObject(
            {...obj, 'type': 'sticker'},
            index,
          );
        }
        mediaType = 'content';
        mediaUrl = normalizeImageMediaUrl(
          _cleanMediaUrl(
            propMap['download_url'] ??
                propMap['mediaUrl'] ??
                propMap['media_url'] ??
                obj['mediaUrl'],
          ),
          kind: kind,
        );
        settings = Settings(
          kind: kind,
          contentId: propMap['content_id']?.toString() ??
              propMap['contentId']?.toString() ??
              obj['content_id']?.toString(),
          compositionCampaignId: propMap['composition_id']?.toString() ??
              propMap['compositionId']?.toString() ??
              propMap['nested_composition_id']?.toString(),
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

  static String? _mediaTypeFromJson(Map<String, dynamic> json) {
    final raw = json['mediaType'] ?? json['media_type'];
    if (raw == null) return null;
    final t = raw.toString().toLowerCase();
    if (t == 'image/svg+xml') return 'sticker';
    if (t == 'svg+xml' || t == 'svg') return 'shape';
    return t;
  }

  /// True when media should render as an SVG sticker (HTML) — not editor shapes.
  static bool looksLikeSticker(MediaItem media) {
    final t = (media.mediaType ?? '').toLowerCase();
    if (t == 'shape') return false;
    if (t == 'sticker' || t == 'image/svg+xml') return true;
    final remote = media.settings?.remoteSrc ?? '';
    if (remote.endsWith('.svg')) return true;
    final kind = (media.settings?.kind ?? '').toLowerCase();
    return kind.contains('sticker');
  }

  static bool _shapeHasSvg(MediaItem media) {
    final url = media.mediaUrl ?? '';
    return url.contains('<svg');
  }

  static bool _zonesHaveRenderableShapes(List<CampaignZone>? zones) {
    if (zones == null) return false;
    for (final z in zones) {
      for (final m in z.mediaItems ?? const <MediaItem>[]) {
        if ((m.mediaType ?? '').toLowerCase() == 'shape' && _shapeHasSvg(m)) {
          return true;
        }
      }
    }
    return false;
  }

  static int _zoneMediaCount(List<CampaignZone>? zones) {
    if (zones == null) return 0;
    var n = 0;
    for (final z in zones) {
      n += z.mediaItems?.length ?? 0;
    }
    return n;
  }

  static bool _zonesHaveStickerLayers(List<CampaignZone>? zones) {
    if (zones == null) return false;
    for (final z in zones) {
      for (final m in z.mediaItems ?? const <MediaItem>[]) {
        if (looksLikeSticker(m)) return true;
      }
    }
    return false;
  }

  static List<CampaignZone>? _pickCompositionZones(
    List<CampaignZone>? embedded,
    List<CampaignZone>? linked,
  ) {
    if (linked == null || linked.isEmpty) return embedded;
    if (embedded == null || embedded.isEmpty) return linked;
    if (_zonesHaveNestedComposition(embedded) &&
        !_zonesHaveNestedComposition(linked)) {
      return embedded;
    }
    if (_zonesHaveRenderableShapes(linked) &&
        !_zonesHaveRenderableShapes(embedded)) {
      return linked;
    }
    if (_zonesHaveStickerLayers(linked) && !_zonesHaveStickerLayers(embedded)) {
      return linked;
    }
    if (linked.length > embedded.length) return linked;
    if (_zoneMediaCount(linked) > _zoneMediaCount(embedded)) return linked;
    return embedded;
  }

  static String? _mediaUrlFromJson(Map<String, dynamic> json) {
    return _cleanMediaUrl(json['mediaUrl'] ?? json['media_url']);
  }

  factory MediaItem.fromJson(Map<String, dynamic> json) {
    final mediaType = _mediaTypeFromJson(json);
    Settings? settings =
        json["settings"] == null ? null : Settings.fromJson(json["settings"]);
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

    final schedule = json['schedule'] == null
        ? Schedule(alwaysPlay: true)
        : Schedule.fromJson(json['schedule'] as Map<String, dynamic>);

    var mediaUrl = _mediaUrlFromJson(json);
    final typeLower = (mediaType ?? '').toLowerCase();
    if (typeLower == 'content' || typeLower.startsWith('image')) {
      mediaUrl = normalizeImageMediaUrl(
        mediaUrl,
        kind: settings?.kind ?? mediaType,
      );
    }
    if (typeLower == 'shape') {
      final built = svgFromShapeProperties(_mergeShapeProps(json, {}));
      if (built != null && built.isNotEmpty) {
        mediaUrl = _cleanMediaUrl(built);
      }
    }

    return MediaItem(
      settings: settings,
      schedule: schedule,
      mediaType: mediaType,
      mediaUrl: mediaUrl,
      zones: parseNestedZones(json),
      id: json['id']?.toString(),
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
  String? adFlightStartDate;
  String? adFlightEndDate;
  String? adFlightStartTime;
  String? adFlightEndTime;
  bool? adSkipPlayback;
  String? adSkipReason;

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
    this.adFlightStartDate,
    this.adFlightEndDate,
    this.adFlightStartTime,
    this.adFlightEndTime,
    this.adSkipPlayback,
    this.adSkipReason,
  });

  static String? _filenameFromUrl(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    final path = url.split('?').first;
    final name = path.split('/').last.trim();
    return name.isNotEmpty ? name : null;
  }

  static String? _jsonString(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final v = json[key];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isEmpty || s.toLowerCase() == 'null') continue;
      return s;
    }
    return null;
  }

  static bool? _readSkipPlayback(
    Map<String, dynamic> json,
    Map<String, dynamic>? firstItem,
  ) {
    for (final source in [json, if (firstItem != null) firstItem]) {
      if (source['skip_playback'] == true || source['skipPlayback'] == true) {
        return true;
      }
      if (source['skip_playback'] == false || source['skipPlayback'] == false) {
        return false;
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
      contentId:
          nested?.contentId ?? _jsonString(json, ['content_id', 'contentId']),
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
    final nested = base ??
        (json["settings"] is Map<String, dynamic>
            ? Settings.fromJson(json["settings"] as Map<String, dynamic>)
            : null);

    Map<String, dynamic>? firstItem;
    final items = json['items'];
    if (items is List && items.isNotEmpty && items.first is Map) {
      firstItem = Map<String, dynamic>.from(items.first as Map);
    }

    String? pickField(List<String> keys) {
      final fromJson = _jsonString(json, keys);
      if (fromJson != null && fromJson.isNotEmpty) return fromJson;
      if (firstItem != null) {
        return _jsonString(firstItem, keys);
      }
      return null;
    }

    String? pickUrl(List<String> keys) {
      final fromJson = _jsonString(json, keys);
      if (fromJson != null && fromJson.isNotEmpty) {
        return _cleanMediaUrl(fromJson);
      }
      if (firstItem != null) {
        final fromItem = _cleanMediaUrl(
          firstItem['mediaUrl'] ??
              firstItem['media_url'] ??
              firstItem['creative_url'] ??
              firstItem['creativeUrl'],
        );
        if (fromItem != null && fromItem.isNotEmpty) return fromItem;
      }
      return null;
    }

    return Settings(
      duration: nested?.duration ??
          _asInt(json['duration']) ??
          _asInt(json['duration_seconds']) ??
          _asInt(firstItem?['duration_seconds']),
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
      contentId: nested?.contentId ?? pickField(['content_id', 'contentId']),
      rotation: nested?.rotation ?? _asInt(json["rotation"]),
      remoteSrc: nested?.remoteSrc ?? json["remoteSrc"],
      iframeSrc:
          nested?.iframeSrc ?? _jsonString(json, ['iframeSrc', 'iframe_src']),
      adCampaignId:
          nested?.adCampaignId ?? pickField(['ad_campaign_id', 'adCampaignId']),
      adCampaignItemId: nested?.adCampaignItemId ??
          pickField(['ad_campaign_item_id', 'adCampaignItemId']),
      slotTimelineId: nested?.slotTimelineId ??
          pickField(['slot_timeline_id', 'slotTimelineId']),
      adZoneId: nested?.adZoneId ?? pickField(['ad_zone_id', 'adZoneId']),
      zoneName: nested?.zoneName ?? pickField(['zone_name', 'zoneName']),
      creativeName: nested?.creativeName ??
          pickField(['creative_name', 'creativeName', 'name']) ??
          _filenameFromUrl(pickUrl(['creative_url', 'creativeUrl', 'media_url', 'mediaUrl'])),
      creativeUrl: nested?.creativeUrl ??
          pickUrl(['creative_url', 'creativeUrl', 'media_url', 'mediaUrl']) ??
          _cleanMediaUrl(
            json["creative_url"] ?? json["creativeUrl"] ?? json["mediaUrl"],
          ),
      creativeMediaType: nested?.creativeMediaType ??
          pickField([
            'creative_media_type',
            'creativeMediaType',
            'media_type',
            'mediaType',
            'content_media_type',
            'contentMediaType',
          ]),
      adFlightStartDate:
          nested?.adFlightStartDate ?? pickField(['start_date', 'startDate']),
      adFlightEndDate:
          nested?.adFlightEndDate ?? pickField(['end_date', 'endDate']),
      adFlightStartTime:
          nested?.adFlightStartTime ?? pickField(['start_time', 'startTime']),
      adFlightEndTime:
          nested?.adFlightEndTime ?? pickField(['end_time', 'endTime']),
      adSkipPlayback:
          _readSkipPlayback(json, firstItem) ?? nested?.adSkipPlayback,
      adSkipReason:
          nested?.adSkipReason ?? pickField(['skip_reason', 'skipReason']),
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
        remoteSrc: json["remoteSrc"] ??
            json["remote_src"] ??
            json["download_url"] ??
            json["downloadUrl"],
        iframeSrc: json["iframeSrc"] ?? json["iframe_src"],
        compositionCampaignId: compositionCampaignIdFromJson(json, null),
        adCampaignId: json["ad_campaign_id"],
        adCampaignItemId: json["ad_campaign_item_id"],
        slotTimelineId: json["slot_timeline_id"],
        adZoneId: json["ad_zone_id"],
        zoneName: json["zone_name"],
        creativeName: json["creative_name"],
        creativeUrl: _cleanMediaUrl(json["creative_url"]),
        creativeMediaType: json["creative_media_type"] ?? json["media_type"],
        adFlightStartDate: json["start_date"] ?? json["startDate"],
        adFlightEndDate: json["end_date"] ?? json["endDate"],
        adFlightStartTime: json["start_time"] ?? json["startTime"],
        adFlightEndTime: json["end_time"] ?? json["endTime"],
        adSkipPlayback:
            json["skip_playback"] == true || json["skipPlayback"] == true,
        adSkipReason: json["skip_reason"] ?? json["skipReason"],
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
        "start_date": adFlightStartDate,
        "end_date": adFlightEndDate,
        "start_time": adFlightStartTime,
        "end_time": adFlightEndTime,
        "skip_playback": adSkipPlayback,
        "skip_reason": adSkipReason,
      };
}

bool isAdPlaybackCreativeId(String? id) {
  final s = (id ?? '').toLowerCase();
  return s.endsWith('_creative');
}

bool idLooksLikeAdSlot(String? id) {
  if (isAdPlaybackCreativeId(id)) return false;
  final s = (id ?? '').toLowerCase();
  if (s.isEmpty) return false;
  return s.contains('adslot') ||
      s.contains('ad_slot') ||
      s.contains('_adslot') ||
      RegExp(r'_ad[a-z]').hasMatch(s);
}

bool mediaItemIsAdSlot(MediaItem media) {
  return media.isAd || idLooksLikeAdSlot(media.id);
}

bool campaignPayloadContainsAdSlots(CampaignResponse? model) {
  final campaigns = model?.data?.playerCampaigns;
  if (campaigns == null) return false;
  for (final campaign in campaigns) {
    for (final zone in campaign.zones ?? const <CampaignZone>[]) {
      for (final media in zone.mediaItems ?? const <MediaItem>[]) {
        if (mediaItemIsAdSlot(media)) return true;
      }
    }
  }
  return false;
}

bool storedPayloadContainsAdSlots(Map<String, dynamic> raw) {
  final data = raw['data'];
  if (data is! Map<String, dynamic>) return false;
  final campaigns = data['playerCampaigns'] ?? data['player_campaigns'];
  if (campaigns is! List) return false;
  for (final campaign in campaigns) {
    if (campaign is! Map<String, dynamic>) continue;
    final zones = campaign['zones'];
    if (zones is! List) continue;
    for (final zone in zones) {
      if (zone is! Map<String, dynamic>) continue;
      final items = zone['mediaItems'] ?? zone['media_items'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map<String, dynamic>) continue;
        final id = item['id']?.toString();
        final type = item['mediaType'] ?? item['media_type'];
        if (isAdMediaType(type?.toString()) || idLooksLikeAdSlot(id)) {
          return true;
        }
      }
    }
  }
  return false;
}

bool hasAdProofMetadata(Settings? settings) {
  if (settings == null) return false;
  return (settings.adCampaignId?.isNotEmpty ?? false) ||
      (settings.adZoneId?.isNotEmpty ?? false) ||
      (settings.slotTimelineId?.isNotEmpty ?? false) ||
      (settings.adCampaignItemId?.isNotEmpty ?? false);
}

bool isAdCampaignUpdateMessage(String? message) {
  return (message ?? '').toLowerCase().contains('ad campaign update');
}

// Must return UTC DateTimes — evaluateAdSlotSchedule compares these
// against todayUtc (DateTime.utc(...)). The local-timezone DateTime(...)
// constructor previously used here made `2026-07-21` mean local midnight,
// which on a UTC+5 machine is actually 2026-07-20T19:00:00Z — nearly a
// full day earlier than intended, so a same-day flight window (e.g.
// start_date == end_date == today) could already read as "outside range"
// well before the day was over.
DateTime? _parseScheduleDateOnly(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final value = raw.trim();
  try {
    if (value.contains('T')) {
      // Take the calendar date exactly as written (e.g. the "2026-07-21"
      // portion of "2026-07-21T00:00:00") — do NOT convert timezones here,
      // that would shift the date itself across a day boundary depending
      // on the local offset. This field represents a calendar date, not a
      // precise instant.
      final parsed = DateTime.parse(value);
      return DateTime.utc(parsed.year, parsed.month, parsed.day);
    }
    final parts = value.split('-');
    if (parts.length == 3) {
      return DateTime.utc(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    }
    final parsed = DateTime.parse(value);
    return DateTime.utc(parsed.year, parsed.month, parsed.day);
  } catch (_) {
    return null;
  }
}

DateTime? _parseScheduleTimeToday(String? raw) {
  return _parseScheduleTimeOnDate(raw, DateTime.now());
}

/// Ad flight times from the API are UTC (same as proof-of-play timestamps).
DateTime? _parseScheduleTimeUtcToday(String? raw) {
  return _parseScheduleTimeOnDate(raw, DateTime.now().toUtc());
}

DateTime? _parseScheduleTimeOnDate(String? raw, DateTime anchor) {
  if (raw == null || raw.trim().isEmpty) return null;
  final parts = raw.trim().split(':');
  if (parts.length < 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  final second = parts.length > 2 ? int.tryParse(parts[2]) : 0;
  if (hour == null || minute == null) return null;
  final isUtc = anchor.isUtc;
  return isUtc
      ? DateTime.utc(
          anchor.year, anchor.month, anchor.day, hour, minute, second ?? 0)
      : DateTime(
          anchor.year, anchor.month, anchor.day, hour, minute, second ?? 0);
}

bool _isTimeInAdFlightWindow(
  DateTime now,
  DateTime startTime,
  DateTime endTime,
) {
  // Same-day window, e.g. 09:00 -> 17:00 (end inclusive)
  if (!endTime.isBefore(startTime)) {
    return !now.isBefore(startTime) && !now.isAfter(endTime);
  }
  // Overnight window, e.g. 14:20 -> 02:35 (next day)
  return !now.isBefore(startTime) || !now.isAfter(endTime);
}

/// Result of evaluating an ad slot against its flight schedule.
class AdSlotScheduleEvaluation {
  final bool hasCreative;
  final bool? inDateRange;
  final bool? inTimeRange;
  final bool skipPlayback;
  final bool shouldPlay;
  final String reason;

  const AdSlotScheduleEvaluation({
    required this.hasCreative,
    required this.inDateRange,
    required this.inTimeRange,
    required this.skipPlayback,
    required this.shouldPlay,
    required this.reason,
  });
}

AdSlotScheduleEvaluation evaluateAdSlotSchedule(MediaItem media) {
  final settings = media.settings;
  final hasCreative = media.adCreativeUrl.isNotEmpty;
  final skipPlayback = settings?.adSkipPlayback == true;

  if (settings == null) {
    return AdSlotScheduleEvaluation(
      hasCreative: hasCreative,
      inDateRange: null,
      inTimeRange: null,
      skipPlayback: skipPlayback,
      shouldPlay: false,
      reason: 'no_settings',
    );
  }

  // Empty slot: skip_playback marks server empty/pending slots.
  if (!hasCreative) {
    return AdSlotScheduleEvaluation(
      hasCreative: false,
      inDateRange: null,
      inTimeRange: null,
      skipPlayback: skipPlayback,
      shouldPlay: false,
      reason: skipPlayback ? 'empty_slot_skip_playback' : 'no_creative',
    );
  }

  final nowUtc = DateTime.now().toUtc();
  final startDate = _parseScheduleDateOnly(settings.adFlightStartDate);
  final endDate = _parseScheduleDateOnly(settings.adFlightEndDate);
  bool? inDateRange;
  if (startDate != null && endDate != null) {
    final todayUtc =
        DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
    inDateRange =
        !todayUtc.isBefore(startDate) && !todayUtc.isAfter(endDate);
    if (inDateRange == false) {
      return AdSlotScheduleEvaluation(
        hasCreative: true,
        inDateRange: false,
        inTimeRange: null,
        skipPlayback: skipPlayback,
        shouldPlay: false,
        reason: 'outside_date_range',
      );
    }
  }

  final startTime = _parseScheduleTimeUtcToday(settings.adFlightStartTime);
  final endTime = _parseScheduleTimeUtcToday(settings.adFlightEndTime);
  bool? inTimeRange;
  if (startTime != null && endTime != null) {
    inTimeRange = _isTimeInAdFlightWindow(nowUtc, startTime, endTime);
    if (inTimeRange == false) {
      return AdSlotScheduleEvaluation(
        hasCreative: true,
        inDateRange: inDateRange,
        inTimeRange: false,
        skipPlayback: skipPlayback,
        shouldPlay: false,
        reason: 'outside_time_range',
      );
    }
  }

  final hasFlightWindow = startDate != null ||
      endDate != null ||
      startTime != null ||
      endTime != null;
  if (!hasFlightWindow) {
    return AdSlotScheduleEvaluation(
      hasCreative: true,
      inDateRange: inDateRange,
      inTimeRange: inTimeRange,
      skipPlayback: skipPlayback,
      shouldPlay: false,
      reason: 'no_flight_schedule',
    );
  }

  return AdSlotScheduleEvaluation(
    hasCreative: true,
    inDateRange: inDateRange,
    inTimeRange: inTimeRange,
    skipPlayback: skipPlayback,
    shouldPlay: true,
    reason: 'in_schedule',
  );
}

/// Ad campaign publishes carry flight windows on the ad_slot payload, not always_play.
bool isAdSlotInFlightSchedule(MediaItem media) {
  return evaluateAdSlotSchedule(media).shouldPlay;
}

/// Human-readable ad slot flight window for debug logs.
String describeAdSlotFlightSchedule(MediaItem media) {
  final s = media.settings;
  final e = evaluateAdSlotSchedule(media);
  final nowLocal = DateTime.now();
  final nowUtc = nowLocal.toUtc();
  String flag(bool? value) => value == null ? 'n/a' : (value ? 'yes' : 'no');
  final parts = <String>[
    'now_local=${nowLocal.toIso8601String()}',
    'now_utc=${formatProofOfPlayPlayedAt(nowUtc)}',
    'skip_playback=${s?.adSkipPlayback ?? "unset"}',
    'start_date=${s?.adFlightStartDate ?? "unset"}',
    'end_date=${s?.adFlightEndDate ?? "unset"}',
    'start_time_utc=${s?.adFlightStartTime ?? "unset"}',
    'end_time_utc=${s?.adFlightEndTime ?? "unset"}',
    'has_creative=${e.hasCreative}',
    'in_date_range=${flag(e.inDateRange)}',
    'in_time_range=${flag(e.inTimeRange)}',
    'should_play=${e.shouldPlay}',
    'reason=${e.reason}',
  ];
  return parts.join(', ');
}

bool shouldPlayMediaForSchedule(
  MediaItem media, {
  required bool Function(List<Restriction>? restrictions) checkRestrictions,
}) {
  // Ad slots always use flight window from ad_slot payload, never schedule.always_play.
  if (mediaItemIsAdSlot(media)) {
    return isAdSlotInFlightSchedule(media);
  }

  final schedule = media.schedule;
  if (schedule == null || (schedule.alwaysPlay ?? false)) {
    return true;
  }

  final restrictions = schedule.restrictions;
  if (restrictions != null && restrictions.isNotEmpty) {
    return checkRestrictions(restrictions);
  }

  return false;
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

  final mediaUrl =
      (json['mediaUrl'] ?? settings?.creativeUrl ?? '').toString().trim();
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
    resolution:
        resolutionMap == null ? null : Resolution.fromJson(resolutionMap),
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

    final props = node['properties'];
    if (props is Map<String, dynamic>) {
      final nestedComp = props['composition'];
      if (nestedComp is Map<String, dynamic>) {
        final compId = compositionCampaignIdFromJson(
          {
            'content_id': props['content_id'] ?? node['id'],
            'properties': props,
          },
          null,
        );
        final embedded = _campaignFromCompositionMediaMap({
          'id': node['id'],
          'campaign_id': compId,
          'composition': nestedComp,
          'settings': props,
        });
        if (embedded != null) {
          out.add(embedded);
        }
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

MediaItem _mergeCompositionInMediaItem(
  MediaItem media,
  List<Campaign> compositions,
) {
  var result = media;
  final type = (media.mediaType ?? '').toLowerCase();

  if (type == 'composition') {
    var linked = findLinkedCompositionCampaign(result, compositions);
    if (linked == null && compositions.length == 1) {
      linked = compositions.first;
    }
    final chosen = MediaItem._pickCompositionZones(result.zones, linked?.zones);
    if (chosen != null && chosen.isNotEmpty) {
      result = MediaItem(
        id: result.id,
        settings: result.settings,
        schedule: result.schedule ?? Schedule(alwaysPlay: true),
        mediaType: result.mediaType,
        mediaUrl: result.mediaUrl,
        zones: chosen,
      );
    }
  } else if (type == 'content') {
    final hasLinkHint =
        (result.settings?.compositionCampaignId ?? '').trim().isNotEmpty;
    if (hasLinkHint) {
      final linked = findLinkedCompositionCampaign(result, compositions);
      if (linked != null && (linked.zones?.isNotEmpty ?? false)) {
        final existing = result.settings;
        result = MediaItem(
          id: result.id,
          settings: Settings(
            compositionCampaignId:
                linked.campaignId ?? existing?.compositionCampaignId,
            contentId: existing?.contentId,
            kind: existing?.kind,
            duration: existing?.duration,
            html: existing?.html,
            text: existing?.text,
            fill: existing?.fill,
          ),
          schedule: result.schedule ?? Schedule(alwaysPlay: true),
          mediaType: 'composition',
          mediaUrl: null,
          zones: linked.zones,
        );
      }
    }
  }

  final nested = result.zones;
  if (nested != null && nested.isNotEmpty) {
    final mergedNested = _mergeCompositionInZoneList(nested, compositions);
    if (mergedNested != nested) {
      result = MediaItem(
        id: result.id,
        settings: result.settings,
        schedule: result.schedule,
        mediaType: result.mediaType,
        mediaUrl: result.mediaUrl,
        zones: mergedNested,
      );
    }
  }
  return result;
}

List<CampaignZone> _mergeCompositionInZoneList(
  List<CampaignZone> zones,
  List<Campaign> compositions,
) {
  var changed = false;
  final updated = zones.map((zone) {
    final items = zone.mediaItems;
    if (items == null) return zone;

    final mergedItems = items
        .map((m) => _mergeCompositionInMediaItem(m, compositions))
        .toList();

    var zoneChanged = false;
    if (mergedItems.length != items.length) {
      zoneChanged = true;
    } else {
      for (var i = 0; i < items.length; i++) {
        if (!identical(mergedItems[i], items[i])) {
          zoneChanged = true;
          break;
        }
      }
    }

    if (!zoneChanged) return zone;
    changed = true;
    return CampaignZone(
      id: zone.id,
      x: zone.x,
      y: zone.y,
      width: zone.width,
      height: zone.height,
      mediaItems: mergedItems,
    );
  }).toList();
  return changed ? updated : zones;
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

    final updatedZones = _mergeCompositionInZoneList(zones, compositions);
    if (identical(updatedZones, zones)) return campaign;

    return Campaign(
      playbackType: campaign.playbackType,
      campaignId: campaign.campaignId,
      campaignName: campaign.campaignName,
      resolution: campaign.resolution,
      campaignSchedule: campaign.campaignSchedule,
      campaignSettings: campaign.campaignSettings,
      zones: updatedZones,
      isPaused: campaign.isPaused,
    );
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

  // Register all compositions (extracted + original) for linking into any
  // zone elsewhere that references them via compositionCampaignId/contentId.
  final allCompositions = <Campaign>[
    ...extracted,
    ...originalCampaigns.where((c) => c.isCompositionLayout),
  ];
  final dedupedCompositions = _dedupeCampaignsById(allCompositions);
  setGlobalCompositionCampaigns(dedupedCompositions);

  // Compositions play in rotation alongside regular campaigns, same as any
  // other campaign. Previously they were dropped from top-level display
  // entirely whenever any regular campaign was also published, on the
  // assumption they'd always be embedded via a zone link elsewhere — but
  // that link isn't guaranteed (nothing may actually reference a given
  // composition), which silently lost it with nowhere to render. Always
  // include them here; if something also links to one via a zone
  // placeholder, it additionally renders nested there too.
  final campaignsToUse =
      originalCampaigns.isNotEmpty ? originalCampaigns : extracted;

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

  final linked = findLinkedCompositionCampaign(media, campaigns);
  final zones = MediaItem._pickCompositionZones(media.zones, linked?.zones);
  if (zones == null || zones.isEmpty) return media;

  return MediaItem(
    id: media.id,
    settings: media.settings,
    schedule: media.schedule ?? Schedule(alwaysPlay: true),
    mediaType: media.mediaType,
    mediaUrl: media.mediaUrl,
    zones: zones,
  );
}

bool mediaItemIsWebAppIframe(MediaItem media) {
  final kind = (media.settings?.kind ?? '').toLowerCase();
  return kind.contains('web-app') || kind.contains('web_app');
}

/// Resolves playlist/campaign web URLs (absolute, path-only, or slug).
String normalizeRemoteWebUrl(String? raw, {String? fallbackIframe}) {
  final iframe = fallbackIframe?.trim();
  if (iframe != null && iframe.isNotEmpty) {
    return _resolveAbsoluteWebUrl(iframe);
  }
  final url = raw?.trim() ?? '';
  if (url.isEmpty) return '';
  return _resolveAbsoluteWebUrl(url);
}

String _resolveAbsoluteWebUrl(String raw) {
  if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
  if (raw.startsWith('/')) {
    final origin = Uri.parse(baseurl).origin;
    return '$origin$raw';
  }
  final prefix = baseurl.endsWith('/') ? baseurl : '$baseurl/';
  return '$prefix$raw';
}

String mediaItemWebAppInstanceUrl(MediaItem media) {
  return normalizeRemoteWebUrl(
    media.mediaUrl,
    fallbackIframe: media.settings?.iframeSrc,
  );
}

String mediaItemWebAppIframeUrl(MediaItem media) {
  return normalizeRemoteWebUrl(
    media.mediaUrl,
    fallbackIframe: media.settings?.iframeSrc,
  );
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
      settings?.creativeName ?? adCreativeUrl.split('/').last.split('?').first;

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
    final resolvedCompletion =
        completionPercent ?? (status == 'completed' ? 100 : 0);
    final resolvedError = status == 'failed'
        ? resolveAdProofOfPlayErrorMessage(
            errorMessage: errorMessage,
            skipReason: s?.adSkipReason,
            skipPlayback: s?.adSkipPlayback,
          )
        : null;

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
      errorMessage: resolvedError,
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
        alwaysPlay: json['always_play'] ?? json['alwaysPlay'],
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
