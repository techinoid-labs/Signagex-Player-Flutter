import 'package:flutter_test/flutter_test.dart';
import '../lib/services/linux_hardware.dart';

void main() {
  test('PC makers come from DMI', () {
    expect(LinuxHardware.identify(vendor: 'Azulle\n', product: 'Access4\n'), ('Azulle', 'Access4'));
  });

  test('a Raspberry Pi is named by its device tree', () {
    expect(LinuxHardware.identify(vendor: '', product: '', deviceTree: 'Raspberry Pi 5 Model B Rev 1.1\u0000'),
        ('Raspberry Pi', 'Raspberry Pi 5 Model B Rev 1.1'));
    expect(LinuxHardware.identify(deviceTree: 'Rockchip RK3566 EVB'), ('', 'Rockchip RK3566 EVB'));
  });

  test('firmware placeholders are treated as unknown', () {
    expect(LinuxHardware.identify(vendor: 'To be filled by O.E.M.', product: 'Default string'), ('', ''));
    expect(LinuxHardware.identify(vendor: 'System manufacturer', product: 'System Product Name'), ('', ''));
  });
}
