import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:digital_signage/services/linux_kiosk_speech.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for espeak-ng: records its arguments and stdin, exits on demand.
class _FakeProcess implements Process {
  _FakeProcess(this.arguments);
  final List<String> arguments;
  final _exit = Completer<int>();
  final _stdin = StreamController<List<int>>();
  final spoken = StringBuffer();
  bool killed = false;
  late final IOSink _sink = IOSink(_stdin.sink)..done.ignore();

  void listen() => _stdin.stream.listen((b) => spoken.write(utf8.decode(b)));
  void finish() { if (!_exit.isCompleted) _exit.complete(0); }

  @override
  IOSink get stdin => _sink;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    finish();
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<_FakeProcess> started;
  late KioskSpeech speech;

  setUp(() {
    started = [];
    speech = KioskSpeech(start: (exe, args) async {
      expect(exe, 'espeak-ng');
      final p = _FakeProcess(args)..listen();
      started.add(p);
      return p;
    });
  });

  String speak(String text, {String lang = 'en', num rate = 1}) =>
      jsonEncode({'a': 'speak', 'text': text, 'lang': lang, 'rate': rate});

  test('voice follows the page language', () {
    expect(espeakVoice('en'), 'en-us');
    expect(espeakVoice('en-GB'), 'en-gb');
    expect(espeakVoice('es'), 'es-419');
    expect(espeakVoice('es-ES'), 'es');
    expect(espeakVoice('fr-CA'), 'fr');
    expect(espeakVoice(''), 'en-us');
    expect(espeakVoice('bad value; rm'), 'en-us');
    expect(espeakArguments('en', 1), ['-v', 'en-us', '-s', '175', '--stdin']);
    expect(espeakArguments('en', 99)[3], '450');
  });

  test('text is spoken through stdin, never on the command line', () async {
    speech.handle(speak('Welcome. Choose a service', lang: 'es'));
    await pumpEventQueue();
    expect(started, hasLength(1));
    expect(started.single.arguments, ['-v', 'es-419', '-s', '175', '--stdin']);
    expect(started.single.arguments.join(' '), isNot(contains('Welcome')));
    expect(started.single.spoken.toString(), 'Welcome. Choose a service');
  });

  test('a second request waits for the first; cancel stops and clears', () async {
    speech.handle(speak('one'));
    speech.handle(speak('two'));
    await pumpEventQueue();
    expect(started, hasLength(1));
    started.first.finish();
    await pumpEventQueue();
    expect(started, hasLength(2));
    expect(started.last.spoken.toString(), 'two');

    speech.handle(speak('three'));
    speech.handle(jsonEncode({'a': 'cancel'}));
    await pumpEventQueue();
    expect(started[1].killed, isTrue);
    expect(started, hasLength(2), reason: 'queued text is dropped on cancel');
  });

  test('bad or empty messages are ignored', () async {
    speech.handle('not json');
    speech.handle(jsonEncode({'a': 'speak', 'text': '   '}));
    speech.handle(jsonEncode([1, 2]));
    await pumpEventQueue();
    expect(started, isEmpty);
  });

  test('missing espeak-ng does not throw', () async {
    final missing = KioskSpeech(
        start: (exe, args) async => throw const ProcessException('espeak-ng', [], 'not found'));
    missing.handle(speak('hello'));
    await pumpEventQueue();
  });
}
