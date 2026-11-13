import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/configuration_policy.dart';
import 'linux_remote_backend.dart'
    show linuxDisplaySession, LinuxDisplaySession, LinuxRemoteBackend;
import '../utils/transitions.dart';
import 'linux_wayland_rotation.dart';

typedef LinuxCommand = Future<String> Function(
    String executable, List<String> arguments);

/// Persistent desired state, serialized application, and bounded background work.
class LinuxConfiguration extends ChangeNotifier {
  static final instance = LinuxConfiguration();
  LinuxConfiguration({LinuxCommand? command, DateTime Function()? clock})
      : command = command ?? runCommand,
        clock = clock ?? DateTime.now;
  final LinuxCommand command;
  final DateTime Function() clock;
  Map<String, dynamic> values = {};
  Map<String, dynamic> results = {};
  int revision = 0;
  String? _registrationScope;
  bool working = true;

  /// Outside the working schedule, what the screen shows (the CMS
  /// "Outside working hours" choice, same rules as Android): black_screen,
  /// display_off, message or content. "continue" keeps [working] true.
  String offHoursMode = 'black_screen';
  String? offHoursMessage;
  /// The off-hours picture or video once downloaded; null shows black.
  String? offHoursMediaPath;
  bool offHoursVideo = false;
  /// When the schedule next opens, for "Opens today at 09:00".
  DateTime? opensAt;
  String? _offHoursMediaUrl;
  bool _displayForcedOff = false;
  bool get hideMessages => values['hide_no_campaign_messages'] == true;
  bool get touchFeedback => values['touch_feedback'] == true;
  bool get disableTransitions => values['disable_transitions'] == true;
  bool get safeVideo => values['safe_video_mode'] == true;
  bool _started = false;
  bool startupSafeVideo = false;
  bool _updatePermission = false;
  bool _ticking = false;
  bool _closed = false;
  String? _lastMute;
  int? _lastBrightness;
  int? _previousVolume;
  DateTime? _volumeUntil;
  DateTime? _brightnessUntil;
  DateTime? _lastDownload;
  Timer? _timer;
  Future<void> _queue = Future.value();
  Future<void> Function(String, String)? event;

  static Future<String> runCommand(
      String executable, List<String> arguments) async {
    final result = await Process.run(executable, arguments)
        .timeout(const Duration(seconds: 15));
    if (result.exitCode != 0)
      throw StateError('$executable: ${result.stderr}'.substring(
          0, ('$executable: ${result.stderr}').length.clamp(0, 300)));
    return result.stdout.toString().trim();
  }

  /// The managed updater is installed and this user may run it (polkit group).
  bool get managedUpdates =>
      File('/usr/lib/signagex-player/update-player').existsSync() && _updatePermission;

  /// The SignageX kiosk session (SIGNAGEX_KIOSK=1) always starts the player at
  /// boot itself and runs no XDG autostart, so "Launch on boot" cannot apply there.
  static bool get kiosk => Platform.environment['SIGNAGEX_KIOSK'] == '1';

  /// Brightness is applied with xrandr, which only drives X11 outputs, so on
  /// the Wayland (cage) kiosk it is reported as unsupported. Rotation works
  /// there through wlr-randr when it is installed (WaylandRotation).
  static bool get wayland =>
      debugWaylandOverride ??
      linuxDisplaySession() == LinuxDisplaySession.wayland;

  /// Tests set this so they don't depend on the session they run in
  /// (a developer's desktop is often Wayland).
  @visibleForTesting
  static bool? debugWaylandOverride;
  static const _x11OnlyKeys = {'brightness'};

  /// wlr-randr is installed, so rotation works on the Wayland kiosk.
  bool waylandRotation = false;

  /// Remote-view input works here. X11 always has xdotool (a package
  /// dependency); Wayland needs python3-evdev and a writable /dev/uinput.
  bool remoteInput = true;

