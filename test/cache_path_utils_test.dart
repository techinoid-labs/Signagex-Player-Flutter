import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/utils/cache_path_utils.dart';

void main() {
  group('cacheFilenameFor — W02: traversal/separator-safe filenames', () {
    test('a percent-encoded backslash traversal segment never appears in the result', () {
      // The exact counterexample from the audit's reproduction
      // (03-audit-check-results.txt): a source URL ending in
      // "..%5Coutside.mp4" used to decode to "..\outside.mp4" and get
      // interpolated straight into the destination path.
      const url = 'https://example.invalid/assets/..%5Coutside.mp4';
      final name = cacheFilenameFor(url);
      expect(name, isNot(contains('\\')));
      expect(name, isNot(contains('..')));
      expect(name, isNot(contains('/')));
    });

    test('a dot-segment path never appears in the result', () {
      const url = 'https://example.invalid/a/../../etc/passwd.mp4';
      final name = cacheFilenameFor(url);
      expect(name, isNot(contains('..')));
      expect(name, isNot(contains('/')));
    });

    test('a Windows-reserved device name as the URL basename is not reflected verbatim', () {
      for (final reserved in ['CON', 'PRN', 'AUX', 'NUL', 'COM1', 'LPT1']) {
        final url = 'https://example.invalid/$reserved.mp4';
        final name = cacheFilenameFor(url);
        final withoutExt = name.split('.').first.toLowerCase();
        expect(kReservedWindowsNames.contains(withoutExt), isFalse,
            reason: 'cache filename for $url must not be a reserved name, got $name');
      }
    });

    test('a trailing-dot basename does not produce a trailing-dot filename', () {
      const url = 'https://example.invalid/asset.mp4.';
      final name = cacheFilenameFor(url);
      expect(name.endsWith('.'), isFalse);
    });

    test('ordinary Unicode names are handled without throwing', () {
      const url = 'https://example.invalid/campañas/vidéo.mp4';
      expect(() => cacheFilenameFor(url), returnsNormally);
      expect(cacheFilenameFor(url), isNot(contains('/')));
    });

    test('percent-encoded spaces and unusual characters do not throw', () {
      const url = 'https://example.invalid/video%20one.mp4?token=a%2Fb';
      expect(() => cacheFilenameFor(url), returnsNormally);
    });

    test('a percent-encoded slash inside the query string does not leak into path extraction', () {
      // Decoding the whole URL before splitting on '/' (an earlier version
      // of this function did exactly that) turns "?token=a%2Fb" into
      // "?token=a/b" first, so splitting on '/' afterwards picks up "b" as
      // the "last segment" instead of the real path segment
      // "video one.mp4" -- Uri.parse().pathSegments must be used instead,
      // since it separates path from query before any decoding happens.
      const url = 'https://example.invalid/video%20one.mp4?token=a%2Fb';
      expect(safeExtensionFor(url), 'mp4');
    });
  });

  group('cacheFilenameFor — W09: basename collision', () {
    test('two different URLs sharing a final path segment get different filenames', () {
      // The exact reproduced scenario: two campaigns whose asset URLs end
      // in the same basename ("video.mp4") on different hosts/paths used
      // to share one cache file.
      const urlA = 'https://host-a.invalid/campaign-a/video.mp4';
      const urlB = 'https://host-b.invalid/campaign-b/video.mp4';
      expect(cacheFilenameFor(urlA), isNot(equals(cacheFilenameFor(urlB))));
    });

    test('the same URL always resolves to the same filename (cache reuse still works)', () {
      const url = 'https://example.invalid/campaign/video.mp4';
      expect(cacheFilenameFor(url), equals(cacheFilenameFor(url)));
    });
  });

  group('safeExtensionFor', () {
    test('extracts a plausible extension from the URL', () {
      expect(safeExtensionFor('https://example.invalid/a/video.mp4'), 'mp4');
      expect(safeExtensionFor('https://example.invalid/a/pic.JPG'), 'jpg');
    });

    test('falls back to mediaType when the URL has no usable extension', () {
      expect(
        safeExtensionFor('https://example.invalid/asset', mediaType: 'video/mp4'),
        'mp4',
      );
    });

    test('never returns a path separator or traversal segment even if present in the URL', () {
      final ext = safeExtensionFor('https://example.invalid/..%5Coutside.mp4');
      expect(ext, isNot(contains('/')));
      expect(ext, isNot(contains('\\')));
      expect(ext, isNot(contains('..')));
    });

    test('a bare extension with no plausible characters falls back to a safe default', () {
      final ext = safeExtensionFor('https://example.invalid/no-extension-here');
      expect(RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext), isTrue);
    });
  });
}
