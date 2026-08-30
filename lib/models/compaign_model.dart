import 'dart:convert';
import 'dart:math' as math;

import 'package:digital_signage/models/ad_proof_of_play_model.dart';
import 'package:digital_signage/utils/debug_log.dart';

int? _asInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? _asDouble(dynamic value) {
  if (value == null) return null;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

// Ad flight dates/times come from the backend in UTC (confirmed against the
// working Android player, which parses these as UTC and converts to
// device-local before comparing -- unlike the generic schedule/restriction
// system elsewhere in this file, which is already device-local on both
// ends and needs no conversion).
DateTime? _utcDateStringToLocal(String value) {
  try {
    final trimmed = value.trim();
    final iso = trimmed.contains('T')
        ? (trimmed.endsWith('Z') ? trimmed : '${trimmed}Z')
        : '${trimmed}T00:00:00Z';
    return DateTime.parse(iso).toLocal();
  } catch (_) {
    return null;
  }
}

DateTime? _utcTimeStringToLocal(String value) {
  try {
    final parts = value.trim().split(':');
    if (parts.length < 2) return null;
    final hour = int.parse(parts[0].trim());
    final minute = int.parse(parts[1].trim());
    final second = parts.length > 2 ? int.parse(parts[2].trim()) : 0;
    final nowUtc = DateTime.now().toUtc();
    final utcDateTime =
        DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day, hour, minute, second);
    return utcDateTime.toLocal();
  } catch (_) {
    return null;
  }
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
    if ((playbackType ?? '').toLowerCase() == 'composition') return true;
    return (zones?.length ?? 0) > 1;
  }

  factory Campaign.fromJson(Map<String, dynamic> json) => Campaign(
        playbackType: json["playback_type"],
        campaignId: json["campaign_id"],
        campaignName: json["campaign_name"],
        // A composition-type campaign's canvas size doesn't always arrive as
        // a top-level "resolution" key -- fall back to the composition
        // blob's own width/height (same fallback _campaignFromCompositionMediaMap
        // already uses). Without this, campaign.resolution silently ends up
        // null for some composition payloads, which makes _buildZones fall
        // back to using the device's own screen size as the scale
        // denominator -- i.e. scaleX/scaleY come out ~1.0 and raw small-
        // canvas zone coordinates get placed directly as screen pixels, so
        // every shape renders tiny and scattered instead of scaled up to
        // fill the screen.
        resolution: json["resolution"] != null
            ? Resolution.fromJson(json["resolution"])
            : (() {
                final compMap = MediaItem.compositionMapFromJson(json);
                if (compMap == null) return null;
                if (compMap['width'] == null && compMap['height'] == null) {
                  return null;
                }
                return Resolution.fromJson({
                  'width': compMap['width'],
                  'height': compMap['height'],
                });
              })(),
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
  // Konva node rotation in degrees, around the node's own x/y (top-left)
  // origin -- never read anywhere in the render path before, so every
  // rotated composition element (shape, text, image, anything) rendered
  // completely unrotated on the player regardless of what the CMS editor
  // showed. See _buildNestedZones for where this actually gets applied.
  double? rotation;
  List<MediaItem>? mediaItems;

  CampaignZone({
    this.id,
    this.x,
    this.y,
    this.width,
    this.height,
    this.rotation,
    this.mediaItems,
  });

  factory CampaignZone.fromJson(Map<String, dynamic> json) {
    final mediaRaw = json["mediaItems"] ?? json["media_items"];
    // TEMP diagnostic: a zone reported as "a playlist with multiple frames"
    // showed only 1 mediaItem -- dump every key on the zone and each raw
    // media item so we can see the CMS's actual field name for embedded
    // playlist data instead of guessing at it.
    debugLog(
      'CampaignZoneRaw',
      'zoneId=${json["id"]} keys=${json.keys.toList()} '
      'mediaItemsCount=${mediaRaw is List ? mediaRaw.length : "n/a"} '
      'mediaItemKeys=${mediaRaw is List ? mediaRaw.map((m) => m is Map ? m.keys.toList() : m.runtimeType.toString()).toList() : "n/a"}',
    );
    // Confirmed against the working Android reference (CampaignZone data
    // class in CampaignResponse.kt): it reads x/y/width/height directly with
    // no scaleX/scaleY multiplication anywhere -- the CMS already sends
    // final pixel values for this "zones"-keyed payload shape, unlike the
    // separate raw-Konva-editor "objects" shape. Multiplying by scaleX/
    // scaleY here was double-scaling and shrinking zones that were already
    // correct.
    final baseWidth = _asInt(json["width"]) ?? 0;
    final baseHeight = _asInt(json["height"]) ?? 0;
    final effectiveWidth = baseWidth;
    final effectiveHeight = baseHeight;
    List<MediaItem>? mediaItems;
    if (mediaRaw is List) {
      mediaItems = mediaRaw.map((raw) {
        final itemJson = Map<String, dynamic>.from(raw as Map<String, dynamic>);
        // A shape item's own json rarely repeats the zone's box size --
        // without this the fallback SVG always defaults to a square
        // 100x100, distorting a regular polygon once BoxFit.fill stretches
        // it to the real (Konva-scaled) non-square zone box.
        itemJson['width'] ??= effectiveWidth;
        itemJson['height'] ??= effectiveHeight;
        return MediaItem.fromJson(itemJson);
      }).toList();
    }
    return CampaignZone(
      id: _asInt(json["id"]),
      x: _asInt(json["x"]),
      y: _asInt(json["y"]),
      width: effectiveWidth,
      height: effectiveHeight,
      rotation: _asDouble(json["rotation"]),
      mediaItems: mediaItems,
    );
  }

  Map<String, dynamic> toJson() => {
        "id": id,
        "x": x,
        "y": y,
        "width": width,
        "height": height,
        "rotation": rotation,
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
    final type = (obj['type'] ??
            obj['mediaType'] ??
            obj['media_type'] ??
            '')
        .toString()
        .toLowerCase();
    if (type == 'composition' || type == 'campaign') return true;

    final merged = _objectJsonForCompositionDetect(obj, propMap);
    if (compositionMapFromJson(merged) != null) return true;
    if (compositionCampaignIdFromJson(merged, null) != null) return true;

    final kind = (propMap['kind'] ?? obj['name'] ?? '').toString().toLowerCase();
    if (kind.contains('composition')) return true;

    final contentType = (propMap['content_type'] ??
            propMap['contentType'] ??
            '')
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
      'download_url',
      'downloadUrl',
      'svgUrl',
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
    // The CMS composition editor (Konva) renders shapes server-side and
    // hands back the real SVG markup in properties.download_url -- this is
    // the ONLY thing the working Android player reads for shape objects
    // (CompositionRenderFragment.kt just drops props.download_url into the
    // DOM, no local reconstruction at all). Prefer that pre-rendered SVG,
    // wherever it landed, over rebuilding from primitive fill/stroke/
    // shapeType properties below -- that reconstruction doesn't understand
    // editor shape kinds like Konva's RegularPolygon (hexagon/octagon), so
    // it was silently producing a wrong/blank shape instead of the real one.
    for (final key in [
      'download_url',
      'downloadUrl',
      'svg',
      'mediaUrl',
      'media_url',
      'svgUrl',
      'url',
    ]) {
      final candidate = _cleanMediaUrl(props[key]?.toString());
      if (candidate != null && candidate.contains('<svg')) return candidate;
    }

    final w = width ?? _asInt(props['width']) ?? 100;
    final h = height ?? _asInt(props['height']) ?? 100;
    final rawFill = props['fill']?.toString();
    // Missing/empty/'transparent' means the CMS shape is outline-only --
    // defaulting that to a solid gray fill was rendering shapes filled when
    // the CMS shows them unfilled.
    final fill = (rawFill == null ||
            rawFill.isEmpty ||
            rawFill.toLowerCase() == 'transparent')
        ? 'none'
        : rawFill;
    final stroke =
        props['stroke']?.toString() ?? props['strokeColor']?.toString() ?? '';
    // A stroke wider than the shape itself (seen from real composition data:
    // strokeWidth=50 on an 80x80 octagon) paints over the entire fill,
    // turning a valid polygon into an unrecognizable solid blob -- cap it so
    // the shape's own fill always stays visible regardless of what value the
    // CMS sends.
    final rawStrokeWidth = _asInt(props['strokeWidth'] ?? props['stroke_width']) ?? 0;
    final strokeWidth = rawStrokeWidth > 0
        ? math.min(rawStrokeWidth, (math.min(w, h) * 0.2).round())
        : 0;
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
      case 'pentagon':
        return _regularPolygonSvg(5, w, h, fill, strokeAttr);
      case 'hexagon':
        return _regularPolygonSvg(6, w, h, fill, strokeAttr);
      case 'heptagon':
        return _regularPolygonSvg(7, w, h, fill, strokeAttr);
      case 'octagon':
        return _regularPolygonSvg(8, w, h, fill, strokeAttr);
      case 'nonagon':
        return _regularPolygonSvg(9, w, h, fill, strokeAttr);
      case 'decagon':
        return _regularPolygonSvg(10, w, h, fill, strokeAttr);
      case 'polygon':
      case 'regularpolygon':
        final sides = _asInt(props['sides'] ?? props['sidesCount']) ?? 6;
        return _regularPolygonSvg(sides, w, h, fill, strokeAttr);
      case 'star':
        final numPoints = _asInt(props['numPoints']) ?? 5;
        final innerRadiusPct = _asDouble(props['innerRadius']) ?? 0.5;
        return _starSvg(numPoints, innerRadiusPct, w, h, fill, strokeAttr);
      case 'ring':
        final outerRadius = (w < h ? w : h) / 2;
        final innerRadiusPct = _asDouble(props['innerRadius']) ?? 0.5;
        return _ringSvg(outerRadius, innerRadiusPct, w, h, fill);
      case 'rect':
      case 'rectangle':
      default:
        return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" '
            'viewBox="0 0 $w $h"><rect width="$w" height="$h" fill="$fill"$strokeAttr/></svg>';
    }
  }

  /// Matches Konva.RegularPolygon: first vertex points straight up, vertices
  /// evenly spaced clockwise, centered in the given box.
  static String _regularPolygonSvg(
    int sides,
    int w,
    int h,
    String fill,
    String strokeAttr,
  ) {
    if (sides < 3) sides = 3;
    final cx = w / 2;
    final cy = h / 2;
    final radius = (w < h ? w : h) / 2;
    final points = <String>[];
    for (var i = 0; i < sides; i++) {
      final angle = (-math.pi / 2) + (2 * math.pi * i / sides);
      final x = cx + radius * math.cos(angle);
      final y = cy + radius * math.sin(angle);
      points.add('${x.toStringAsFixed(2)},${y.toStringAsFixed(2)}');
    }
    return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" '
        'viewBox="0 0 $w $h"><polygon points="${points.join(' ')}" '
        'fill="$fill"$strokeAttr/></svg>';
  }

  /// Matches Konva.Star: alternating outer/inner vertices, first outer
  /// vertex straight up.
  static String _starSvg(
    int numPoints,
    double innerRadiusPct,
    int w,
    int h,
    String fill,
    String strokeAttr,
  ) {
    if (numPoints < 2) numPoints = 5;
    final cx = w / 2;
    final cy = h / 2;
    final outerRadius = (w < h ? w : h) / 2;
    final innerRadius = outerRadius * innerRadiusPct.clamp(0.01, 0.99);
    final points = <String>[];
    final totalVertices = numPoints * 2;
    for (var i = 0; i < totalVertices; i++) {
      final radius = i.isEven ? outerRadius : innerRadius;
      final angle = (-math.pi / 2) + (math.pi * i / numPoints);
      final x = cx + radius * math.cos(angle);
      final y = cy + radius * math.sin(angle);
      points.add('${x.toStringAsFixed(2)},${y.toStringAsFixed(2)}');
    }
    return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" '
        'viewBox="0 0 $w $h"><polygon points="${points.join(' ')}" '
        'fill="$fill"$strokeAttr/></svg>';
  }

  /// Matches Konva.Ring: an annulus (donut) via evenodd fill between two
  /// concentric circles.
  static String _ringSvg(
    double outerRadius,
    double innerRadiusPct,
    int w,
    int h,
    String fill,
  ) {
    final cx = w / 2;
    final cy = h / 2;
    final innerRadius = outerRadius * innerRadiusPct.clamp(0.01, 0.99);
    return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" '
        'viewBox="0 0 $w $h"><path fill-rule="evenodd" fill="$fill" d="'
        'M${cx - outerRadius},$cy a$outerRadius,$outerRadius 0 1,0 ${outerRadius * 2},0 '
        'a$outerRadius,$outerRadius 0 1,0 -${outerRadius * 2},0 Z '
        'M${cx - innerRadius},$cy a$innerRadius,$innerRadius 0 1,0 ${innerRadius * 2},0 '
        'a$innerRadius,$innerRadius 0 1,0 -${innerRadius * 2},0 Z"/></svg>';
  }

  static MediaItem? _mediaItemFromCompositionObject(
    Map<String, dynamic> obj,
    int index,
  ) {
    final type = (obj['type'] ??
            obj['mediaType'] ??
            obj['media_type'] ??
            'content')
        .toString()
        .toLowerCase();
    if (type == 'svg' || type == 'icon' || type == 'svg+xml') {
      return _mediaItemFromCompositionObject(
        {...obj, 'type': 'shape'},
        index,
      );
    }
    final props = obj['properties'];
    final propMap =
        props is Map<String, dynamic> ? props : <String, dynamic>{};

    String mediaType;
    String? mediaUrl;
    Settings settings;

    switch (type) {
      case 'text':
        // Konva scales the whole node -- including its rendered glyph size
        // and stroke -- so fontSize/strokeWidth need the same scaleY
        // compensation as width/height (see zonesFromCompositionMap).
        final textScaleY = _asDouble(obj['scaleY']) ?? 1.0;
        final baseFontSize = _asInt(propMap['fontSize']);
        final baseTextStrokeWidth = _asInt(propMap['strokeWidth']);
        mediaType = 'text';
        mediaUrl = null;
        settings = Settings(
          text: propMap['text']?.toString() ?? obj['name']?.toString(),
          html: propMap['html']?.toString(),
          fontSize: baseFontSize != null
              ? (baseFontSize * textScaleY).round()
              : null,
          fontFamily: propMap['fontFamily']?.toString(),
          fill: propMap['fill']?.toString(),
          strokeWidth: baseTextStrokeWidth != null
              ? (baseTextStrokeWidth * textScaleY).round()
              : null,
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
        // width/height on obj are already scaleX/scaleY-compensated by the
        // caller (see zonesFromCompositionMap) -- this is what makes the
        // fallback-SVG viewBox (used only when the backend hasn't already
        // provided a pre-rendered SVG via download_url/svg/mediaUrl) come
        // out the right size instead of the pre-resize base size. Stroke
        // width scales with the node too, same as fontSize does for text.
        final zoneW = _asInt(obj['width']) ?? 100;
        final zoneH = _asInt(obj['height']) ?? 100;
        final shapeScaleY = _asDouble(obj['scaleY']) ?? 1.0;
        final baseShapeStrokeWidth = _asInt(mergedShape['strokeWidth']);
        if (baseShapeStrokeWidth != null) {
          // Scale in place so the generated SVG's own stroke-width (below)
          // comes out right, not just the Settings field.
          mergedShape['strokeWidth'] =
              (baseShapeStrokeWidth * shapeScaleY).round();
        }
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

      // The editor is Konva-based: resizing a shape/text object changes
      // scaleX/scaleY rather than width/height directly. Confirmed directly
      // against the actual CMS editor canvas (not just its content-library
      // thumbnail, which turned out to be a cropped/zoomed preview and not
      // a reliable reference): several shape objects report identical
      // "default" raw sizes (100x80, 100x100) despite rendering at very
      // different, much larger sizes in the editor -- proving those raw
      // width/height values are pre-resize base sizes, and scaleX/scaleY is
      // what actually needs to be baked in to get the true rendered size.
      // (An earlier attempt removed this compensation on the theory that
      // Android's CompositionRenderFragment.kt -- which reads width/height
      // directly with no scale compensation -- proved the backend already
      // bakes the resize in; that theory is now confirmed wrong by direct
      // evidence, not just a guess this time.)
      final scaleX = _asDouble(raw['scaleX']) ?? 1.0;
      final scaleY = _asDouble(raw['scaleY']) ?? 1.0;
      final baseWidth = _asInt(raw['width']) ?? 0;
      final baseHeight = _asInt(raw['height']) ?? 0;
      // A 0-width/height zone (missing width/height in the raw Konva object)
      // is never intentional -- it just makes the zone's content invisible
      // or force-clipped, so floor it instead of trusting a literal 0.
      final effectiveWidth = math.max((baseWidth * scaleX).round(), 50);
      final effectiveHeight = math.max((baseHeight * scaleY).round(), 50);
      final scaledRaw = (scaleX == 1.0 && scaleY == 1.0)
          ? raw
          : {...raw, 'width': effectiveWidth, 'height': effectiveHeight};

      // TEMP diagnostic: dump the raw object's own fields verbatim so we can
      // see actual scaleX/scaleY/rotation/offset values instead of guessing
      // -- the last two attempts at this compensation (add it, remove it)
      // were both based on indirect evidence, not the raw JSON itself.
      debugLog(
        'CompositionObject',
        'zone=$zoneIndex type=${raw['type']} name=${raw['name']} '
        'x=${raw['x']} y=${raw['y']} width=${raw['width']} height=${raw['height']} '
        'scaleX=${raw['scaleX']} scaleY=${raw['scaleY']} rotation=${raw['rotation']} '
        'offsetX=${raw['offsetX']} offsetY=${raw['offsetY']} '
        'effectiveWidth=$effectiveWidth effectiveHeight=$effectiveHeight',
      );

      final media = _mediaItemFromCompositionObject(scaledRaw, zoneIndex);
      if (media == null) continue;
      zones.add(
        CampaignZone(
          id: zoneIndex,
          x: _asInt(raw['x']),
          y: _asInt(raw['y']),
          width: effectiveWidth,
          height: effectiveHeight,
          rotation: _asDouble(raw['rotation']),
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
        if ((m.mediaType ?? '').toLowerCase() == 'shape' &&
            _shapeHasSvg(m)) {
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
    var mediaType = _mediaTypeFromJson(json);
    // A linked playlist/nested composition sometimes arrives tagged with a
    // generic mediaType (e.g. 'content') plus a content_id/composition_id
    // reference rather than literally typed 'composition' -- without this
    // it gets flattened to a single static frame instead of resolving into
    // its real (possibly multi-frame) linked content.
    if (mediaType?.toLowerCase() != 'composition' &&
        mediaType?.toLowerCase() != 'campaign') {
      final propsForDetection = json['properties'] is Map<String, dynamic>
          ? json['properties'] as Map<String, dynamic>
          : <String, dynamic>{};
      if (objectLooksLikeNestedComposition(json, propsForDetection)) {
        mediaType = 'composition';
      }
    }
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

  // Ad flight schedule (separate from the generic date/time restrictions
  // above). The backend sends these in UTC -- see adFlightWindowActive on
  // MediaItem, which converts to device-local before comparing.
  String? adFlightStartDate;
  String? adFlightEndDate;
  String? adFlightStartTime;
  String? adFlightEndTime;

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
        creativeMediaType:
            json["creative_media_type"] ?? json["media_type"],
        adFlightStartDate:
            json["start_date"]?.toString() ?? json["startDate"]?.toString(),
        adFlightEndDate:
            json["end_date"]?.toString() ?? json["endDate"]?.toString(),
        adFlightStartTime:
            json["start_time"]?.toString() ?? json["startTime"]?.toString(),
        adFlightEndTime:
            json["end_time"]?.toString() ?? json["endTime"]?.toString(),
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

bool _compositionCampaignIdsMatch(String? a, String? b) {
  final left = a?.trim();
  final right = b?.trim();
  if (left == null || left.isEmpty || right == null || right.isEmpty) {
    return false;
  }
  if (left == right) return true;
  if (left == right.replaceFirst('composition_', '')) return true;
  if ('composition_$left' == right) return true;
  if (left.replaceFirst('composition_', '') == right.replaceFirst('composition_', '')) {
    return left.replaceFirst('composition_', '').isNotEmpty;
  }
  return false;
}

Campaign? _findRegisteredCompositionForCampaign(
  Campaign campaign,
  List<Campaign> compositionRegistry,
) {
  Campaign? bestMatch;
  final name = campaign.campaignName?.trim().toLowerCase();

  for (final comp in compositionRegistry) {
    final idMatch = _compositionCampaignIdsMatch(
      campaign.campaignId,
      comp.campaignId,
    );
    final nameMatch = name != null &&
        name.isNotEmpty &&
        name == comp.campaignName?.trim().toLowerCase();
    if (!idMatch && !nameMatch) continue;

    if (bestMatch == null ||
        _campaignZoneCount(comp) > _campaignZoneCount(bestMatch)) {
      bestMatch = comp;
    }
  }
  return bestMatch;
}

List<Campaign> _hydratePlayerCampaignsFromCompositions(
  List<Campaign> playerCampaigns,
  List<Campaign> compositionRegistry,
) {
  if (compositionRegistry.isEmpty) return playerCampaigns;

  return playerCampaigns.map((campaign) {
    final registered = _findRegisteredCompositionForCampaign(
      campaign,
      compositionRegistry,
    );
    if (registered == null ||
        _campaignZoneCount(registered) <= _campaignZoneCount(campaign)) {
      return campaign;
    }

    print(
        '[Composition] Hydrating "${campaign.campaignName}" '
        '(${_campaignZoneCount(campaign)} zone(s)) from registry '
        '(${_campaignZoneCount(registered)} zone(s), id=${registered.campaignId})');

    return Campaign(
      playbackType: 'composition',
      campaignId: registered.campaignId ?? campaign.campaignId,
      campaignName: campaign.campaignName ?? registered.campaignName,
      resolution: registered.resolution ?? campaign.resolution,
      campaignSchedule: campaign.campaignSchedule ??
          registered.campaignSchedule ??
          CampaignSchedule(alwaysPlay: true),
      campaignSettings: campaign.campaignSettings ?? registered.campaignSettings,
      zones: registered.zones,
      isPaused: campaign.isPaused,
    );
  }).toList();
}

bool _isCompositionRepresentedInPlayerList(
  Campaign comp,
  List<Campaign> playerCampaigns,
) {
  for (final c in playerCampaigns) {
    if (_compositionCampaignIdsMatch(c.campaignId, comp.campaignId)) {
      return true;
    }
    final compName = comp.campaignName?.trim().toLowerCase();
    final cName = c.campaignName?.trim().toLowerCase();
    if (compName != null &&
        compName.isNotEmpty &&
        compName == cName &&
        (c.isCompositionLayout ||
            _campaignZoneCount(c) >= _campaignZoneCount(comp))) {
      return true;
    }
  }
  return false;
}

List<Campaign> _appendMissingStandaloneCompositions(
  List<Campaign> playerCampaigns,
  List<Campaign> compositionRegistry,
) {
  if (compositionRegistry.isEmpty) return playerCampaigns;

  final result = List<Campaign>.from(playerCampaigns);
  for (final comp in compositionRegistry) {
    if (_campaignZoneCount(comp) < 2 && !comp.isCompositionLayout) continue;
    if (_isCompositionRepresentedInPlayerList(comp, result)) continue;

    print(
        '[Composition] Adding "${comp.campaignName}" to rotation '
        '(${_campaignZoneCount(comp)} zone(s), id=${comp.campaignId})');

    result.add(
      Campaign(
        playbackType: 'composition',
        campaignId: comp.campaignId,
        campaignName: comp.campaignName,
        resolution: comp.resolution,
        campaignSchedule:
            comp.campaignSchedule ?? CampaignSchedule(alwaysPlay: true),
        campaignSettings: comp.campaignSettings,
        zones: comp.zones,
        isPaused: comp.isPaused,
      ),
    );
  }
  return result;
}

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
    final chosen =
        MediaItem._pickCompositionZones(result.zones, linked?.zones);
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

    final mergedItems =
        items.map((m) => _mergeCompositionInMediaItem(m, compositions)).toList();

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

  // Register all compositions (extracted + original) for linking
  final allCompositions = <Campaign>[
    ...extracted,
    ...originalCampaigns.where((c) => c.isCompositionLayout),
  ];
  final dedupedCompositions = _dedupeCampaignsById(allCompositions);
  setGlobalCompositionCampaigns(dedupedCompositions);

  // Keep all originally published player campaigns (including standalone compositions).
  // Extracted/nested compositions stay in globalCompositionCampaigns for zone linking only.
  final campaignsToUse =
      originalCampaigns.isEmpty ? extracted : originalCampaigns;

  final deduped = _dedupeCampaignsById(campaignsToUse);

  // Replace thin player-campaign stubs (e.g. preview image) with full layouts
  // from the composition registry when ids or names match ("final", etc.).
  final hydrated =
      _hydratePlayerCampaignsFromCompositions(deduped, dedupedCompositions);

  // When solos + composition publish together, the full layout may live only in
  // the composition registry — add it to rotation if not already represented.
  final withStandalones = _appendMissingStandaloneCompositions(
    hydrated,
    dedupedCompositions,
  );

  // Inject composition zones into composition media items
  final withEmbedded = _mergeCompositionPlaceholders(withStandalones);

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

  final nameHint = media.settings?.creativeName?.trim().toLowerCase();
  if (nameHint != null && nameHint.isNotEmpty) {
    for (final c in all) {
      if (c.campaignName?.trim().toLowerCase() == nameHint) return c;
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
  final zones =
      MediaItem._pickCompositionZones(media.zones, linked?.zones);
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

  /// Ad flight window (start_date/end_date/start_time/end_time), separate
  /// from the generic schedule/restrictions gating. True when there's no
  /// flight window configured (nothing to gate on) or when unparseable, so
  /// this never blocks playback for ad items that don't send these fields.
  bool get adFlightWindowActive {
    final s = settings;
    if (s == null) return true;

    final hasDate = (s.adFlightStartDate?.isNotEmpty ?? false) &&
        (s.adFlightEndDate?.isNotEmpty ?? false);
    final hasTime = (s.adFlightStartTime?.isNotEmpty ?? false) &&
        (s.adFlightEndTime?.isNotEmpty ?? false);
    if (!hasDate && !hasTime) return true;

    final now = DateTime.now();

    if (hasDate) {
      final startLocal = _utcDateStringToLocal(s.adFlightStartDate!);
      final endLocal = _utcDateStringToLocal(s.adFlightEndDate!);
      if (startLocal != null && endLocal != null) {
        final today = DateTime(now.year, now.month, now.day);
        final startDay =
            DateTime(startLocal.year, startLocal.month, startLocal.day);
        final endDay = DateTime(endLocal.year, endLocal.month, endLocal.day);
        if (today.isBefore(startDay) || today.isAfter(endDay)) {
          return false;
        }
      }
    }

    if (hasTime) {
      final startLocal = _utcTimeStringToLocal(s.adFlightStartTime!);
      final endLocal = _utcTimeStringToLocal(s.adFlightEndTime!);
      if (startLocal != null && endLocal != null) {
        final nowMinutes = now.hour * 60 + now.minute;
        final startMinutes = startLocal.hour * 60 + startLocal.minute;
        final endMinutes = endLocal.hour * 60 + endLocal.minute;
        if (startMinutes <= endMinutes) {
          if (nowMinutes < startMinutes || nowMinutes > endMinutes) {
            return false;
          }
        } else {
          // Overnight window (e.g. 22:00 -> 06:00).
          if (nowMinutes < startMinutes && nowMinutes > endMinutes) {
            return false;
          }
        }
      }
    }

    return true;
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
