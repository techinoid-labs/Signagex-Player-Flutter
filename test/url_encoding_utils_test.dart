import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/utils/url_encoding_utils.dart';

void main() {
  group('encodeUrlWhitespaceOnly — W11: no double-encoding', () {
    test('an already-encoded space and signed query slash are left untouched', () {
      // The exact reproduced counterexample (03-audit-check-results.txt):
      // Uri.encodeFull turned this into
      // "video%2520one.mp4?token=a%252Fb" -- corrupting both the filename
      // escape and the signed query parameter.
      const url = 'https://example.invalid/video%20one.mp4?token=a%2Fb';
      expect(encodeUrlWhitespaceOnly(url), url);
    });

    test('a literal unencoded space is encoded', () {
      const url = 'https://example.invalid/_next/static/media/Leaf 4.6bb812d5.svg';
      final result = encodeUrlWhitespaceOnly(url);
      expect(result, contains('Leaf%204.6bb812d5.svg'));
      expect(result, isNot(contains(' ')));
    });

    test('mixed: a literal space alongside an existing valid escape', () {
      const url = 'https://example.invalid/my file%20name.jpg';
      final result = encodeUrlWhitespaceOnly(url);
      // The literal space becomes %20, the existing %20 stays exactly %20
      // (not %2520).
      expect(result, 'https://example.invalid/my%20file%20name.jpg');
    });

    test('a URL with no whitespace at all is returned unchanged', () {
      const url = 'https://example.invalid/asset.mp4?token=a%2Fb';
      expect(encodeUrlWhitespaceOnly(url), url);
    });
  });
}
