// To parse this JSON data, do
//
//     final interactivityModel = interactivityModelFromJson(jsonString);

import 'dart:convert';

InteractivityModel interactivityModelFromJson(String str) => InteractivityModel.fromJson(json.decode(str));

String interactivityModelToJson(InteractivityModel data) => json.encode(data.toJson());

class InteractivityModel {
    String? action;
    Data? data;
    String? sender;

    InteractivityModel({
         this.action,
         this.data,
         this.sender,
    });

    factory InteractivityModel.fromJson(Map<String, dynamic> json) => InteractivityModel(
        action: json["action"],
        data: Data.fromJson(json["data"]),
        sender: json["sender"],
    );

    Map<String, dynamic> toJson() => {
        "action": action,
        "data": data!.toJson(),
        "sender": sender,
    };
}

class Data {
    bool success;
    String message;
    List<Interactivity> interactivity;

    Data({
        required this.success,
        required this.message,
        required this.interactivity,
    });

    factory Data.fromJson(Map<String, dynamic> json) => Data(
        success: json["success"],
        message: json["message"],
        interactivity: List<Interactivity>.from(json["interactivity"].map((x) => Interactivity.fromJson(x))),
    );

    Map<String, dynamic> toJson() => {
        "success": success,
        "message": message,
        "interactivity": List<dynamic>.from(interactivity.map((x) => x.toJson())),
    };
}

class Interactivity {
    String id;
    String playerId;
    String name;
    dynamic anyRegion;
    dynamic regionX;
    dynamic regionY;
    dynamic regionWidth;
    dynamic regionHeight;
    List<String> keyPress;
    dynamic days;
    dynamic startTime;
    dynamic endTime;
    dynamic startDate;
    dynamic endDate;
    dynamic pause;
    dynamic resolutionWidth;
    dynamic resolutionHeight;
    List<Trigger> triggers;

    Interactivity({
        required this.id,
        required this.playerId,
        required this.name,
        required this.anyRegion,
        required this.regionX,
        required this.regionY,
        required this.regionWidth,
        required this.regionHeight,
        required this.keyPress,
        required this.days,
        required this.startTime,
        required this.endTime,
        required this.startDate,
        required this.endDate,
        required this.pause,
        required this.resolutionWidth,
        required this.resolutionHeight,
        required this.triggers,
    });

    factory Interactivity.fromJson(Map<String, dynamic> json) => Interactivity(
        id: json["id"],
        playerId: json["player_id"],
        name: json["name"],
        anyRegion: json["any_region"],
        regionX: json["region_x"],
        regionY: json["region_y"],
        regionWidth: json["region_width"],
        regionHeight: json["region_height"],
        keyPress: List<String>.from(json["key_press"].map((x) => x)),
        days: json["days"],
        startTime: json["start_time"],
        endTime: json["end_time"],
        startDate: json["start_date"],
        endDate: json["end_date"],
        pause: json["pause"],
        resolutionWidth: json["resolution_width"],
        resolutionHeight: json["resolution_height"],
        triggers: List<Trigger>.from(json["triggers"].map((x) => Trigger.fromJson(x))),
    );

    Map<String, dynamic> toJson() => {
        "id": id,
        "player_id": playerId,
        "name": name,
        "any_region": anyRegion,
        "region_x": regionX,
        "region_y": regionY,
        "region_width": regionWidth,
        "region_height": regionHeight,
        "key_press": List<dynamic>.from(keyPress.map((x) => x)),
        "days": days,
        "start_time": startTime,
        "end_time": endTime,
        "start_date": startDate,
        "end_date": endDate,
        "pause": pause,
        "resolution_width": resolutionWidth,
        "resolution_height": resolutionHeight,
        "triggers": List<dynamic>.from(triggers.map((x) => x.toJson())),
    };
}

class Trigger {
    String triggerType;
    dynamic playingLoop;
    dynamic namedRegion;
    String duration;
    String transition;
    dynamic aspectRatio;
    dynamic contentId;
    String? playlistId;
    String? campaignId;
    List<Content> content;

    Trigger({
        required this.triggerType,
        required this.playingLoop,
        required this.namedRegion,
        required this.duration,
        required this.transition,
        required this.aspectRatio,
        required this.contentId,
        required this.playlistId,
        required this.campaignId,
        required this.content,
    });

    factory Trigger.fromJson(Map<String, dynamic> json) => Trigger(
        triggerType: json["trigger_type"],
        playingLoop: json["playing_loop"],
        namedRegion: json["named_region"],
        duration: json["duration"],
        transition: json["transition"],
        aspectRatio: json["aspect_ratio"],
        contentId: json["content_id"],
        playlistId: json["playlist_id"],
        campaignId: json["campaign_id"],
        content: List<Content>.from(json["content"].map((x) => Content.fromJson(x))),
    );

    Map<String, dynamic> toJson() => {
        "trigger_type": triggerType,
        "playing_loop": playingLoop,
        "named_region": namedRegion,
        "duration": duration,
        "transition": transition,
        "aspect_ratio": aspectRatio,
        "content_id": contentId,
        "playlist_id": playlistId,
        "campaign_id": campaignId,
        "content": List<dynamic>.from(content.map((x) => x.toJson())),
    };
}

class Content {
    String id;
    String name;
    String mediaType;
    String? mediaUrl;
    List<Zone>? zones;

    Content({
        required this.id,
        required this.name,
        required this.mediaType,
        this.mediaUrl,
        this.zones,
    });

    factory Content.fromJson(Map<String, dynamic> json) => Content(
        id: json["id"],
        name: json["name"],
        mediaType: json["mediaType"],
        mediaUrl: json["mediaUrl"],
        zones: json["zones"] == null ? [] : List<Zone>.from(json["zones"]!.map((x) => Zone.fromJson(x))),
    );

    Map<String, dynamic> toJson() => {
        "id": id,
        "name": name,
        "mediaType": mediaType,
        "mediaUrl": mediaUrl,
        "zones": zones == null ? [] : List<dynamic>.from(zones!.map((x) => x.toJson())),
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
        mediaItems: List<MediaItem>.from(json["mediaItems"].map((x) => MediaItem.fromJson(x))),
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
    DateTime start;
    DateTime? end;

    Date({
        required this.start,
        required this.end,
    });

    factory Date.fromJson(Map<String, dynamic> json) => Date(
        start: DateTime.parse(json["start"]),
        end: json["end"] == null ? null : DateTime.parse(json["end"]),
    );

    Map<String, dynamic> toJson() => {
        "start": "${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}",
        "end": "${end!.year.toString().padLeft(4, '0')}-${end!.month.toString().padLeft(2, '0')}-${end!.day.toString().padLeft(2, '0')}",
    };
}

class Days {
    bool monday;
    bool tuesday;
    bool wednesday;
    bool thursday;
    bool friday;
    bool saturday;
    bool sunday;

    Days({
        required this.monday,
        required this.tuesday,
        required this.wednesday,
        required this.thursday,
        required this.friday,
        required this.saturday,
        required this.sunday,
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

class Settings {
    String duration;
    String transition;
    bool loop;

    Settings({
        required this.duration,
        required this.transition,
        required this.loop,
    });

    factory Settings.fromJson(Map<String, dynamic> json) => Settings(
        duration: json["duration"],
        transition: json["transition"],
        loop: json["loop"],
    );

    Map<String, dynamic> toJson() => {
        "duration": duration,
        "transition": transition,
        "loop": loop,
    };
}
