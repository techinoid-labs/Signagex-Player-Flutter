// W12 follow-up (see player-remediation-handover/02-detailed-audit.md): the
// original audit's overnight-wraparound fix was applied to only one of four
// "is current time within [from, to]" checks in this codebase
// (MqttViewModel._checkTimeRestriction). The other three --
// MqttViewModel._isTimeInRange, MqttViewModel._isTimeInRangeForCampaign, and
// the two call sites inside play_list_view.dart -- are the same bug: with
// both boundaries anchored to today's date, an overnight window like
// "22:00-06:00" has end < start, so "now is after start AND before end" can
// never be true. This is the single shared implementation all of them should
// use instead of re-deriving the same logic four times.
//
// Seconds are optional in the "HH:mm[:ss]" input -- confirmed against
// compaign_model.dart's own ad-flight time parser, which already treats a
// missing seconds component as 0 rather than assuming it's always present.
// The previous duplicates that did `.split(':')[2]` unconditionally would
// throw a RangeError on any "HH:mm" value.
// Named ClockTime (not TimeOfDay) to avoid colliding with Flutter material's
// own TimeOfDay class in any file that imports both unprefixed.
class ClockTime {
  final int hour;
  final int minute;
  final int second;

  const ClockTime({required this.hour, required this.minute, this.second = 0});

  int get secondsSinceMidnight => hour * 3600 + minute * 60 + second;
}

ClockTime parseClockTime(String value) {
  final parts = value.split(':');
  final hour = int.parse(parts[0].trim());
  final minute = parts.length > 1 ? int.parse(parts[1].trim()) : 0;
  final second = parts.length > 2 ? int.parse(parts[2].trim()) : 0;
  return ClockTime(hour: hour, minute: minute, second: second);
}

/// Whether [now]'s time-of-day falls within ["timeFrom", "timeTo"]
/// (inclusive), each "HH:mm" or "HH:mm:ss". When [timeTo] is earlier in the
/// day than [timeFrom], the range is treated as wrapping past midnight (e.g.
/// "22:00"-"06:00" matches 23:00 and 01:00, not neither).
bool isNowInTimeRange(String timeFrom, String timeTo, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final nowSeconds =
      current.hour * 3600 + current.minute * 60 + current.second;
  final fromSeconds = parseClockTime(timeFrom).secondsSinceMidnight;
  final toSeconds = parseClockTime(timeTo).secondsSinceMidnight;

  if (toSeconds < fromSeconds) {
    return nowSeconds >= fromSeconds || nowSeconds <= toSeconds;
  }
  return nowSeconds >= fromSeconds && nowSeconds <= toSeconds;
}
