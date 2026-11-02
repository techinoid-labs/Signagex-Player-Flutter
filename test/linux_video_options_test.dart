import 'package:digital_signage/utils/linux_video_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native render size remains the default on unconfigured devices', () {
    expect(linuxVideoOptions({}), {'platforms': ['linux']});
  });
  test('a device can cap render work while preserving source aspect ratio', () {
    expect(linuxVideoOptions({
      'SIGNAGEX_VIDEO_MAX_WIDTH': '1280',
      'SIGNAGEX_VIDEO_MAX_HEIGHT': '720',
    }), {
      'platforms': ['linux'], 'maxWidth': 1280, 'maxHeight': 720,
      'fitMaxSize': true,
    });
  });
  test('partial, malformed and unsafe limits cannot break player startup', () {
    for (final size in ['', 'oops', '-1', '0', '63', '8193']) {
      expect(linuxVideoOptions({
        'SIGNAGEX_VIDEO_MAX_WIDTH': size,
        'SIGNAGEX_VIDEO_MAX_HEIGHT': '720',
      }), {'platforms': ['linux']});
    }
    expect(linuxVideoOptions({'SIGNAGEX_VIDEO_MAX_WIDTH': '1280'}),
        {'platforms': ['linux']});
  });
}
