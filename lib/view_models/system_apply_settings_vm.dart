import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:screen_brightness/screen_brightness.dart';

import 'package:digital_signage/services/mqtt_client_service.dart';
import 'package:digital_signage/utils/debug_log.dart' as debug;
import 'package:digital_signage/utils/globle_variable.dart';

MqttClientService mqttClientService = MqttClientService();

// Diagnostic-only file logger -- see debug_log.dart for why this exists
// (release-mode Windows exes are GUI-subsystem, print() output goes
// nowhere visible no matter how the exe is launched) and why it funnels
// through a shared write queue instead of writing directly.
Future<void> _debugLog(String message) =>
    debug.debugLog('DeviceSettings', message);

class DeviceSettingsViewModel with ChangeNotifier {
  Future<void> setVolumeForIOS(double value) async {
    const platform = MethodChannel('com.example/device_info');

    try {
      final result = await platform.invokeMethod('setVolume', {'value': value});
      print(result);
    } on PlatformException catch (e) {
      print("Failed to set volume: '${e.message}'.");
    }
  }

  Future<void> setBrightnessForIOS(double value) async {
    const platform = MethodChannel('com.example/device_info');

    try {
      final result =
          await platform.invokeMethod('setScreenBrightness', {'value': value});
      print(result);
    } on PlatformException catch (e) {
      print("Failed to set brightness: '${e.message}'.");
    }
  }

  Future<String> rebootDeviceForLinux() async {
    print("Attempting to restart the device...");

    // Execute the reboot command
    final result = await Process.run('pkexec', ['systemctl', 'reboot']);

    print('Exit code: ${result.exitCode}');
    print('Stdout: ${result.stdout}');
    print('Stderr: ${result.stderr}');

    if (result.exitCode != 0) {
      return 'Error: ${result.stderr}';
    }

    return 'Reboot command executed successfully';
  }

  Future<void> rebootDeviceForWindows() async {
    try {
      mqttClientService.publish(globleTopic, "success");
      final result = await Process.run(
          'powershell', ['-Command', 'Restart-Computer -Force']);

      if (result.exitCode != 0) {
        print('Error: ${result.stderr}');
      } else {
        print('Device is rebooting...');
      }
    } catch (e) {
      print('An error occurred: $e');
    }
  }

  Future<void> rebootDeviceForAndroid() async {
    print("reboot$globleTopic");
    try {
      mqttClientService.publish(globleTopic, "success");
      await platform.invokeMethod('rebootDevice');
    } on PlatformException catch (e) {
      print("Failed to reboot device: ${e.message}");
    }
  }

  Future<void> rebootDeviceForMacOS() async {
    try {
      mqttClientService.publish(globleTopic, "success");
      final String result = await platformMacOS.invokeMethod('rebootDevice');
      print(result);
    } on PlatformException catch (e) {
      print("Failed to reboot the device: '${e.message}'.");
    }
  }

  Future<String> changeVolumeForLinux(String volumePercentage) async {
    final result = await Process.run(
        'bash', ['-c', 'amixer set Master $volumePercentage%']);

    // Log command output and errors
    print('Command: amixer set Master $volumePercentage%');
    print('stdout: ${result.stdout}');
    print('stderr: ${result.stderr}');

    if (result.exitCode != 0) {
      return 'Error: ${result.stderr}';
    }

    return 'Volume changed to $volumePercentage%';
  }

  Future<String> getActiveOutputForLinux() async {
    final result = await Process.run(
        'bash', ['-c', 'xrandr | grep " connected" | awk \'{print \$1}\'']);

    if (result.exitCode != 0) {
      return 'Error: ${result.stderr}';
    }

    return result.stdout.trim();
  }

  Future<String> changeBrightnessForLinux(String brightnessLevel) async {
    String displayOutput = await getActiveOutputForLinux();

    // Check if an output was found
    if (displayOutput.isEmpty) {
      return 'No connected display found.';
    }

    final result = await Process.run('bash',
        ['-c', 'xrandr --output $displayOutput --brightness $brightnessLevel']);

    print(
        'Command: xrandr --output $displayOutput --brightness $brightnessLevel');
    print('stdout: ${result.stdout}');
    print('stderr: ${result.stderr}');

    if (result.exitCode != 0) {
      return 'Error: ${result.stderr}';
    }

    return 'Brightness changed to $brightnessLevel on $displayOutput';
  }

