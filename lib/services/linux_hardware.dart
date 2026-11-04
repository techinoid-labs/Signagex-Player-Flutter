import 'dart:io';

/// The device's real make and model for the CMS (instead of the hostname):
/// DMI on PCs such as the Azulle, the device-tree model on a Raspberry Pi.
class LinuxHardware {
  /// Firmware placeholders that say nothing about the device.
  static final _placeholder = RegExp(
      r'^(|to be filled by o\.?e\.?m\.?|default string|system (product name|manufacturer)|not applicable|none|unknown|o\.?e\.?m\.?)$',
      caseSensitive: false);

  static String _clean(String? value) {
    final text = (value ?? '').replaceAll('\u0000', '').trim();
    return _placeholder.hasMatch(text) ? '' : text;
  }

  /// (manufacturer, model); either may be empty when the hardware does not say.
  static (String, String) identify({String? vendor, String? product, String? deviceTree}) {
    final tree = _clean(deviceTree);
    if (tree.isNotEmpty) {
      const pi = 'Raspberry Pi';
      return tree.startsWith(pi) ? (pi, tree) : ('', tree);
    }
    return (_clean(vendor), _clean(product));
  }

  static String _read(String path) {
    try {
      return File(path).readAsStringSync();
    } catch (_) {
      return '';
    }
  }

  static (String, String) current() => identify(
        vendor: _read('/sys/class/dmi/id/sys_vendor'),
        product: _read('/sys/class/dmi/id/product_name'),
        deviceTree: _read('/proc/device-tree/model'),
      );
}
