// To parse this JSON data, do
//
//     final campaignModel = campaignModelFromJson(jsonString);

import 'dart:convert';

CampaignModel campaignModelFromJson(String str) => CampaignModel.fromJson(json.decode(str));

String campaignModelToJson(CampaignModel data) => json.encode(data.toJson());

class CampaignModel {
    String action;
    String sender;
    Data data;

    CampaignModel({
        required this.action,
        required this.sender,
        required this.data,
    });

    factory CampaignModel.fromJson(Map<String, dynamic> json) => CampaignModel(
        action: json["action"],
        sender: json["sender"],
        data: Data.fromJson(json["data"]),
    );

    Map<String, dynamic> toJson() => {
        "action": action,
        "sender": sender,
        "data": data.toJson(),
    };
}

class Data {
    String playbackType;
    Resolution resolution;
    Schedule campaignSchedule;
    List<Zone> zones;

    Data({
        required this.playbackType,
        required this.resolution,
        required this.campaignSchedule,
        required this.zones,
    });

    factory Data.fromJson(Map<String, dynamic> json) => Data(
        playbackType: json["playback_type"],
        resolution: Resolution.fromJson(json["resolution"]),
        campaignSchedule: Schedule.fromJson(json["campaign_schedule"]),
        zones: List<Zone>.from(json["zones"].map((x) => Zone.fromJson(x))),
    );

    Map<String, dynamic> toJson() => {
        "playback_type": playbackType,
        "resolution": resolution.toJson(),
        "campaign_schedule": campaignSchedule.toJson(),
        "zones": List<dynamic>.from(zones.map((x) => x.toJson())),
    };
}

class Schedule {
    bool alwaysPlay;
    Period? period;

    Schedule({
        required this.alwaysPlay,
        required this.period,
    });

    factory Schedule.fromJson(Map<String, dynamic> json) => Schedule(
        alwaysPlay: json["always_play"],
        period: json["period"] == null ? null : Period.fromJson(json["period"]),
    );

    Map<String, dynamic> toJson() => {
        "always_play": alwaysPlay,
        "period": period?.toJson(),
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
    String start;
    String end;

    Date({
        required this.start,
        required this.end,
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
        x: json["x"],
         id: json["id"],
        y: json["y"],
        width: json["width"],
        height: json["height"],
        mediaItems: List<MediaItem>.from(json["mediaItems"].map((x) => MediaItem.fromJson(x))),
    );

    Map<String, dynamic> toJson() => {
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
    Schedule schedule;

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
        schedule: Schedule.fromJson(json["schedule"]),
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
