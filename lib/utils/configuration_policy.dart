/// Device-local scheduling. End is exclusive; overnight windows belong to
/// their starting weekday. An empty window list is unrestricted.
bool inConfigurationWindow(List<dynamic> windows, DateTime now) {
  if (windows.isEmpty) return true;
  int minute(String value) {
    final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(value);
    if (match == null) throw const FormatException('Expected HH:mm');
    final h = int.parse(match[1]!);
    final m = int.parse(match[2]!);
    if (h > 23 || m > 59) throw const FormatException('Invalid time');
    return h * 60 + m;
  }
  bool dayAllowed(dynamic days, int weekday) {
    if (days == null) return true;
    final mask = days is List ? (days.isEmpty ? '' : days.first.toString()) : days.toString();
    if (!RegExp(r'^[01]{7}$').hasMatch(mask)) throw const FormatException('Expected Sunday-first 7-day mask');
    return mask[weekday % 7] == '1';
  }
  final current = now.hour * 60 + now.minute;
  for (final raw in windows) {
    final window = Map<String, dynamic>.from(raw as Map);
    final from = minute(window['from']?.toString() ?? '00:00');
    final to = minute(window['to']?.toString() ?? '23:59');
    if (from == to && dayAllowed(window['days'], now.weekday)) return true;
    if (from < to && current >= from && current < to && dayAllowed(window['days'], now.weekday)) return true;
    if (from > to && ((current >= from && dayAllowed(window['days'], now.weekday)) ||
        (current < to && dayAllowed(window['days'], (now.weekday == 1 ? 7 : now.weekday - 1))))) return true;
  }
  return false;
}

/// When the next window opens after [now] (within a week), or null. Used for
/// the "Opens today at 09:00" line outside working hours.
DateTime? nextConfigurationStart(List<dynamic> windows, DateTime now) {
  DateTime? best;
  for (final raw in windows) {
    if (raw is! Map) continue;
    final from = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(raw['from']?.toString() ?? '');
    if (from == null) continue;
    final days = raw['days'];
    final mask = days is List ? (days.isEmpty ? '' : days.first.toString()) : days?.toString();
    for (var d = 0; d <= 7; d++) {
      final day = DateTime(now.year, now.month, now.day + d);
      if (mask != null && RegExp(r'^[01]{7}$').hasMatch(mask) && mask[day.weekday % 7] != '1') continue;
      final start = DateTime(day.year, day.month, day.day, int.parse(from[1]!), int.parse(from[2]!));
      if (start.isAfter(now) && (best == null || start.isBefore(best))) best = start;
    }
  }
  return best;
}

/// Outside-working-hours modes the CMS can choose (Android's WorkingHours.Mode).
const offHoursModes = <String>{'display_off', 'black_screen', 'message', 'content', 'continue'};

int configurationPercent(dynamic raw) {
  final value = num.tryParse(raw.toString());
  if (value == null || !value.isFinite || value < 0 || value > 100 || value != value.roundToDouble()) {
    throw const FormatException('Expected a whole percentage from 0 to 100');
  }
  return value.toInt();
}

const linuxConfigurationKeys = <String>{
  'launch_on_boot', 'apply_app_updates', 'hide_no_campaign_messages',
  'touch_feedback', 'use_html5_webview', 'safe_video_mode', 'screen_rotation',
  'reboot', 'volume', 'volume_timeout', 'mute_audio', 'disable_transitions',
  'brightness', 'logo', 'working_schedule', 'content_update_interval',
};