  Future<void> restartNetworkAdapterForWindows() async {
    try {
      // PowerShell command to list all network adapters and get their names and descriptions
      String listAdaptersCommand = '''
      Get-NetAdapter | Where-Object { \$_.Status -eq 'Up' } | Select-Object -Property Name, InterfaceDescription
    ''';

      // Execute PowerShell command to list active adapters
      final listResult =
          await Process.run('powershell', ['-Command', listAdaptersCommand]);

      if (listResult.exitCode != 0 || listResult.stdout.trim().isEmpty) {
        print('Error: No active network adapters found.');
        return;
      }

      // Split the output into lines and process each adapter
      List<String> adapterLines = listResult.stdout
          .trim()
          .split('\n')
          .skip(1)
          .toList(); // Skip header row

      if (adapterLines.isEmpty) {
        print('No active adapters found.');
        return;
      }

      for (var line in adapterLines) {
        List<String> adapterDetails =
            line.trim().split(RegExp(r'\s{2,}')); // Split by multiple spaces

        if (adapterDetails.length >= 2) {
          String adapterName = adapterDetails[0];
          String adapterDescription = adapterDetails[1];

          // Determine if it's Wi-Fi or Ethernet by checking the description
          if (adapterDescription.toLowerCase().contains('wi-fi') ||
              adapterDescription.toLowerCase().contains('wireless')) {
            print('Found Wi-Fi adapter: $adapterName ($adapterDescription)');
          } else if (adapterDescription.toLowerCase().contains('ethernet')) {
            print('Found Ethernet adapter: $adapterName ($adapterDescription)');
          } else {
            print('Skipping unknown adapter type: $adapterDescription');
            continue;
          }

          // PowerShell command to restart the network adapter
          String restartCommand =
              'Restart-NetAdapter -Name "$adapterName" -Confirm:\$false';

          // Execute PowerShell command to restart the adapter
          final restartResult = await Process.run('powershell', [
            '-Command',
            'Start-Process PowerShell -ArgumentList \'-NoProfile -ExecutionPolicy Bypass -Command "$restartCommand"\' -Verb RunAs'
          ]);

          // Check the output of the restart process
          print('Restart Output for $adapterName: ${restartResult.stdout}');
          print('Restart Error for $adapterName: ${restartResult.stderr}');
          if (restartResult.exitCode != 0) {
            print(
                'Error restarting adapter $adapterName: ${restartResult.stderr}');
          } else {
            print('Adapter "$adapterName" restarted successfully.');
          }
        }
      }
    } catch (e) {
      print('An error occurred: $e');
    }
  }

  static Future<void> setOrientationForAndroid(int orientation) async {
    try {
      const MethodChannel _channel = MethodChannel('com.example/network');

      await _channel
          .invokeMethod('setOrientation', {'orientation': orientation});
    } on PlatformException catch (e) {
      print("Failed to set orientation: '${e.message}'.");
    }
  }

  Future<String> restartNetworkForMac() async {
    const MethodChannel _channel = MethodChannel('com.example/networkControl');

    final String result = await _channel.invokeMethod('restartNetwork');
    return result;
  }

  Future<String> unmuteVolumeForLinux() async {
    final result =
        await Process.run('bash', ['-c', 'amixer set Master unmute']);

    // Log command output and errors
    print('Command: amixer set Master unmute');
    print('stdout: ${result.stdout}');
    print('stderr: ${result.stderr}');

    if (result.exitCode != 0) {
      return 'Error: ${result.stderr}';
    }

    return 'Volume unmuted';
  }

  Future<String> muteVolumeForLinux() async {
    final result = await Process.run('bash', ['-c', 'amixer set Master mute']);

    // Log command output and errors
    print('Command: amixer set Master mute');
    print('stdout: ${result.stdout}');
    print('stderr: ${result.stderr}');

    if (result.exitCode != 0) {
      return 'Error: ${result.stderr}';
    }

    return 'Volume muted';
  }

