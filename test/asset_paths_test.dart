import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

// Linux and the Pi load assets case-sensitively; Windows does not, so a path
// like 'WIFIX.png' for 'WifiX.png' works there and silently breaks here.
void main() {
  test('every asset path in lib/ names a file with exactly that case', () {
    final literal = RegExp(r'''['"](assets/[^'"$]+)['"]''');
    final missing = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final match in literal.allMatches(file.readAsStringSync())) {
        final path = match.group(1)!;
        if (!File(path).existsSync()) missing.add('${file.path}: $path');
      }
    }
    expect(missing, isEmpty);
  });
}
