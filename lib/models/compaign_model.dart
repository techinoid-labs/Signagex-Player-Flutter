import 'dart:convert';

CampaignModel campaignModelFromJson(String str) =>
    CampaignModel.fromJson(json.decode(str));

String campaignModelToJson(CampaignModel data) => json.encode(data.toJson());

class CampaignModel {
  String action;
  String sender;
  String playbackType;
  List<Data> data;

  CampaignModel({
    required this.action,
    required this.sender,
    required this.playbackType,
    required this.data,
  });

  factory CampaignModel.fromJson(Map<String, dynamic> json) => CampaignModel(
        action: json["action"],
        sender: json["sender"],
        playbackType: json["playback_type"],
        data: List<Data>.from(json["data"].map((x) => Data.fromJson(x))),
      );

  Map<String, dynamic> toJson() => {
        "action": action,
        "sender": sender,
        "playback_type": playbackType,
        "data": List<dynamic>.from(data.map((x) => x.toJson())),
      };
}

class Data {
  int campaignId;
  Resolution resolution;
  CampaignSettings campaignSettings;
  CampaignSchedule campaignSchedule;
  List<Zone> zones;

  Data({
    required this.campaignId,
    required this.resolution,
    required this.campaignSettings,
    required this.campaignSchedule,
    required this.zones,
  });

  factory Data.fromJson(Map<String, dynamic> json) => Data(
        campaignId: json["campaign_id"],
        resolution: Resolution.fromJson(json["resolution"]),
        campaignSettings: CampaignSettings.fromJson(json["campaign_settings"]),
        campaignSchedule: CampaignSchedule.fromJson(json["campaign_schedule"]),
        zones: List<Zone>.from(json["zones"].map((x) => Zone.fromJson(x))),
      );

  Map<String, dynamic> toJson() => {
        "campaign_id": campaignId,
        "resolution": resolution.toJson(),
        "campaign_settings": campaignSettings.toJson(),
        "campaign_schedule": campaignSchedule.toJson(),
        "zones": List<dynamic>.from(zones.map((x) => x.toJson())),
      };
}

class CampaignSchedule {
  bool alwaysPlay;
  Period period;

  CampaignSchedule({
    required this.alwaysPlay,
    required this.period,
  });

  factory CampaignSchedule.fromJson(Map<String, dynamic> json) =>
      CampaignSchedule(
        alwaysPlay: json["always_play"],
        period: Period.fromJson(json["period"]),
      );

  Map<String, dynamic> toJson() => {
        "always_play": alwaysPlay,
        "period": period.toJson(),
      };
}

class Period {
  Days days;
  Time time;
  Date date;

  Period({
    required this.days,
    required this.time,
    required this.date,
  });

  factory Period.fromJson(Map<String, dynamic> json) => Period(
        days: Days.fromJson(json["days"]),
        time: Time.fromJson(json["time"]),
        date: Date.fromJson(json["date"]),
      );

  Map<String, dynamic> toJson() => {
        "days": days.toJson(),
        "time": time.toJson(),
        "date": date.toJson(),
      };
}

class Date {
  DateTime start;
  DateTime end;

  Date({
    required this.start,
    required this.end,
  });

  /// Custom method to parse date strings in MM/dd/yyyy format
  static DateTime parseDate(String dateStr) {
    final parts = dateStr.split('/');
    if (parts.length == 3) {
      return DateTime(
        int.parse(parts[2]), // Year
        int.parse(parts[0]), // Month
        int.parse(parts[1]), // Day
      );
    }
    throw FormatException("Invalid date format", dateStr);
  }

  factory Date.fromJson(Map<String, dynamic> json) => Date(
        start: parseDate(json["start"]),
        end: parseDate(json["end"]),
      );

  Map<String, dynamic> toJson() => {
        "start": "${start.month}/${start.day}/${start.year}",
        "end": "${end.month}/${end.day}/${end.year}",
      };
}

class Days {
  bool sunday;
  bool monday;
  bool tuesday;
  bool wednesday;
  bool thursday;
  bool friday;
  bool saturday;

  Days({
    required this.sunday,
    required this.monday,
    required this.tuesday,
    required this.wednesday,
    required this.thursday,
    required this.friday,
    required this.saturday,
  });

  factory Days.fromJson(Map<String, dynamic> json) => Days(
        sunday: json["sunday"],
        monday: json["monday"],
        tuesday: json["tuesday"],
        wednesday: json["wednesday"],
        thursday: json["thursday"],
        friday: json["friday"],
        saturday: json["saturday"],
      );

  Map<String, dynamic> toJson() => {
        "sunday": sunday,
        "monday": monday,
        "tuesday": tuesday,
        "wednesday": wednesday,
        "thursday": thursday,
        "friday": friday,
        "saturday": saturday,
      };
}

class Time {
  String from;
  String to;

  Time({
    required this.from,
    required this.to,
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

class Resolution {
  int width;
  int height;

  Resolution({
    required this.width,
    required this.height,
  });

  factory Resolution.fromJson(Map<String, dynamic> json) => Resolution(
        width: json["width"],
        height: json["height"],
      );

  Map<String, dynamic> toJson() => {
        "width": width,
        "height": height,
      };
}

class CampaignSettings {
  int duration;
  bool loop;
  String transition;

  CampaignSettings({
    required this.duration,
    required this.loop,
    required this.transition,
  });

  factory CampaignSettings.fromJson(Map<String, dynamic> json) =>
      CampaignSettings(
        duration: json["duration"],
        loop: json["loop"],
        transition: json["transition"],
      );

  Map<String, dynamic> toJson() => {
        "duration": duration,
        "loop": loop,
        "transition": transition,
      };
}

class Zone {
  int id;
  int x;
  int y;
  int width;
  int height;
  List<MediaItem> mediaItems;

  Zone({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.mediaItems,
  });

  factory Zone.fromJson(Map<String, dynamic> json) => Zone(
        id: json["id"],
        x: json["x"],
        y: json["y"],
        width: json["width"],
        height: json["height"],
        mediaItems: List<MediaItem>.from(
            json["mediaItems"].map((x) => MediaItem.fromJson(x))),
      );

  Map<String, dynamic> toJson() => {
        "id": id,
        "x": x,
        "y": y,
        "width": width,
        "height": height,
        "mediaItems": List<dynamic>.from(mediaItems.map((x) => x.toJson())),
      };
}

class MediaItem {
  String id;
  String mediaType;
  String mediaUrl;
  Settings settings;
  CampaignSchedule schedule;

  MediaItem({
    required this.id,
    required this.mediaType,
    required this.mediaUrl,
    required this.settings,
    required this.schedule,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
        id: json["id"],
        mediaType: json["mediaType"],
        mediaUrl: json["mediaUrl"],
        settings: Settings.fromJson(json["settings"]),
        schedule: CampaignSchedule.fromJson(json["schedule"]),
      );

  Map<String, dynamic> toJson() => {
        "id": id,
        "mediaType": mediaType,
        "mediaUrl": mediaUrl,
        "settings": settings.toJson(),
        "schedule": schedule.toJson(),
      };
}

class Settings {
  int duration;
  bool loop;
  String transition;

  Settings({
    required this.duration,
    required this.loop,
    required this.transition,
  });

  factory Settings.fromJson(Map<String, dynamic> json) => Settings(
        duration: json["duration"],
        loop: json["loop"],
        transition: json["transition"],
      );

  Map<String, dynamic> toJson() => {
        "duration": duration,
        "loop": loop,
        "transition": transition,
      };
}