  Future<void> adjustBrightnessForWindows(int brightness) async {
    try {
      // Ensure brightness is between 0-100
      if (brightness < 0) brightness = 0;
      if (brightness > 100) brightness = 100;

      // WmiMonitorBrightnessMethods is a user-level WMI call -- it does not
      // need admin rights. The previous implementation wrapped it in
      // Start-Process -Verb RunAs, which pops a UAC prompt; on an unattended
      // kiosk with nobody there to click "Yes", that prompt just hangs
      // forever and the brightness command silently never completes. Call
      // it directly instead.
      //
      // Note: this WMI class is only populated for displays with
      // driver-level ACPI brightness support (typically laptop panels). A
      // signage box driving an external monitor/TV over HDMI has no WMI
      // brightness provider at all -- that needs DDC/CI control instead,
      // which isn't implemented here yet.
      final result = await Process.run('powershell', [
        '-Command',
        '(Get-WmiObject -Namespace root/wmi -Class WmiMonitorBrightnessMethods).WmiSetBrightness(1, $brightness)'
      ]);

      print('Output: ${result.stdout}');
      print('Error: ${result.stderr}');
      if (result.exitCode != 0) {
        print('Error adjusting brightness: ${result.stderr}');
      } else {
        print('Brightness changed to $brightness%');
      }
    } catch (e) {
      print('An error occurred: $e');
    }
  }

  // Set-AudioDevice (from the third-party AudioDeviceCmdlets PowerShell
  // module) turned out to be unreliable on a real kiosk machine -- confirmed
  // via the debug log: "The term 'Set-AudioDevice' is not recognized",
  // meaning the module never actually installed. Install-Module depends on
  // PSGallery reachability, the NuGet provider being bootstrapped, and a
  // permissive script execution policy -- any one of which can silently
  // fail on a locked-down signage box even when the machine otherwise has
  // working internet (as this one does -- MQTT/HTTPS both connect fine).
  // Control the OS volume directly via the Core Audio API instead
  // (IAudioEndpointVolume, reached through Add-Type/COM interop, the same
  // technique already used for simulateClickForWindows below) -- no
  // external module, no internet dependency, no execution-policy exposure.
  static const String _audioComShim = r'''
using System;
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
  int f0(); int f1();
  int GetChannelCount(out uint c);
  int SetMasterVolumeLevel(float l, [MarshalAs(UnmanagedType.LPStruct)] Guid ctx);
  int SetMasterVolumeLevelScalar(float l, [MarshalAs(UnmanagedType.LPStruct)] Guid ctx);
  int GetMasterVolumeLevel(out float l);
  int GetMasterVolumeLevelScalar(out float l);
  int SetChannelVolumeLevel(uint ch, float l, [MarshalAs(UnmanagedType.LPStruct)] Guid ctx);
  int SetChannelVolumeLevelScalar(uint ch, float l, [MarshalAs(UnmanagedType.LPStruct)] Guid ctx);
  int GetChannelVolumeLevel(uint ch, out float l);
  int GetChannelVolumeLevelScalar(uint ch, out float l);
  int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, [MarshalAs(UnmanagedType.LPStruct)] Guid ctx);
  int GetMute(out bool mute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid iid, int ctx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object endpointVolume);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int f0();
  int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class MMDeviceEnumeratorComObject { }
public class SignageXAudio {
  static IAudioEndpointVolume Endpoint() {
    var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
    IMMDevice device;
    enumerator.GetDefaultAudioEndpoint(0, 1, out device);
    var iid = typeof(IAudioEndpointVolume).GUID;
    object epv;
    device.Activate(ref iid, 23, IntPtr.Zero, out epv);
    return (IAudioEndpointVolume)epv;
  }
  public static void SetVolume(int percent) {
    Endpoint().SetMasterVolumeLevelScalar(percent / 100f, Guid.Empty);
  }
  public static void SetMute(bool mute) {
    Endpoint().SetMute(mute, Guid.Empty);
  }
}
''';

  // W16: returns success/failure (checked exit code), not just "the
  // Process.run call itself didn't throw" -- a nonzero exit from the
  // PowerShell/COM shim (e.g. no default audio endpoint present) used to
  // be silently swallowed, and the caller recorded the setting as applied
  // regardless.
  Future<bool> _setWindowsVolume(int volume) async {
    if (volume < 0) volume = 0;
    if (volume > 100) volume = 100;

    final script = "\$def = @'\n$_audioComShim\n'@\n"
        "Add-Type -TypeDefinition \$def -Language CSharp -ErrorAction Stop\n"
        "[SignageXAudio]::SetVolume($volume)";
    final result = await Process.run('powershell', ['-Command', script]);
    print('Output: ${result.stdout}');
    print('Error: ${result.stderr}');
    _debugLog(
        'setWindowsVolume($volume): exitCode=${result.exitCode}, stdout=${result.stdout}, stderr=${result.stderr}');
    return result.exitCode == 0;
  }