  Map<String, dynamic> get capabilities => {
        'protocol': 1,
        'platform': 'linux',
        'settings': {
          for (final key in linuxConfigurationKeys)
            key: key == 'use_html5_webview' ||
                    (key == 'launch_on_boot' && kiosk) ||
                    (wayland && _x11OnlyKeys.contains(key)) ||
                    (wayland && key == 'screen_rotation' && !waylandRotation)
                ? 'unsupported'
                : key == 'apply_app_updates' &&
                        (!File('/usr/lib/signagex-player/update-player')
                                .existsSync() ||
                            !_updatePermission)
                    ? 'unsupported'
                    : 'supported',
        },
        'interactivity': {
          'touch': true,
          'key': true,
          'on_demand': true,
          'specific_time': true,
          'idle_timeout': true,
          'local_api': 'authenticated-loopback',
          'recurring': true
        },
        'brightness_kind': 'software',
        'display_session': wayland ? 'wayland' : 'x11',
        'remote_input': remoteInput,
        'schedule_timezone': 'device-local',
      };

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      _updatePermission = (await command('id', ['-nG']))
          .split(RegExp(r'\s+'))
          .contains('signagex-updates');
    } catch (_) {}
    if (wayland) remoteInput = await LinuxRemoteBackend.instance.inputAvailable();
    if (wayland) waylandRotation = await WaylandRotation.instance.available();
    final prefs = await SharedPreferences.getInstance();
    try {
      final stored =
          jsonDecode(prefs.getString('linux_configuration') ?? '{}') as Map;
      values = Map<String, dynamic>.from(stored['values'] ?? {});
      revision = (stored['revision'] as num?)?.toInt() ?? 0;
      _registrationScope = stored['registration_scope'] as String?;
      results = Map<String, dynamic>.from(stored['results'] ?? {});
      final volume = stored['volume_restore'] as Map?;
      if (volume != null) {
        _previousVolume = (volume['value'] as num).toInt();
        _volumeUntil = DateTime.tryParse(volume['until'].toString());
      }
      _brightnessUntil =
          DateTime.tryParse(stored['brightness_until']?.toString() ?? '');
    } catch (_) {
      values = {};
      revision = 0;
    }
    disableConfiguredTransitions = disableTransitions;
    startupSafeVideo = safeVideo;
    if (results['safe_video_mode'] != null)
      results['safe_video_mode'] = {
        'status': 'applied',
        'message': '',
        'value': safeVideo
      };
    for (final key in ['screen_rotation', 'volume']) {
      if (values.containsKey(key)) {
        try {
          await _validateAndApply(key, values[key]);
        } on UnsupportedError catch (error) {
          results[key] = {'status': 'unsupported', 'message': error.message};
        } catch (error) {
          results[key] = {'status': 'failed', 'message': error.toString()};
        }
      }
    }
    // A rotation sent the older way (settings message), or ROTATE from the
    // kiosk settings: the compositor forgot it when it restarted.
    if (wayland && waylandRotation && !values.containsKey('screen_rotation')) {
      await WaylandRotation.instance.restore();
    }
    _timer =
        Timer.periodic(const Duration(seconds: 15), (_) => unawaited(tick()));
    await tick();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'linux_configuration',
        jsonEncode({
          'values': values,
          'revision': revision,
          'registration_scope': _registrationScope,
          'results': results,
          if (_previousVolume != null && _volumeUntil != null)
            'volume_restore': {
              'value': _previousVolume,
              'until': _volumeUntil!.toIso8601String()
            },
          if (_brightnessUntil != null)
            'brightness_until': _brightnessUntil!.toIso8601String(),
        }));
  }

  Future<Map<String, dynamic>> apply(Map<String, dynamic> settings,
      {String? registrationScope}) async {
    final completer = Completer<Map<String, dynamic>>();
    _queue = _queue.catchError((_) {}).then((_) async {
      try {
        completer.complete(await _apply(settings, registrationScope));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<Map<String, dynamic>> _apply(
      Map<String, dynamic> settings, String? registrationScope) async {
    await start();
    // Revisions belong to a CMS player record, not this disk. Reinstalling,
    // re-pairing or moving between environments can reuse the pairing code
    // while starting the server revision counter again. Only an authoritative
    // registration response supplies this scope; ordinary MQTT settings may
    // not reset replay protection. Preserve desired values so unchanged
    // controls do not flicker while adopting the new record's revision.
    if (registrationScope != null &&
        registrationScope.isNotEmpty &&
        registrationScope != _registrationScope) {
      _registrationScope = registrationScope;
      revision = 0;
    }
    final incoming = (settings['configuration_revision'] as num?)?.toInt() ?? 0;
    if (incoming > 0 && incoming <= revision) return acknowledgement;
    final orderedKeys = [
      'volume_timeout',
      ...linuxConfigurationKeys.where((key) => key != 'volume_timeout')
    ];
    for (final key in orderedKeys) {
      if (!settings.containsKey(key)) continue;
      // The CMS schema includes null scalar defaults even when a setting has
      // never been configured. They are not device commands. Explicit false,
      // zero and rotation "0" remain meaningful and must still be applied.
      if (settings[key] == null && !const {'working_schedule','content_update_interval','brightness','logo','reboot'}.contains(key)) {
        if (!values.containsKey(key)) results.remove(key);
        continue;
      }
      final value = settings[key] ??
          (key == 'working_schedule'
              ? {'type': 'always', 'schedule': []}
              : key == 'content_update_interval'
                  ? {'interval': 'realtime', 'schedule': []}
                  : key == 'brightness'
                      ? {'value': 100, 'mode': 'manual'}
                      : key == 'logo' || key == 'reboot'
                          ? <String, dynamic>{}
                          : null);
      final previous = values[key];
      if (results[key]?['status'] == 'applied' &&
          jsonEncode(previous) == jsonEncode(value)) continue;
      try {
        await _validateAndApply(key, value);
        values[key] = value;
        results[key] = {
          'status': key == 'safe_video_mode' && startupSafeVideo != value
              ? 'pending'
              : 'applied',
          'value': key == 'safe_video_mode' && startupSafeVideo != value
              ? startupSafeVideo
              : value,
          'message': key == 'safe_video_mode' && startupSafeVideo != value
              ? 'Decoder preference saved; applies at next player start'
              : ''
        };
      } on UnsupportedError catch (error) {
        results[key] = {'status': 'unsupported', 'message': error.message};
      } catch (error) {
        results[key] = {
          'status': 'failed',
          'message': error
              .toString()
              .substring(0, error.toString().length.clamp(0, 300))
        };
      }
    }
    revision = incoming > 0 ? incoming : revision;
    disableConfiguredTransitions = disableTransitions;
    await _persist();
    await tick();
    notifyListeners();
    return acknowledgement;
  }

  Map<String, dynamic> get acknowledgement => {
        'action': 'settings_applied',
        'revision': revision,
        'results': results,
        'sender': 'Linux'
      };

  Future<String> _output() async {
    final output = await command('xrandr', ['--query']);
    final matches = RegExp(r'^(\S+) connected(?: primary)?', multiLine: true)
        .allMatches(output)
        .toList();
    if (matches.isEmpty) throw StateError('No connected X11 display');
    final primary = matches.where((m) => m[0]!.contains('primary'));
    return (primary.isEmpty ? matches.first : primary.first)[1]!;
  }

  Future<void> _validateAndApply(String key, dynamic value) async {
    if (wayland && _x11OnlyKeys.contains(key)) {
      throw UnsupportedError('Brightness control needs an X11 session');
    }
    if (wayland && key == 'screen_rotation' && !waylandRotation) {
      throw UnsupportedError(
          'Rotation on the Wayland kiosk needs wlr-randr (sudo apt install wlr-randr)');
    }
    const booleanKeys = {
      'launch_on_boot',
      'apply_app_updates',
      'hide_no_campaign_messages',
      'touch_feedback',
      'use_html5_webview',
      'safe_video_mode',
      'mute_audio',
      'disable_transitions'
    };
    if (booleanKeys.contains(key) && value is! bool)
      throw const FormatException('Expected boolean');
    if (key == 'use_html5_webview' && value == true)
      throw UnsupportedError(
          'Legacy Android WebView is unavailable on Linux; CEF is used');
    if (key == 'launch_on_boot' && kiosk) {
      // Reported as unsupported; never recreate the desktop autostart entry here.
      return;
    } else if (key == 'launch_on_boot') {
      if (value == true) {
        final unit = File(
            '${Platform.environment['HOME']}/.config/systemd/user/signagex-player.service');
        if (!await unit.exists()) {
          final installer = File(
              '${File(Platform.resolvedExecutable).parent.path}/kiosk/install-user-service.sh');
          if (!await installer.exists())
            throw UnsupportedError(
                'Install the supervised startup service first');
          await command(installer.path, []);
        }
      }
      final dir =
          Directory('${Platform.environment['HOME']}/.config/autostart');
      await dir.create(recursive: true);
      await File('${dir.path}/signagex-player.desktop').writeAsString(
          '[Desktop Entry]\nType=Application\nName=SignageX Player\nExec=${File('/usr/bin/signagex-player-start-supervised').existsSync() ? '/usr/bin/signagex-player-start-supervised' : '${Platform.environment['HOME']}/.local/bin/signagex-start-supervised'}\nHidden=${value == false}\nX-GNOME-Autostart-enabled=$value\n');
    } else if (key == 'apply_app_updates' &&
        value == true &&
        (!File('/usr/lib/signagex-player/update-player').existsSync() ||
            !_updatePermission)) {
      throw UnsupportedError(
          'Install the managed updater and ask an administrator to enable update permission first');
    } else if (key == 'screen_rotation' && wayland) {
      await WaylandRotation.instance.apply(value.toString());
    } else if (key == 'screen_rotation') {
      final direction = {
        '0': 'normal',
        '90': 'right',
        '180': 'inverted',
        '270': 'left'
      }[value.toString()];
      if (direction == null)
        throw const FormatException('Rotation must be 0, 90, 180 or 270');
      await command(
          'xrandr', ['--output', await _output(), '--rotate', direction]);
    } else if (key == 'volume') {
      final percent = configurationPercent(value);
      if ((values['volume_timeout'] as num? ?? 0) > 0) {
        final current =
            await command('wpctl', ['get-volume', '@DEFAULT_AUDIO_SINK@']);
        _previousVolume ??= ((double.tryParse(RegExp(r'Volume:\s*([0-9.]+)')
                            .firstMatch(current)?[1] ??
                        '') ??
                    0.4) *
                100)
            .round();
        _volumeUntil = clock()
            .add(Duration(minutes: (values['volume_timeout'] as num).toInt()));
      }
      await command(
          'wpctl', ['set-volume', '@DEFAULT_AUDIO_SINK@', '$percent%']);
    } else if (key == 'mute_audio') {
      await command('wpctl', [
        'set-mute',
        '@DEFAULT_AUDIO_SINK@',
        value == true || !working ? '1' : '0'
      ]);
      _lastMute = value == true || !working ? '1' : '0';
    } else if (key == 'volume_timeout') {
      final number = num.tryParse(value.toString());
      if (number == null ||
          number < 0 ||
          number > 1000 ||
          number != number.roundToDouble())
        throw const FormatException('Timeout must be 0–1000 minutes');
      if (number == 0) {
        _volumeUntil = null;
        _previousVolume = null;
      }
    } else if (key == 'brightness') {
      final map = Map<String, dynamic>.from(value as Map);
      configurationPercent(map['value'] ?? 100);
      if (!['manual', 'schedule'].contains(map['mode'] ?? 'manual'))
        throw const FormatException('Invalid brightness mode');
      for (final window in (map['schedule'] as List? ?? [])) {
        configurationPercent(window['value']);
        inConfigurationWindow([window], clock());
      }
      final timeout = (map['timeout'] as num? ?? 0).toInt();
      if (map['mode'] == 'schedule' && timeout > 0)
        throw const FormatException(
            'Brightness timeout applies to manual mode only');
      if (timeout < 0 || timeout > 1000)
        throw const FormatException('Invalid brightness timeout');
      _brightnessUntil =
          timeout > 0 ? clock().add(Duration(minutes: timeout)) : null;
      final percent = _brightness(map, clock());
      await command('xrandr', [
        '--output',
        await _output(),
        '--brightness',
        (percent / 100).toStringAsFixed(2)
      ]);
      _lastBrightness = percent;
    } else if (key == 'working_schedule') {
      final map = Map<String, dynamic>.from(value as Map);
      if (!['always', 'custom'].contains(
          map['type'] ?? (map['schedule'] == null ? 'always' : 'custom')))
        throw const FormatException('Invalid working schedule');
      inConfigurationWindow(map['schedule'] as List? ?? [], clock());
    } else if (key == 'content_update_interval') {
      final map = Map<String, dynamic>.from(value as Map);
      final interval = int.tryParse((map['interval'] ?? '60').toString());
      if (map['interval'] != 'realtime' &&
          (interval == null || interval < 1 || interval > 86400))
        throw const FormatException('Invalid update interval');
      if (!['none', 'wifi', 'wired', '']
          .contains(map['download_restrictions'] ?? 'none'))
        throw const FormatException('Invalid download restriction');
      if (map['data_saving_mode'] != null && map['data_saving_mode'] is! bool)
        throw const FormatException('Invalid data saving value');
      inConfigurationWindow(map['schedule'] as List? ?? [], clock());
    } else if (key == 'reboot') {
      final map = Map<String, dynamic>.from(value as Map);
      if (map['day'] == null || map['day'] == '' || map['day'] == 'none')
        return;
      if (![
        'monday',
        'tuesday',
        'wednesday',
        'thursday',
        'friday',
        'saturday',
        'sunday',
        'daily'
      ].contains(map['day']))
        throw const FormatException('Expected weekday or daily');
      inConfigurationWindow([
        {'from': map['time'], 'to': map['time']}
      ], clock());
    } else if (key == 'logo') {
      final map = Map<String, dynamic>.from(value as Map);
      if (map['remove'] == true || map['url'] == null || map['url'] == '')
        return;
      final uri = Uri.parse(map['url'].toString());
      if (uri.scheme != 'https')
        throw const FormatException('Logo requires HTTPS');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final response = await (await client.getUrl(uri))
            .close()
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200)
          throw StateError('Logo HTTP ${response.statusCode}');
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 2 * 1024 * 1024)
            throw StateError('Logo exceeds 2 MB');
        }
        final dir = Directory(
            '${Platform.environment['HOME']}/.local/share/signagex-player');
        await dir.create(recursive: true);
        final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes),
            targetWidth: 320, targetHeight: 96, allowUpscaling: false);
        final frame = await codec.getNextFrame();
        frame.image.dispose();
        codec.dispose();
        final file = File('${dir.path}/custom-logo');
        await file.writeAsBytes(bytes);
        await FileImage(file).evict();
      } finally {
        client.close(force: true);
      }
    }
  }

  /// The off-hours picture or video (CMS "Show content"), kept on disk so it
  /// shows offline too. A failure leaves the screen black, never playback.
  Future<void> _downloadOffHoursMedia(String url, Map? content) async {
    final kind = '${content?['kind'] ?? ''}'.toLowerCase();
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    final video = kind.contains('video') ||
        RegExp(r'\.(mp4|webm|mov|mkv|m4v)$').hasMatch(path);
    final dir = Directory(
        '${Platform.environment['HOME']}/.local/share/signagex-player/off-hours');
    final name = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    final file = File('${dir.path}/${name.length > 120 ? name.substring(name.length - 120) : name}');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      if (!await file.exists() || await file.length() == 0) {
        await dir.create(recursive: true);
        final response = await (await client.getUrl(Uri.parse(url)))
            .close()
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          throw StateError('HTTP ${response.statusCode}');
        }
        final partial = File('${file.path}.part');
        final sink = partial.openWrite();
        var size = 0;
        try {
          await for (final chunk in response) {
            size += chunk.length;
            if (size > 500 * 1024 * 1024) throw StateError('larger than 500 MB');
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        await partial.rename(file.path);
      }
      if (_offHoursMediaUrl != url) return;
      offHoursMediaPath = file.path;
      offHoursVideo = video;
      notifyListeners();
    } catch (error) {
      await event?.call('Off-hours content could not be downloaded: $error', 'warning');
    } finally {
      client.close(force: true);
    }
  }

  /// "Display off" outside working hours: X11 powers the screen down with
  /// DPMS (forced again each tick, in case something woke it) and back on at
  /// opening time. Wayland has no portable way, so the screen is black there.
  Future<void> _applyDisplayOff(bool off) async {
    if (wayland) return;
    try {
      if (off) {
        if (!_displayForcedOff) await command('xset', ['+dpms']);
        await command('xset', ['dpms', 'force', 'off']);
        _displayForcedOff = true;
      } else if (_displayForcedOff) {
        _displayForcedOff = false;
        await command('xset', ['dpms', 'force', 'on']);
        // The kiosk keeps the screen from ever blanking on its own.
        await command('xset', ['-dpms']);
      }
    } catch (error) {
      await event?.call('Display power change failed: $error', 'warning');
    }
  }

  String? get logoPath => (values['logo'] as Map?)?['remove'] == true ||
          (values['logo'] as Map?)?['url'] == null
      ? null
      : File('${Platform.environment['HOME']}/.local/share/signagex-player/custom-logo')
              .existsSync()
          ? '${Platform.environment['HOME']}/.local/share/signagex-player/custom-logo'
          : null;
  bool get removeLogo => (values['logo'] as Map?)?['remove'] == true;

  int _brightness(Map map, DateTime now) {
    if (map['mode'] == 'schedule') {
      for (final window in (map['schedule'] as List? ?? [])) {
        if (inConfigurationWindow([window], now))
          return configurationPercent(window['value']);
      }
    }
    return configurationPercent(map['value'] ?? 100);
  }

  Future<void> tick() async {
    if (_ticking || _closed) return;
    _ticking = true;
    try {
      final now = clock();
      final schedule = values['working_schedule'] as Map?;
      final windows = schedule?['schedule'] as List? ?? [];
      var active = schedule == null ||
          schedule['type'] == 'always' ||
          inConfigurationWindow(windows, now);
      final off = schedule?['off_hours'] is Map
          ? Map<String, dynamic>.from(schedule!['off_hours'] as Map)
          : <String, dynamic>{};
      var mode = offHoursModes.contains(off['mode']) ? off['mode'] as String : 'black_screen';
      // "Keep playing" outside hours is simply never closed.
      if (!active && mode == 'continue') active = true;
      final message = off['message']?.toString().trim();
      final content = off['content'] is Map ? off['content'] as Map : null;
      final url = content?['url']?.toString() ?? '';
      // Without a message or content to show, those modes are black, never playback.
      if (mode == 'message' && (message == null || message.isEmpty)) mode = 'black_screen';
      if (mode == 'content' && !url.startsWith('https://')) mode = 'black_screen';
      final opens = active ? null : nextConfigurationStart(windows, now);
      final changed = working != active ||
          offHoursMode != mode ||
          offHoursMessage != (mode == 'message' ? message : null) ||
          opensAt != opens;
      working = active;
      offHoursMode = mode;
      offHoursMessage = mode == 'message' ? message : null;
      opensAt = opens;
      if (!active && mode == 'content' && url != _offHoursMediaUrl) {
        _offHoursMediaUrl = url;
        offHoursMediaPath = null;
        unawaited(_downloadOffHoursMedia(url, content));
      }
      await _applyDisplayOff(!active && mode == 'display_off');
      if (changed) {
        notifyListeners();
        await event?.call(
            'Working schedule ${active ? 'active' : 'inactive ($mode)'}', 'info');
      }
      final mute = values['mute_audio'] == true || !working ? '1' : '0';
      if (_lastMute != mute &&
          (values.containsKey('mute_audio') || !working || _lastMute != null)) {
        await command('wpctl', ['set-mute', '@DEFAULT_AUDIO_SINK@', mute]);
        _lastMute = mute;
      }
      if (_volumeUntil != null && !now.isBefore(_volumeUntil!)) {
        await command('wpctl',
            ['set-volume', '@DEFAULT_AUDIO_SINK@', '${_previousVolume!}%']);
        _volumeUntil = null;
        _previousVolume = null;
        await _persist();
      }
      final brightness = values['brightness'] as Map?;
      if (brightness != null && !wayland) {
        final expired =
            _brightnessUntil != null && !now.isBefore(_brightnessUntil!);
        final percent = expired ? 100 : _brightness(brightness, now);
        if (_lastBrightness != percent) {
          await command('xrandr', [
            '--output',
            await _output(),
            '--brightness',
            (percent / 100).toStringAsFixed(2)
          ]);
          _lastBrightness = percent;
        }
      }
      final reboot = values['reboot'] as Map?;
      const weekdays = [
        'monday',
        'tuesday',
        'wednesday',
        'thursday',
        'friday',
        'saturday',
        'sunday'
      ];
      final day = reboot?['day'];
      if ((day == 'daily' || day == weekdays[now.weekday - 1]) &&
          reboot?['time'] ==
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}') {
        final prefs = await SharedPreferences.getInstance();
        final key = '${now.year}-${now.month}-${now.day}-${reboot!['time']}';
        if (prefs.getString('linux_last_scheduled_reboot') != key) {
          await prefs.setString('linux_last_scheduled_reboot', key);
          await event?.call('Scheduled reboot', 'info');
          await command('systemctl', ['--no-ask-password', 'reboot']);
        }
      }
    } catch (error) {
      await event?.call('Configuration schedule: $error', 'error');
    } finally {
      _ticking = false;
    }
  }

  /// Wait outside the transfer so a closed download window never falls back
  /// to streaming an uncached network URL. Management MQTT stays connected.
  Future<void> waitForDownload({String? destination}) async {
    while (!_closed) {
      if (await allowsDownload(checkInterval: false, destination: destination))
        return;
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    throw StateError('Player stopped before download');
  }

  Future<bool> allowsDownload(
      {bool checkInterval = true, String? destination}) async {
    final policy = values['content_update_interval'] as Map? ?? {};
    final interval = int.tryParse((policy['interval'] ?? '0').toString()) ?? 0;
    if (policy['data_saving_mode'] == true ||
        !inConfigurationWindow(policy['schedule'] as List? ?? [], clock()))
      return false;
    if (checkInterval &&
        _lastDownload != null &&
        clock().difference(_lastDownload!).inSeconds < interval) return false;
    final restriction = policy['download_restrictions'];
    if (restriction == 'wifi' || restriction == 'wired') {
      final host =
          destination == null ? '1.1.1.1' : Uri.parse(destination).host;
      final addresses = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 10));
      var viable = false;
      for (final address in addresses) {
        String route;
        try {
          route = await command('ip', [
            if (address.type == InternetAddressType.IPv6) '-6',
            'route',
            'get',
            address.address
          ]);
        } catch (_) {
          continue;
        }
        final device = RegExp(r'\bdev\s+(\S+)').firstMatch(route)?[1];
        if (device == null) continue;
        viable = true;
        final type = await command(
            'nmcli', ['-g', 'GENERAL.TYPE', 'device', 'show', device]);
        if (restriction == 'wifi'
            ? type.trim() != 'wifi'
            : type.trim() != 'ethernet') return false;
      }
      return viable;
    }
    return true;
  }

  void markContentUpdate() {
    _lastDownload = clock();
  }

  void close() {
    _closed = true;
    _timer?.cancel();
  }
}
