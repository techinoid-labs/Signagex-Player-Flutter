import 'dart:convert';

PlayListModel playListModelFromJson(String str) => PlayListModel.fromJson(json.decode(str));

String playListModelToJson(PlayListModel data) => json.encode(data.toJson());

class PlayListModel {
  String action;
  Data data;
  String sender;

  PlayListModel({
    required this.action,
    required this.data,
    required this.sender,
  });

  factory PlayListModel.fromJson(Map<String, dynamic> json) => PlayListModel(
        action: json["action"],
        data: Data.fromJson(json["data"]),
        sender: json["sender"],
      );

  Map<String, dynamic> toJson() => {
        "action": action,
        "data": data.toJson(),
        "sender": sender,
      };
}

class Data {
  bool success;
  String message;
  String playbackType;
  Playlist playlist;

  Data({
    required this.success,
    required this.message,
    required this.playbackType,
    required this.playlist,
  });

  factory Data.fromJson(Map<String, dynamic> json) => Data(
        success: json["success"],
        message: json["message"],
        playbackType: json["playback_type"],
        playlist: Playlist.fromJson(json["playlist"]),
      );

  Map<String, dynamic> toJson() => {
        "success": success,
        "message": message,
        "playback_type": playbackType,
        "playlist": playlist.toJson(),
      };
}

class Playlist {
  dynamic name;
  String? id;
  Schedule? playlistSchedule;
  Playback? playback;
  Default? playlistDefault;
  List<Media>? media;

  Playlist({
    required this.name,
    required this.id,
    required this.playlistSchedule,
    required this.playback,
    required this.playlistDefault,
    required this.media,
  });

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
        name: json["name"],
        id: json["id"],
        playlistSchedule: Schedule.fromJson(json["playlist_schedule"]),
        playback: Playback.fromJson(json["playback"]),
        playlistDefault: Default.fromJson(json["default"]),
        media: List<Media>.from(json["media"].map((x) => Media.fromJson(x))),
      );

  Map<String, dynamic> toJson() => {
        "name": name,
        "id": id,
        "playlist_schedule": playlistSchedule!.toJson(),
        "playback": playback!.toJson(),
        "default": playlistDefault!.toJson(),
        "media": List<dynamic>.from(media!.map((x) => x.toJson())),
      };
}

class Media {
  Default settings;
  Schedule schedule;
  String mediaType;
  String mediaUrl;

  Media({
    required this.settings,
    required this.schedule,
    required this.mediaType,
    required this.mediaUrl,
  });

  factory Media.fromJson(Map<String, dynamic> json) => Media(
        settings: Default.fromJson(json["settings"]),
        schedule: Schedule.fromJson(json["schedule"]),
        mediaType: json["mediaType"],
        mediaUrl: json["mediaUrl"],
      );

  Map<String, dynamic> toJson() => {
        "settings": settings.toJson(),
        "schedule": schedule.toJson(),
        "mediaType": mediaType,
        "mediaUrl": mediaUrl,
      };
}

class Schedule {
  bool alwaysPlay;
  Period? period;

  Schedule({
    required this.alwaysPlay,
    this.period,
  });

  factory Schedule.fromJson(Map<String, dynamic> json) => Schedule(
        alwaysPlay: json["always_play"],
        period: json.containsKey("period") ? Period.fromJson(json["period"]) : null,
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
  DateTime end;

  Date({
    required this.start,
    required this.end,
  });

  factory Date.fromJson(Map<String, dynamic> json) => Date(
        start: DateTime.parse(json["start"]),
        end: DateTime.parse(json["end"]),
      );

  Map<String, dynamic> toJson() => {
        "start": "${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}",
        "end": "${end.year.toString().padLeft(4, '0')}-${end.month.toString().padLeft(2, '0')}-${end.day.toString().padLeft(2, '0')}",
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

class Default {
  String duration;
  String transition;
  String? volume;
  String? otherMediaDefaultVolume;
  String? ratio;

  Default({
    required this.duration,
    required this.transition,
    required this.volume,
    this.otherMediaDefaultVolume,
    this.ratio,
  });

  factory Default.fromJson(Map<String, dynamic> json) => Default(
        duration: json["duration"],
        transition: json["transition"],
        volume: json["volume"],
        otherMediaDefaultVolume: json.containsKey("other_media_default_volume")
            ? json["other_media_default_volume"]
            : null,
        ratio: json["ratio"],
      );

  Map<String, dynamic> toJson() => {
        "duration": duration,
        "transition": transition,
        "volume": volume,
        "other_media_default_volume": otherMediaDefaultVolume,
        "ratio": ratio,
      };
}

class Playback {
  String mode;
  int count;
  String order;

  Playback({
    required this.mode,
    required this.count,
    required this.order,
  });

  factory Playback.fromJson(Map<String, dynamic> json) => Playback(
        mode: json["mode"],
        count: json["count"],
        order: json["order"],
      );

  Map<String, dynamic> toJson() => {
        "mode": mode,
        "count": count,
        "order": order,
      };
}