  // W16: real mute via the audio endpoint's own SetMute, not "set volume to
  // 0" -- the old approach made mute and volume the *same* underlying
  // property (volume level), so a settings payload with both mute_audio
  // and volume raced: whichever of muteVolumeForWindows/
  // changeVolumeForWindows's un-awaited PowerShell process happened to
  // finish last "won", and unmuting always landed on a hardcoded 50%
  // instead of whatever level was actually configured before muting. A
  // real mute flag is an independent property from volume level, so
  // mute+volume in the same payload can no longer race at all, and
  // unmuting restores the volume that was already in effect.
  Future<bool> _setWindowsMute(bool mute) async {
    final script = "\$def = @'\n$_audioComShim\n'@\n"
        "Add-Type -TypeDefinition \$def -Language CSharp -ErrorAction Stop\n"
        "[SignageXAudio]::SetMute(\$${mute ? 'true' : 'false'})";
    final result = await Process.run('powershell', ['-Command', script]);
    _debugLog(
        'setWindowsMute($mute): exitCode=${result.exitCode}, stdout=${result.stdout}, stderr=${result.stderr}');
    return result.exitCode == 0;
  }

  Future<bool> changeVolumeForWindows(int volume) async {
    try {
      final ok = await _setWindowsVolume(volume);
      print(ok ? 'Volume changed to $volume%' : 'Volume change failed');
      return ok;
    } catch (e) {
      print('An error occurred: $e');
      _debugLog('changeVolumeForWindows($volume): FAILED -- $e');
      return false;
    }
  }

  Future<bool> unmuteVolumeForWindows() async {
    try {
      final ok = await _setWindowsMute(false);
      print(ok ? 'Volume is unmuted.' : 'Unmute failed');
      return ok;
    } catch (e) {
      print('An error occurred: $e');
      return false;
    }
  }

  Future<bool> muteVolumeForWindows() async {
    try {
      final ok = await _setWindowsMute(true);
      print(ok ? 'Volume is muted.' : 'Mute failed');
      return ok;
    } catch (e) {
      print('An error occurred: $e');
      return false;
    }
  }

  Future<void> setVolumeForMac(int volume) async {
    const platform = MethodChannel('com.example/volumeControl');
    try {
      await platform.invokeMethod('setVolume', {'volume': volume});
    } on PlatformException catch (e) {
      print("Failed to set volume: ${e.message}");
    }
  }

  Future<void> _muteVolumeForMac() async {
    const platform = MethodChannel('com.example/volumeControl');
    try {
      await platform.invokeMethod('muteVolume');
    } on PlatformException catch (e) {
      print("Failed to mute volume: ${e.message}");
    }
  }

  Future<void> setVolumeForAndroid(int level) async {
    const MethodChannel _channel = MethodChannel('com.example/network');

    await _channel.invokeMethod('setVolume', {'level': level});
  }

  Future<void> setAppBrightnessForAndroid(double brightness) async {
    try {
      double currentBrightnesss = await ScreenBrightness().current;

      // Log the current brightness to verify
      print('Current brightness is: $currentBrightnesss');
      // Log the brightness value before setting
      print('Attempting to set brightness to: $brightness');

      // Set the application screen brightness
      await ScreenBrightness().setScreenBrightness(brightness);

      // Get the current brightness after setting
      double currentBrightness = await ScreenBrightness().current;

      // Log the current brightness to verify
      print('Current brightness is: $currentBrightness');
    } catch (e) {
      // Handle any errors
      print('Failed to set brightness: $e');
    }
  }

  Future<void> muteVolumeForAndroid() async {
    try {
      const platform = MethodChannel('com.example/network');

      final result = await platform.invokeMethod('muteVolume');
      print(
          result); // Prints "Volume muted" or the success message from Android
    } on PlatformException catch (e) {
      print("Failed to mute volume: '${e.message}'.");
    }
  }

  Future<void> unmuteVolumeForAndroid() async {
    const platform = MethodChannel('com.example/network');
    try {
      await platform.invokeMethod('unmuteVolume');
      print('Volume unmuted');
    } on PlatformException catch (e) {
      print('Failed to unmute volume: ${e.message}');
    }
  }

