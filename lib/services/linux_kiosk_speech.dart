import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/debug_log.dart' as debug;

/// Read-aloud for kiosk pages on Linux.
///
/// Kiosk pages read a screen with the browser's speechSynthesis. The embedded
/// browser (CEF) has that API but no speech engine on Linux, so it accepts
/// the text and stays silent. [kioskSpeechShim] replaces the API in the page
/// with one that hands the text to the player, and this speaks it with
/// espeak-ng through the normal sound output (PipeWire/PulseAudio).
class KioskSpeech {
  KioskSpeech({Future<Process> Function(String, List<String>)? start})
      : _start = start ?? Process.start;

  static final instance = KioskSpeech();

  /// The JavaScript channel the page posts to.
  static const channel = 'SxKioskSpeech';

  /// Longest text spoken in one go (a whole screen is far shorter).
  static const maxChars = 4000;

  final Future<Process> Function(String, List<String>) _start;
  final List<({String text, String lang, double rate})> _queue = [];
  Process? _current;
  // Set synchronously while one item is starting or speaking, so a second
  // request can never start a second voice while the first is launching.
  bool _busy = false;
  // Bumped by cancel(), so a voice still launching is stopped once it starts.
  int _generation = 0;
  bool _reportedMissing = false;

  /// A message from the page: {"a":"speak","text","lang","rate"} or {"a":"cancel"}.
  void handle(String raw) {
    Map? message;
    try {
      final value = jsonDecode(raw);
      if (value is Map) message = value;
    } catch (_) {}
    if (message == null) return;
    if (message['a'] == 'cancel') {
      cancel();
      return;
    }
    if (message['a'] != 'speak') return;
    final text = '${message['text'] ?? ''}'.trim();
    if (text.isEmpty) return;
    // Length and language only: the text may hold what a customer typed.
    log('read-aloud: ${text.length} characters (${message['lang'] ?? ''})');
    final rate = message['rate'];
    _queue.add((
      text: text.length > maxChars ? text.substring(0, maxChars) : text,
      lang: '${message['lang'] ?? ''}',
      rate: rate is num && rate.isFinite ? rate.toDouble() : 1.0,
    ));
    unawaited(_next());
  }

  void log(String message) => unawaited(debug.debugLog('Kiosk', message));

  /// Stops speaking and drops anything queued (new screen, session end).
  void cancel() {
    _queue.clear();
    _generation++;
    final current = _current;
    _current = null;
    current?.kill();
  }

  Future<void> _next() async {
    if (_busy || _queue.isEmpty) return;
    _busy = true;
    final generation = _generation;
    final item = _queue.removeAt(0);
    final Process process;
    try {
      process = await _start('espeak-ng', espeakArguments(item.lang, item.rate));
    } on ProcessException catch (e) {
      _queue.clear();
      _busy = false;
      if (!_reportedMissing) {
        _reportedMissing = true;
        unawaited(debug.debugLog('Kiosk',
            'read-aloud needs espeak-ng (sudo apt install espeak-ng): ${e.message}'));
      }
      return;
    } catch (_) {
      _busy = false;
      return;
    }
    if (generation != _generation) {
      // Cancelled while it was launching.
      process.kill();
      _busy = false;
      unawaited(_next());
      return;
    }
    _current = process;
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    // The text goes on stdin, never on the command line.
    try {
      process.stdin.write(item.text);
      await process.stdin.close();
    } catch (_) {}
    await process.exitCode;
    if (identical(_current, process)) _current = null;
    _busy = false;
    unawaited(_next());
  }
}

/// espeak-ng arguments: voice from the page's language, speed from its rate.
List<String> espeakArguments(String lang, double rate) => [
      '-v',
      espeakVoice(lang),
      '-s',
      '${(175 * rate).clamp(80, 450).round()}',
      '--stdin',
    ];

/// The espeak-ng voice for a BCP 47 language code ('en', 'es-MX', 'fr-CA'...).
String espeakVoice(String lang) {
  final code = lang.trim().toLowerCase().replaceAll('_', '-');
  if (!RegExp(r'^[a-z]{2,3}(-[a-z0-9]{2,8})*$').hasMatch(code)) return 'en-us';
  final primary = code.split('-').first;
  switch (primary) {
    case 'en':
      return const {'en-gb', 'en-ie', 'en-au', 'en-nz', 'en-za', 'en-in'}.any(code.startsWith)
          ? 'en-gb'
          : 'en-us';
    case 'es':
      return code == 'es-es' ? 'es' : 'es-419';
    case 'pt':
      return code == 'pt-pt' ? 'pt' : 'pt-br';
    default:
      return primary;
  }
}

/// Replaces the page's speechSynthesis with one that posts to the player.
/// Safe to run more than once.
const kioskSpeechShim = r'''
(function () {
  if (window.__sxKioskSpeech) return;
  window.__sxKioskSpeech = true;
  function post(m) {
    try { SxKioskSpeech(JSON.stringify(m)); } catch (e) {}
  }
  function Utterance(text) {
    this.text = text == null ? '' : String(text);
    this.lang = ''; this.rate = 1; this.pitch = 1; this.volume = 1; this.voice = null;
    this.onstart = null; this.onend = null; this.onerror = null;
    this.onpause = null; this.onresume = null; this.onboundary = null; this.onmark = null;
  }
  Utterance.prototype.addEventListener = function () {};
  Utterance.prototype.removeEventListener = function () {};
  var synth = {
    speaking: false, pending: false, paused: false, onvoiceschanged: null,
    speak: function (u) {
      if (!u) return;
      post({ a: 'speak', text: String(u.text || ''), lang: u.lang || document.documentElement.lang || '', rate: Number(u.rate) || 1 });
    },
    cancel: function () { post({ a: 'cancel' }); },
    pause: function () {}, resume: function () {},
    getVoices: function () { return []; },
    addEventListener: function () {}, removeEventListener: function () {}
  };
  try { Object.defineProperty(window, 'SpeechSynthesisUtterance', { value: Utterance, configurable: true, writable: true }); } catch (e) { window.SpeechSynthesisUtterance = Utterance; }
  try { Object.defineProperty(window, 'speechSynthesis', { value: synth, configurable: true }); } catch (e) { window.speechSynthesis = synth; }
})();
''';
