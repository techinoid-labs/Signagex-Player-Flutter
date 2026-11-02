/// Optional per-device video render limit; source files remain unchanged.
Map<String, dynamic> linuxVideoOptions(Map<String, String> environment) {
  final options = <String, dynamic>{'platforms': <String>['linux']};
  final width = int.tryParse(environment['SIGNAGEX_VIDEO_MAX_WIDTH'] ?? '');
  final height = int.tryParse(environment['SIGNAGEX_VIDEO_MAX_HEIGHT'] ?? '');
  if (width != null && height != null &&
      width >= 64 && width <= 8192 && height >= 64 && height <= 8192) {
    options.addAll({'maxWidth': width, 'maxHeight': height, 'fitMaxSize': true});
  }
  return options;
}