  Future<void> muteVolumeForMac() async {
    const platform = MethodChannel('com.example/volumeControl');
    try {
      await platform.invokeMethod('muteVolume');
      mqttClientService.publish(globleTopic, "success");
    } on PlatformException catch (e) {
      print("Failed to mute volume: ${e.message}");
    }
  }

  Future<String> unmuteVolumeForMac() async {
    const MethodChannel _channel = MethodChannel('com.example/volumeControl');
    final String result = await _channel.invokeMethod('unmuteVolume');
    return result;
  }

  Future<void> restartNetworkForAndroid() async {
    try {
      final result = await platform.invokeMethod('restartNetwork');
      print(result); // Prints "Wi-Fi restarted" or success message from Android
    } on PlatformException catch (e) {
      print("Failed to restart Wi-Fi: '${e.message}'.");
    }
  }

  // Remote View controls for Windows -- mirror the Android player's
  // PRESS_HOME/PRESS_BACK/CLICK remote actions using the closest desktop
  // equivalents, since there's no "launcher home screen" or Android-style
  // back stack on a Windows desktop.

  // "Home": show the desktop (minimizes every window), same as Win+D.
  Future<void> showDesktopForWindows() async {
    try {
      final result = await Process.run('powershell', [
        '-Command',
        '(New-Object -ComObject Shell.Application).MinimizeAll()'
      ]);
      if (result.exitCode != 0) print('Error showing desktop: ${result.stderr}');
    } catch (e) {
      print('An error occurred: $e');
    }
  }

  // "Back": undo the minimize-all, restoring whatever windows were open.
  Future<void> restoreWindowsForWindows() async {
    try {
      final result = await Process.run('powershell', [
        '-Command',
        '(New-Object -ComObject Shell.Application).UndoMinimizeALL()'
      ]);
      if (result.exitCode != 0) {
        print('Error restoring windows: ${result.stderr}');
      }
    } catch (e) {
      print('An error occurred: $e');
    }
  }

  // Simulates a real mouse click at (x, y) in screen pixel coordinates via
  // user32.dll, so remote-view tap-through actually clicks whatever is
  // under the cursor in the running app (e.g. a "next content" hotspot),
  // instead of Flutter never learning a click happened at all.
  Future<void> simulateClickForWindows(int x, int y) async {
    try {
      final command = '''
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class SignageXInput {
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, System.IntPtr dwExtraInfo);
}
'@ -ErrorAction SilentlyContinue
[SignageXInput]::SetCursorPos($x, $y)
[SignageXInput]::mouse_event(0x0002, 0, 0, 0, [System.IntPtr]::Zero)
[SignageXInput]::mouse_event(0x0004, 0, 0, 0, [System.IntPtr]::Zero)
''';
      final result = await Process.run('powershell', ['-Command', command]);
      if (result.exitCode != 0) {
        print('Error simulating click: ${result.stderr}');
      }
    } catch (e) {
      print('An error occurred: $e');
    }
  }

  // W22: send_text previously only wrote the clipboard -- nothing ever
  // consumed it, so remote text never actually reached any input. This
  // simulates a real Ctrl+V keystroke via user32.dll's keybd_event (same
  // technique as simulateClickForWindows above), so whatever currently has
  // OS keyboard focus in this kiosk's own window -- a WebView-hosted <input>
  // included, since Windows delivers synthetic key events the same as real
  // ones -- receives the paste exactly like a real user pressing Ctrl+V
  // right after the clipboard was set would. Caller is expected to have
  // already called Clipboard.setData with the text to send.
  Future<bool> simulatePasteForWindows() async {
    try {
      const command = '''
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class SignageXKeyInput {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
}
'@ -ErrorAction SilentlyContinue
[SignageXKeyInput]::keybd_event(0x11, 0, 0, [System.UIntPtr]::Zero)
[SignageXKeyInput]::keybd_event(0x56, 0, 0, [System.UIntPtr]::Zero)
[SignageXKeyInput]::keybd_event(0x56, 0, 2, [System.UIntPtr]::Zero)
[SignageXKeyInput]::keybd_event(0x11, 0, 2, [System.UIntPtr]::Zero)
''';
      final result = await Process.run('powershell', ['-Command', command]);
      if (result.exitCode != 0) {
        print('Error simulating paste: ${result.stderr}');
        return false;
      }
      return true;
    } catch (e) {
      print('An error occurred: $e');
      return false;
    }
  }
}
