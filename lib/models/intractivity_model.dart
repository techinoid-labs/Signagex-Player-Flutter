import 'dart:convert';

import 'package:digital_signage/models/compaign_model.dart'
    show CampaignSchedule, Restriction;

// The `create_interactivity` message: the player's FULL current trigger list,
// sent on every create, update and delete (signageX-backend
// interactivity.resolver.ts). Real sample: "Interactivity Response complete
// final response.txt" at the repo root.
//
// Class names are all Interactivity-prefixed on purpose: this file used to
// declare its own MediaItem/Settings/Trigger/Zone, which collided with
// compaign_model.dart's and forced `hide` clauses on every importer. Trigger
// content is kept as raw JSON and converted to compaign_model's Campaign at
// render time, so there is one media model, not two.

InteractivityModel interactivityModelFromJson(String str) =>
    InteractivityModel.fromJson(json.decode(str) as Map<String, dynamic>);

String interactivityModelToJson(InteractivityModel data) =>
    json.encode(data.toJson());

int? _asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.round();
  return num.tryParse(v.toString())?.round();
}

double? _asDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

bool _asBool(dynamic v) => v == true || v?.toString().toLowerCase() == 'true';

List<String> _asStrings(dynamic v) {
  if (v is List) {
    return v
        .where((e) => e != null)
        .map((e) => e.toString())
        .where((e) => e.trim().isNotEmpty)
        .toList();
  }
  if (v is String && v.trim().isNotEmpty) return [v];
  return const [];
}

List<Map<String, dynamic>> _asMaps(dynamic v) {
  if (v is! List) return const [];
  return v
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}

class InteractivityModel {
  final String action;
  final List<Interactivity> interactivity;

  /// The message as received, kept so it can be persisted and restored
  /// exactly rather than re-serialised from the parsed fields.
  final Map<String, dynamic> raw;

  InteractivityModel({
    required this.action,
    required this.interactivity,
    required this.raw,
  });

  factory InteractivityModel.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    final list = data is Map ? data['interactivity'] : null;
    return InteractivityModel(
      action: json['action']?.toString() ?? '',
      interactivity: _asMaps(list).map(Interactivity.fromJson).toList(),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw;
}

class Interactivity {
  final String id;
  final String name;

  // Conditions -- any of these that is present can fire it.
  final List<String> keyPress;
  final bool touchRegion;
  final List<InteractivityControl> control;
  final List<String> localApi;
  final bool onDemand;

  /// Seconds without any touch or key input. Null when not configured.
  final int? interactivityTimeout;

  /// Device-local date-times ("2026-09-15T20:33:00").
  final List<DateTime> specificTime;

  // Gate.
  final bool pause;
  final CampaignSchedule? schedule;
  final List<InteractivityRestrictionGroup> restrictionGroups;

  /// The space touch-region pixel coordinates are in.
  final double resolutionWidth;
  final double resolutionHeight;

  final List<InteractivityTrigger> triggers;

  Interactivity({
    required this.id,
    required this.name,
    required this.keyPress,
    required this.touchRegion,
    required this.control,
    required this.localApi,
    required this.onDemand,
    required this.interactivityTimeout,
    required this.specificTime,
    required this.pause,
    required this.schedule,
    required this.restrictionGroups,
    required this.resolutionWidth,
    required this.resolutionHeight,
    required this.triggers,
  });

