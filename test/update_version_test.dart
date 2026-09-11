import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/services/update_check_service.dart';

void main() {
  group('isNewerBuild — update only on a strictly newer vN build', () {
    test('newer latest is an update', () {
      expect(isNewerBuild('v12', 'v13'), isTrue);
      expect(isNewerBuild('v9', 'v10'), isTrue); // not fooled by string order
      expect(isNewerBuild('v1', 'v100'), isTrue);
    });

    test('equal build is not an update', () {
      expect(isNewerBuild('v12', 'v12'), isFalse);
    });

    test('older latest never downgrades', () {
      expect(isNewerBuild('v13', 'v12'), isFalse);
      expect(isNewerBuild('v100', 'v9'), isFalse);
    });

    test('malformed / non-numeric versions are never an update', () {
      expect(isNewerBuild('v12', ''), isFalse);
      expect(isNewerBuild('', 'v12'), isFalse);
      expect(isNewerBuild('v12', 'vX'), isFalse);
      expect(isNewerBuild('dev', 'v12'), isFalse); // local/dev build id
      expect(isNewerBuild('v12', '13beta'), isFalse);
      expect(isNewerBuild('v12', 'v'), isFalse);
    });

    test('tolerates a missing v prefix and surrounding whitespace', () {
      expect(isNewerBuild('12', '13'), isTrue);
      expect(isNewerBuild(' v12 ', ' v13 '), isTrue);
      expect(isNewerBuild('v12', '12'), isFalse); // 12 == 12, not newer
    });
  });
}