  factory Interactivity.fromJson(Map<String, dynamic> json) {
    final schedule = json['schedule'];
    final timeout = _asInt(json['interactivity_timeout']);
    return Interactivity(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      keyPress: _asStrings(json['key_press']),
      touchRegion: _asBool(json['touch_region']),
      control:
          _asMaps(json['control']).map(InteractivityControl.fromJson).toList(),
      localApi: _asStrings(json['local_api']),
      onDemand: _asBool(json['on_demand']),
      interactivityTimeout: timeout != null && timeout > 0 ? timeout : null,
      specificTime: _asStrings(json['specific_time'])
          .map((s) => DateTime.tryParse(s))
          .whereType<DateTime>()
          .toList(),
      pause: _asBool(json['pause']),
      schedule: schedule is Map
          ? CampaignSchedule.fromJson(Map<String, dynamic>.from(schedule))
          : null,
      restrictionGroups: _asMaps(json['restriction_groups'])
          .map(InteractivityRestrictionGroup.fromJson)
          .toList(),
      resolutionWidth: _asDouble(json['resolution_width']) ?? 1920,
      resolutionHeight: _asDouble(json['resolution_height']) ?? 1080,
      triggers:
          _asMaps(json['triggers']).map(InteractivityTrigger.fromJson).toList(),
    );
  }
}

/// One touch region. `relative` is the region as 0..1 fractions of the
/// interactivity's resolution; x/y/width/height are the same region in
/// resolution pixels, used only when `relative` is missing.
class InteractivityControl {
  final bool anyRegion;
  final double? x;
  final double? y;
  final double? width;
  final double? height;
  final double? relX;
  final double? relY;
  final double? relWidth;
  final double? relHeight;

  InteractivityControl({
    required this.anyRegion,
    this.x,
    this.y,
    this.width,
    this.height,
    this.relX,
    this.relY,
    this.relWidth,
    this.relHeight,
  });

  factory InteractivityControl.fromJson(Map<String, dynamic> json) {
    final rel = json['relative'];
    final relMap = rel is Map ? rel : const <String, dynamic>{};
    return InteractivityControl(
      anyRegion: _asBool(json['any_region']),
      x: _asDouble(json['x']),
      y: _asDouble(json['y']),
      width: _asDouble(json['width']),
      height: _asDouble(json['height']),
      relX: _asDouble(relMap['x']),
      relY: _asDouble(relMap['y']),
      relWidth: _asDouble(relMap['width']),
      relHeight: _asDouble(relMap['height']),
    );
  }
}

/// `{operator, restrictions, groups}`: the restrictions and nested groups
/// combine with [operator]; the top-level list of groups is ANDed.
class InteractivityRestrictionGroup {
  final String operator;
  final List<Restriction> restrictions;
  final List<InteractivityRestrictionGroup> groups;

  InteractivityRestrictionGroup({
    required this.operator,
    required this.restrictions,
    required this.groups,
  });

  factory InteractivityRestrictionGroup.fromJson(Map<String, dynamic> json) =>
      InteractivityRestrictionGroup(
        operator: (json['operator']?.toString() ?? 'AND').toUpperCase(),
        restrictions:
            _asMaps(json['restrictions']).map(Restriction.fromJson).toList(),
        groups: _asMaps(json['groups'])
            .map(InteractivityRestrictionGroup.fromJson)
            .toList(),
      );
}

class InteractivityTrigger {
  /// play | enqueue | enqueue_and_play | stop
  final String triggerType;

  /// Seconds the content stays on screen; 10 when the CMS sent none.
  final int duration;
  final String transition;

  /// 0-100, applied to the content's own video/audio while it shows.
  final int volume;

  /// `[{id, name, mediaType, mediaUrl?, zones:[...]}]` -- zones/mediaItems
  /// in the same shape as a publish_campaign campaign's.
  final List<Map<String, dynamic>> content;

  InteractivityTrigger({
    required this.triggerType,
    required this.duration,
    required this.transition,
    required this.volume,
    required this.content,
  });

  factory InteractivityTrigger.fromJson(Map<String, dynamic> json) {
    final duration = _asInt(json['duration']) ?? 0;
    return InteractivityTrigger(
      triggerType: (json['trigger_type']?.toString() ?? 'play').toLowerCase(),
      duration: duration > 0 ? duration : 10,
      transition: json['transition']?.toString() ?? 'none',
      volume: (_asInt(json['volume']) ?? 100).clamp(0, 100).toInt(),
      content: _asMaps(json['content']),
    );
  }
}
