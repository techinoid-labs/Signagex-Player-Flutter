import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:battery_plus/battery_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_phoenix/flutter_phoenix.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_info2/system_info2.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:digital_signage/models/ad_proof_of_play_model.dart';
import 'package:digital_signage/models/compaign_model.dart';
import 'package:digital_signage/models/intractivity_model.dart'
    hide MediaItem, Settings;
import 'package:digital_signage/models/play_list_model.dart';
import 'package:digital_signage/utils/cache_path_utils.dart';
import 'package:digital_signage/utils/connectivity_utils.dart';
import 'package:digital_signage/utils/debug_log.dart' as debug;
import 'package:digital_signage/utils/interactivity_hit_test.dart';
import 'package:digital_signage/utils/time_range_utils.dart';
import 'package:digital_signage/utils/url_encoding_utils.dart';
import 'package:digital_signage/utils/globle_variable.dart';
import 'package:digital_signage/utils/windows_screen_capture.dart'
    as windows_capture;
import 'package:digital_signage/view_models/system_apply_settings_vm.dart';

import '../data/api_repository/api_repository.dart';
import '../services/mqtt_client_service.dart';
import '../utils/constants.dart';

// #region agent log
void _mqttAgentDebugLog(
  String location,
  String message,
  Map<String, dynamic> data,
  String hypothesisId, {
  String runId = 'webapp-solo-fix',
}) {
  try {
    final payload = jsonEncode({
      'sessionId': '25797a',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'location': location,
      'message': message,
      'data': data,
      'hypothesisId': hypothesisId,
      'runId': runId,
    });
    File(r'D:\digital-signage-flutter\debug-25797a.log')
        .writeAsStringSync('$payload\n', mode: FileMode.append);
  } catch (_) {}
}
// #endregion

enum MqttState {
  initial,
  success,
  failure,
  noContent,
  campaignScreen,
  connectionScreen,
  noInternet,
  downloading,
  pairedScreen,
  playlistScreen,
  // PLAYER_STOP_REASON_CONTRACT: paired:false + action:"action_stop_player"
  // on a player/connection/ response. Distinct from pairedScreen (a
  // genuinely never-paired device) -- this player IS paired, just
  // temporarily stopped by the backend (licence/subscription/account
  // issue), so it must keep its cache and pairing state exactly as-is and
  // just stop showing content until the next poll comes back paired again.
  playerStopped,
}

class MqttViewModel extends ChangeNotifier {
  final MqttClientService _mqttClientService;
  final DeviceSettingsViewModel deviceSettings = DeviceSettingsViewModel();

  MqttState _state = MqttState.initial;
  Map<String, dynamic> devicesinfo = deviceInfoMap;

  Map<String, dynamic>? _deviceInfo;
  List<dynamic> _mediaList = [];

  Map<String, dynamic>? get deviceInfo => _deviceInfo;
  static const _channel = MethodChannel('com.example/device_info');
  static const platform = MethodChannel('com.example/network');
  List<dynamic> get mediaList => _mediaList;
  MqttState get state => _state;
  String _topic = "";
  String get topic => _topic;
  String get playerCode => _topic;

  // PLAYER_STOP_REASON_CONTRACT: the backend's stopReason() value from the
  // most recent action_stop_player response (licence_removed, org_expired,
  // demo_expired, org_inactive, org_suspended, or an older/unrecognised
  // value -- see PlayerStoppedView for how each is rendered). Null when not
  // currently stopped.
  String? _stopReason;
  String? get stopReason => _stopReason;

  PlayListModel? _playListModel;

  PlayListModel? get playListModel => _playListModel;

  CampaignModel? _campaignModel;

  CampaignModel? get campaignModel => _campaignModel;

  InteractivityModel? _interactivityModel;

  InteractivityModel? get interactivityModel => _interactivityModel;

  Map<String, String?> macAddresses = {
    'wlan0': null,
    'eth0': null,
  };
  Map<String, dynamic> storedJsonObj = {};
  Future<void> _loadStoredJsonObj() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();

    String? jsonString = prefs.getString('jsonObj');

    if (jsonString != null) {
      print('Retrieved JSON from SharedPreferences: $jsonString');
      storedJsonObj = jsonDecode(jsonString);
      print('Loaded JSON Object: $storedJsonObj');
      notifyListeners();
    } else {
      print('No JSON Object found in SharedPreferences.');
    }
  }

  bool? storeState;
  Future<void> getStoredState() async {
    final prefs = await SharedPreferences.getInstance();

    // Retrieve the 'storeState' value
    storeState = prefs.getBool('storeState');

    if (storeState != null) {
      debugPrint("Stored State: $storeState");
      // Use the value as needed
    } else {
      debugPrint("No 'storeState' value found.");
    }
  }

  Future<Map<String, dynamic>?> retrieveStoredResponse() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? jsonString = prefs.getString('apiResponse');

    if (jsonString != null) {
      final jsonResponse = jsonDecode(jsonString) as Map<String, dynamic>;
      print('Retrieved stored response: $jsonResponse');
      _topic = jsonResponse["player_code"] ?? "";
      debugPrint("This is the response from the$topic API: $jsonResponse");
      if (_topic.isNotEmpty) {
        globleTopic = _topic;
      }
      return jsonResponse;
    } else {
      print('No stored response found.');
      return null;
    }
  }

  Future<void> loadDeviceInfoFromSharedPreferences() async {
    // Real device stats get freshly (re-)collected by
    // getSystemDataForWindows/getDeviceInfoAndroid/etc. within a couple
    // seconds of every single launch, on every platform -- so there was
    // never a good reason to seed the live map from an old disk-cached copy
    // in the first place. Doing so actively caused two different bugs on
    // top of each other:
    //
    // 1. This used to REASSIGN the `deviceInfoMap` variable to a brand new
    //    object (`deviceInfoMap = Map.from(...)`). `devicesinfo` (what
    //    every population/publish call in this file actually reads and
    //    writes) was bound to the *original* object at construction time
    //    and doesn't follow that reassignment -- from that point on the two
    //    names silently pointed at two different maps for the rest of the
    //    app's lifetime, and every write to devicesinfo (manufacturer, app
    //    version, everything) was landing on an object nothing ever
    //    published again.
    // 2. Fixing #1 by clearing-and-merging into the existing object instead
    //    (so the two names can't diverge) turned out to just be a
    //    differently-shaped version of the same problem: whatever had
    //    *already* been written into devicesinfo by a fast-completing async
    //    call (e.g. _populateAppVersion, which can finish before this does)
    //    got wiped by the clear() and was never restored, since nothing
    //    re-sets those fields a second time. Observed in a real debug log:
    //    player_version and the static "action" field vanishing from every
    //    published payload after being confirmed set moments earlier, and a
    //    network_name of literally "Loading..." (a value nothing in the
    //    current codebase even writes) resurfacing from a disk cache that
    //    predates this field existing.
    //
    // Don't load stale device details into the live map. Pairing and content
    // preferences must remain intact; _monitorConnectivity clears them only
    // when the build environment changes.
  }

  // Diagnostic-only file logger. print()/debugPrint() are invisible on a
  // release-mode Windows build (Flutter Windows builds as a GUI-subsystem
  // exe, so stdout isn't attached to a console even when launched from
  // one, whether double-clicked or run via `.\exe` in a terminal) -- this
  // writes straight to a file next to the exe so it's readable afterward
  // regardless of how the app was launched. Funnels through debug_log.dart's
  // shared write queue -- see that file for why (concurrent unsynchronized
  // writes from multiple classes were corrupting/dropping each other).
  Future<void> _debugLog(String message) =>
      debug.debugLog('MqttViewModel', message);

  MqttViewModel(this._mqttClientService) {
    _debugLog('=== MqttViewModel constructed (app launched) ===');
    _mqttClientService.receivedMessageNotifier.addListener(_updateMessage);
    _mqttClientService.onMessageReceived = _handleIncomingMessage;

    fetchAllInfo();
    _populateAppVersion();
    _initializeBasedOnPlatform();
    _monitorConnectivity();
  }

  // Field name and "Version: x.y.z" format match the working Android
  // player's PlayerInformation.getPlayerVersion() exactly -- the backend
  // reads player_version, not app_version.
  Future<void> _populateAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      devicesinfo["player_version"] = "Version: ${info.version}";
      notifyListeners();
      _debugLog('_populateAppVersion OK: player_version="Version: ${info.version}"');
    } catch (e) {
      debugPrint("Failed to read app version: $e");
      _debugLog('_populateAppVersion FAILED: $e');
    }
  }

  Future<void> captureAndSendScreenshot(String topic) async {
    try {
      Uint8List? imageBytes;

      // Real OS-level capture, reflecting the actual desktop -- other
      // windows, the taskbar, whatever press_home's MinimizeAll() actually
      // did -- none of which RenderRepaintBoundary below can ever see,
      // since it only captures this Flutter app's own render tree. Falls
      // through to that if GDI capture fails for any reason (e.g. running
      // on a platform/session without a desktop DC available).
      if (Platform.isWindows) {
        try {
          final desktop = windows_capture.captureWindowsDesktop();
          if (desktop != null) {
            imageBytes = Uint8List.fromList(img.encodePng(desktop));
            _debugLog(
                'captureAndSendScreenshot: captured via Windows GDI, ${desktop.width}x${desktop.height}');
          } else {
            _debugLog(
                'captureAndSendScreenshot: Windows GDI capture returned null, falling back to RenderRepaintBoundary');
          }
        } catch (error, st) {
          _debugLog(
              'captureAndSendScreenshot: Windows GDI capture threw, falling back to RenderRepaintBoundary -- $error\n$st');
        }
      }

      if (imageBytes == null) {
        RenderRepaintBoundary boundary = boundaryKey.currentContext!
            .findRenderObject() as RenderRepaintBoundary;

        if (boundary.debugNeedsPaint) {
          debugPrint("Widget not rendered yet. Waiting for rendering...");
          await Future.delayed(const Duration(milliseconds: 100));
        }

        // The working Android player captures Remote View screenshots at
        // full native screen resolution with JPEG quality 80
        // (ScreenCaptureManager.convertBitmapToBase64) and sends that
        // uncapped -- our previous pixelRatio: 0.5 plus a 400px-wide
        // quality-40 JPEG recompression was far below that, which is what
        // made Remote View look "very bad".
        final image = await boundary.toImage(pixelRatio: 1.0);

        final ByteData? byteData =
            await image.toByteData(format: ImageByteFormat.png);
        if (byteData == null) {
          debugPrint("Failed to capture screenshot: ByteData is null.");
          _debugLog('captureAndSendScreenshot: FAILED -- byteData is null');
          return;
        }
        imageBytes = byteData.buffer.asUint8List();
      }

      debugPrint("Original image size: ${imageBytes.length}");

      // Compress the image further
      final compressedImageBytes = await _compressImage(imageBytes);
      debugPrint("Compressed image size: ${compressedImageBytes.length}");

      // Convert to Base64 string
      final base64String = base64Encode(compressedImageBytes);

      // Remote View reads this from <topic>/remote as a single JSON
      // message with an img_url field -- this used to publish two
      // unrelated messages (a metadata blob, then raw base64 bytes with
      // no JSON wrapper) to the plain topic instead, which the backend
      // had no way to parse as a screenshot at all. Match the working
      // Android player's exact contract.
      Map<String, dynamic> sendLog = {
        "action": "image",
        "img_url": base64String,
        // captureAndSendScreenshot runs on every platform, so tag the real OS
        // rather than always claiming "windows".
        "sender": Platform.operatingSystem,
      };

      _mqttClientService.publish('$topic/remote', jsonEncode(sendLog));
      _debugLog(
          'captureAndSendScreenshot: published to $topic/remote, ${compressedImageBytes.length} bytes');
    } catch (error, st) {
      debugPrint("Error capturing or sending screenshot: $error");
      _debugLog('captureAndSendScreenshot: FAILED -- $error\n$st');
    }
  }

  Future<Uint8List> _compressImage(Uint8List imageBytes) async {
    // flutter_image_compress has no Windows platform implementation --
    // calling compressWithList() there throws MissingPluginException on
    // every single call, which captureAndSendScreenshot's catch block was
    // silently swallowing (only debugPrint, invisible in a release Windows
    // exe). That meant Remote View screenshots never actually got published
    // on Windows at all. Use the pure-Dart `image` package there instead --
    // no native plugin, so it works the same on every platform.
    if (Platform.isWindows) {
      final decoded = img.decodePng(imageBytes);
      if (decoded == null) return imageBytes;
      // Match Android's ScreenCaptureManager.convertBitmapToBase64: quality
      // 80, no forced downscale. A 4K signage display is a lot wider than a
      // phone screen though, so still cap at 1280px wide to keep the MQTT
      // payload reasonable -- 400px/quality 40 (previous values) was what
      // made this look "very bad".
      final resized = decoded.width > 1280
          ? img.copyResize(decoded, width: 1280)
          : decoded;
      _debugLog(
          'captureAndSendScreenshot: compressed via image pkg, ${resized.width}x${resized.height}');
      return Uint8List.fromList(img.encodeJpg(resized, quality: 80));
    }

    // Compress the image further by lowering quality and size
    final compressedBytes = await FlutterImageCompress.compressWithList(
      imageBytes,
      minWidth: 400,
      minHeight: 300,
      quality: 5,
      format: CompressFormat.jpeg,
    );
    return compressedBytes;
  }

  // Monitor connectivity changes and reinitialize MQTT on connection recovery
  Future<void> _monitorConnectivity() async {
    // Wipe SharedPreferences when the build environment switches (e.g.
    // production ZIP installed over staging), otherwise the old player code
    // bleeds into the new build and the player can't pair correctly.
    final prefsCheck = await SharedPreferences.getInstance();
    final storedEnv = prefsCheck.getString('app_environment') ?? '';
    if (storedEnv.isNotEmpty && storedEnv != appEnvironment) {
      await prefsCheck.clear();
      debugPrint(
          '[Env] SharedPreferences cleared: environment changed '
          'from $storedEnv → $appEnvironment');
    }
    await prefsCheck.setString('app_environment', appEnvironment);

    await _loadStoredJsonObj();
    await getStoredState();
    await retrieveStoredResponse();
    await loadDeviceInfoFromSharedPreferences();
    // Was InternetConnectionChecker().onStatusChange (probed third-party DNS-
    // resolver IPs), then briefly a raw TCP connect to this app's own
    // backend host:port -- neither fixed the repeated "connected via
    // Ethernet, still says no network" reports. Checked how
    // signagex-player-android (which works correctly over Ethernet on the
    // same networks) actually decides this: it never probes any external
    // host at all, it asks the OS directly (ConnectivityManager/
    // NetworkCapabilities.NET_CAPABILITY_INTERNET on the active network) and
    // treats every transport identically. See connectivity_utils.dart's own
    // doc comment for the full history. This mirrors that exactly.
    // W17: drain any proof-of-play reports that failed to send earlier --
    // once at startup (in case the app was closed/crashed with reports still
    // queued) and again every time the stream below reports connectivity
    // restored.
    unawaited(retryQueuedAdProofOfPlay());
    osNetworkConnectivityStream().listen((hasConnection) async {
      // Confirmed real-world symptom this is meant to catch: a
      // publish_campaign message can be received and parsed correctly, but
      // the actual screen doesn't switch to it for several minutes -- with
      // zero prior evidence of whether this connectivity listener is
      // repeatedly firing and re-entering this branch during that window
      // (which would race against/override the state _startDownloadingFor*
      // just set). storedJsonObj["action"] and _state show exactly what
      // this listener would do if it fires again right now.
      _debugLog(
          'osNetworkConnectivityStream: hasConnection=$hasConnection '
          'storedJsonObjAction=${storedJsonObj["action"]} currentState=$_state');

      if (hasConnection) {
        unawaited(retryQueuedAdProofOfPlay());
        print("this is data $storedJsonObj");

        if (storedJsonObj["action"] == "publish_playlist") {
          await _tryConnect('publish_playlist');

          if (_topic.isNotEmpty) {
            subsibeMessage(_topic);
          }
          if (globleTopic.isNotEmpty) {
            publishMessage(globleTopic, jsonEncode(deviceInfoMap));
          }
          _playListModel = playListModelFromJson(jsonEncode(storedJsonObj));
          // W14: see the matching comment at the main publish_playlist
          // handler -- a restored playlist can be shorter than whatever
          // _currentIndex was left pointing at.
          _currentIndex = 0;
          _timer?.cancel();

          // W07 follow-up: _startDownloadingForPlaylist() already iterates
          // every playlist/media item itself -- calling it again per media
          // item here queued one full redundant download pass per item
          // (confirmed: an N-item playlist launched N complete passes, with
          // only the last one's generation actually allowed to commit final
          // state). One call is enough, same as the campaign path below.
          final hasPlaylistMedia = _playListModel!.data.playlist.any(
            (playlist) => playlist.media?.isNotEmpty ?? false,
          );
          if (hasPlaylistMedia) {
            _startDownloadingForPlaylist();
          }
        } else if (storedJsonObj["action"] == "publish_campaign") {
          await _tryConnect('publish_campaign');

          if (_topic.isNotEmpty) {
            subsibeMessage(_topic);
          }
          if (globleTopic.isNotEmpty) {
            publishMessage(globleTopic, jsonEncode(deviceInfoMap));
          }
          _campaignModel = normalizeCampaignResponse(
            campaignModelFromJson(jsonEncode(storedJsonObj)),
            storedJsonObj,
          );
          _selectCompositionCampaignIndexIfPresent();

          print(_mediaList);
          // W07 follow-up: same redundant-call issue as the playlist branch
          // above -- _startDownloadingForCampaign() already walks every
          // campaign/zone/media item itself.
          if ((_campaignModel?.data?.playerCampaigns ?? []).isNotEmpty) {
            _startDownloadingForCampaign();
          }
        } else {
          print("elssssssssssssssssssssse caseeeeeee}");
          _mqttConnection();
        }
      } else {
        if (storedJsonObj["action"] == "publish_playlist") {
          _playListModel = playListModelFromJson(jsonEncode(storedJsonObj));
          // W14: see the matching comment at the main publish_playlist
          // handler -- a restored playlist can be shorter than whatever
          // _currentIndex was left pointing at.
          _currentIndex = 0;
          _timer?.cancel();
          print(_mediaList);
          {
            final hasPlaylistMedia = _playListModel!.data.playlist.any(
              (playlist) => playlist.media?.isNotEmpty ?? false,
            );
            if (hasPlaylistMedia) {
              _startDownloadingForPlaylist();
            }
          }
        } else if (storedJsonObj["action"] == "publish_campaign") {
          _campaignModel = normalizeCampaignResponse(
            campaignModelFromJson(jsonEncode(storedJsonObj)),
            storedJsonObj,
          );
          _selectCompositionCampaignIndexIfPresent();

          if ((_campaignModel?.data?.playerCampaigns ?? []).isNotEmpty) {
            _startDownloadingForCampaign();
          }
        } else {
          // Reproduced in Windows Sandbox (which connects through a Hyper-V
          // virtual NIC that Windows presents as Ethernet): the sandbox has
          // genuinely working internet, yet the player sat on the
          // no-network screen forever. This branch is why -- with no stored
          // content to restore, a false "disconnected" reading went straight
          // to MqttState.noInternet and never attempted a single network
          // call, so nothing could ever disprove it or recover.
          //
          // The OS connectivity signal is authoritative on Android (which is
          // why the reference player can gate on it), but demonstrably is
          // NOT on Windows: Network List Manager -- what connectivity_plus
          // reads -- classifies some adapters (Hyper-V/virtual NICs, and
          // evidently whatever the office Ethernet setup presents) as having
          // no internet even while HTTP and MQTT to the real backend work
          // fine. Treating that reading as proof is what produced every
          // "works on Wi-Fi, dead on Ethernet" report.
          //
          // So the signal is now advisory: it still triggers a connection
          // ATTEMPT, but only the attempt itself decides the outcome.
          // _mqttConnection() already sets noInternet in its own catch if
          // the connection genuinely fails, so a real outage still lands on
          // the same screen -- the difference is that it's now decided by an
          // actual failed network call rather than by an OS flag that can be
          // wrong.
          _debugLog(
              'connectivity reported disconnected and there is no stored '
              'content -- attempting to connect anyway rather than trusting '
              'the OS flag (see Windows Sandbox/Ethernet false-negative)');
          await _mqttConnection();
        }
      }
    });
  }

  Future<void> checkAndRequestPermissions() async {
    final status = await Permission.location.status;
    if (!status.isGranted) {
      await Permission.location.request();
    }
  }

  Future<void> fetchNetworkInfo() async {
    final NetworkInfo networkInfo = NetworkInfo();

    try {
      // Fetch network information
      final networkName = await networkInfo.getWifiName();
      final ipAddress = await networkInfo.getWifiIP();
      devicesinfo["last_ip_address"] = ipAddress;

      // Windows' underlying WinRT connectivity API reports the network
      // profile as the literal placeholder string "Loading..." while it is
      // still resolving the real SSID -- this is not ours, network_info_plus
      // just surfaces it verbatim. Publishing that placeholder makes the
      // dashboard show "Loading..." forever, so only overwrite the last-known
      // good name once a real (non-placeholder) name comes back; a transient
      // placeholder reading no longer clobbers a value we already had.
      var cleanName = (networkName ?? "").trim();
      if (cleanName.startsWith('"') && cleanName.endsWith('"') && cleanName.length > 1) {
        cleanName = cleanName.substring(1, cleanName.length - 1);
      }
      final isPlaceholder = cleanName.isEmpty ||
          cleanName.toLowerCase() == "loading..." ||
          cleanName.toLowerCase() == "loading" ||
          cleanName.toLowerCase() == "identifying...";
      if (!isPlaceholder) {
        devicesinfo["network_name"] = cleanName;
      } else if ((devicesinfo["network_name"] as String? ?? "").isEmpty) {
        devicesinfo["network_name"] = cleanName;
      }

      print('Network Name (SSID): $networkName');
      print('IP Address: $ipAddress');
    } catch (e) {
      print('Failed to get network info: ${e.toString()}');
    }
  }

  Future<void> fetchBatteryInfo() async {
    final Battery battery = Battery();

    try {
      // Fetch battery information
      final batteryLevel = await battery.batteryLevel;
      print(batteryLevel);
    } catch (e) {
      print('Failed to get battery level: ${e.toString()}');
    }
  }

  String uniqueid = "";
  Future<String> getDeviceID() async {
    final result = await Process.run('powershell', [
      '-Command',
      'Get-WmiObject -Class Win32_ComputerSystemProduct | Select-Object -ExpandProperty UUID'
    ]);

    if (result.exitCode != 0) {
      return 'Error: ${result.stderr}';
    }

    return result.stdout.trim();
  }

  Future<void> fetchSystemInfo() async {
    try {
      // Common System Information
      final kernelArchitecture = SysInfo.kernelArchitecture.toString();
      print('Kernel Architecture: $kernelArchitecture');

      final kernelBitness = SysInfo.kernelBitness;
      print('Kernel Bitness: $kernelBitness');

      final kernelName = SysInfo.kernelName;
      print('Kernel Name: $kernelName');

      final kernelVersion = SysInfo.kernelVersion;
      print('Kernel Version: $kernelVersion');
      devicesinfo["android_version"] = kernelVersion;
      final operatingSystemName = SysInfo.operatingSystemName;
      print('Operating System Name: $operatingSystemName');

      final operatingSystemVersion = SysInfo.operatingSystemVersion;
      print('Operating System Version: $operatingSystemVersion');

      final userDirectory = SysInfo.userDirectory;
      print('User Directory: $userDirectory');

      final userId = SysInfo.userId;
      print('User ID: $userId');

      final userName = SysInfo.userName;
      print('User Name: $userName');

      final userSpaceBitness = SysInfo.userSpaceBitness;
      print('User Space Bitness: $userSpaceBitness');

      // Memory Information
      final totalPhysicalMemory = SysInfo.getTotalPhysicalMemory();
      print('Total Physical Memory: $totalPhysicalMemory bytes');

      final freePhysicalMemory = SysInfo.getFreePhysicalMemory();
      print('Free Physical Memory: $freePhysicalMemory bytes');

      final totalVirtualMemory = SysInfo.getTotalVirtualMemory();
      print('Total Virtual Memory: $totalVirtualMemory bytes');

      final freeVirtualMemory = SysInfo.getFreeVirtualMemory();
      print('Free Virtual Memory: $freeVirtualMemory bytes');
    } catch (e) {
      print("Failed to get system info: '${e.toString()}'.");
    }
  }

  Future<void> fetchAllInfo() async {
    await fetchNetworkInfo();
    await fetchBatteryInfo();
    await fetchSystemInfo();
  }

  Future<void> _initializeMacAddresses() async {
    final macAddressesMap = await getListOfMacAddresses();
    if (macAddressesMap != null) {
      final List<dynamic> macList = macAddressesMap['macAddress'];
      for (var item in macList) {
        final interface = item['interface'] as String?;
        final mac = item['mac'] as String?;
        if (interface != null && mac != null) {
          macAddresses[interface] = mac;
        }
      }

      print("Fetched MAC addresses: $macAddresses");
      devicesinfo["mac_address"]["macAddress"][0]["interface"] = "wlan0";
      devicesinfo["mac_address"]["macAddress"][1]["interface"] = "eth0";
      if (devicesinfo["mac_address"]["macAddress"][0]["interface"] == "wlan0") {
        devicesinfo["mac_address"]["macAddress"][0]["mac"] =
            macAddresses["wlan0"] ?? "";
      } else {
        devicesinfo["mac_address"]["macAddress"][1]["mac"] =
            macAddresses["eth0"] ?? "";
      }
      debugPrint("this is object$deviceInfoMap");
    } else {
      print("No MAC addresses found.");
    }
  }

  static Future<Map<String, dynamic>?> getListOfMacAddresses() async {
    final String? macAddressesJson =
        await platform.invokeMethod('getListOfMacAddresses');
    if (macAddressesJson != null) {
      return jsonDecode(macAddressesJson);
    }
    return null;
  }

  static Future<String?> getWifiMacAddress() async {
    return await _channel.invokeMethod('getWifiMacAddress');
  }

  static Future<String?> getEthernetMacAddress() async {
    return await _channel.invokeMethod('getEthernetMacAddress');
  }

  Future<void> _initializeBasedOnPlatform() async {
    if (Platform.isAndroid) {
      await _initializeMacAddresses();
      getDeviceInfoAndroid();
    } else if (Platform.isIOS) {
      final identifier =
          await _channel.invokeMethod<String>('getDeviceIdentifier');
      print('iOS Device Identifier: $identifier');
      devicesinfo["mac_address"]["platform"] = "IOS";
      devicesinfo["mac_address"]["macAddress"][0]["interface"] = "wlan0";
      if (devicesinfo["mac_address"]["macAddress"][0]["interface"] == "wlan0") {
        devicesinfo["mac_address"]["macAddress"][0]["mac"] = identifier;
      }
      getDeviceInfo();
    } else if (Platform.isMacOS) {
      await getDeviceIdentifiersForMac();
    } else if (Platform.isWindows) {
      await getSystemDataForWindows();
    } else if (Platform.isLinux) {
      await getDataForLinux();
    }
  }

  Future<void> getDeviceInfoAndroid() async {
    try {
      final String? result = await platform.invokeMethod('getSystemData');
      if (result != null) {
        print("Device Info from Android: $result");

        // Parse the JSON result
        final Map<String, dynamic> deviceInfo = jsonDecode(result);
        devicesinfo["device_info"] = deviceInfo;

        // Extract and parse the `cpu_detailed_information` field
        final cpuDetailedInfo =
            deviceInfo["cpu_detailed_information"] as String?;
        if (cpuDetailedInfo != null) {
          // Split the string by double newlines to separate processor blocks
          final processorBlocks = cpuDetailedInfo.trim().split('\n\n');

          final List<Map<String, String>> processorsList = [];

          for (var block in processorBlocks) {
            final lines = block.split('\n');
            final Map<String, String> processorMap = {};

            for (var line in lines) {
              final parts = line.split(':');
              if (parts.length == 2) {
                final key =
                    parts[0].trim().replaceAll(' ', '_').replaceAll('\t', '');
                final value = parts[1].trim();
                processorMap[key] = value;
              }
            }
            processorsList.add(processorMap);
          }

          // Update `cpu_detailed_information` in the device info map
          deviceInfo["cpu_detailed_information"] = processorsList;
        }

        debugPrint("this is ${deviceInfo["cpu_detailed_information"]}");
        devicesinfo["sender"] = "android";
        devicesinfo["android_version"] = deviceInfo["android_version"];
        devicesinfo["last_seen"] = deviceInfo["last_seen"];
        devicesinfo["device_model"] = deviceInfo["device_model"];
        devicesinfo["network_name"] = deviceInfo["network_name"];
        devicesinfo["time_zone"] = deviceInfo["time_zone"];
        devicesinfo["last_ip_address"] = deviceInfo["last_ip_address"];
        devicesinfo["cpu_information"]["processor"] =
            deviceInfo["cpu_information"]["processor"];
        devicesinfo["cpu_information"]["count_cores"] =
            deviceInfo["cpu_information"]["count_cores"];
        devicesinfo["memory_information"]["total_memory"] =
            int.parse(deviceInfo["memory_information"]["total_memory"]);
        devicesinfo["memory_information"]["available_memory"] =
            int.parse(deviceInfo["memory_information"]["available_memory"]);
        devicesinfo["memory_information"]["used_memory"] =
            int.parse(deviceInfo["memory_information"]["used_memory"]);
        devicesinfo["battery_information"]["battery_percentage"] = num.tryParse(
                deviceInfo["battery_information"]["battery_percentage"]
                        as String? ??
                    '') ??
            0;
        devicesinfo["battery_information"]["formatted_voltage"] = num.tryParse(
                deviceInfo["battery_information"]["formatted_voltage"]
                        as String? ??
                    '') ??
            0;

        devicesinfo["battery_information"]["formatted_temperature"] =
            num.tryParse(deviceInfo["battery_information"]
                        ["formatted_temperature"] as String? ??
                    '') ??
                0;
        devicesinfo["cpu_detailed_information"]["cpu_detailed_information"] =
            deviceInfo["cpu_detailed_information"];
        devicesinfo["hardware_details"] = deviceInfo["hardware_details"];
        devicesinfo["storage_info"]["total_storage"] =
            deviceInfo["storage_info"]["total_storage"];
        devicesinfo["storage_info"]["available_storage"] =
            deviceInfo["storage_info"]["available_storage"];
        devicesinfo["ram_info"] = deviceInfo["ram_info"];
        devicesinfo["device_resolution"]["width"] =
            deviceInfo["device_resolution"]["width"];
        devicesinfo["device_resolution"]["height"] =
            deviceInfo["device_resolution"]["height"];
        devicesinfo["camera_details"] =
            deviceInfo["camera_details"]["lens_facing"];
        debugPrint("this is full object$deviceInfoMap");
        _fetchCurrentLocation();
        notifyListeners();
      } else {
        print("Failed to get device info");
      }
    } on PlatformException catch (e) {
      print("Failed to get device info: '${e.message}'.");
    }
  }

  // Method to check and request location permissions
  Future<void> _getLocation() async {
    final status = await Permission.location.status;
    if (status.isGranted) {
      Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      print(
          'location Latitude: ${position.latitude}, Longitude: ${position.longitude}');
    } else if (status.isDenied) {
      // Handle permission denied case
    } else if (status.isPermanentlyDenied) {
      // Handle permission permanently denied case
    }
  }

  Future<void> _fetchCurrentLocation() async {
    try {
      await _getLocation();

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      devicesinfo["latitude"] = position.latitude;
      devicesinfo["longitude"] = position.longitude;

      print('sadasdasasda$deviceInfoMap');
    } catch (e) {
      print('Error fetching location: $e');
    }
  }

  Future<void> getDeviceInfo() async {
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod('getDeviceInfo');

      if (result != null) {
        print("this is result$result");
        _deviceInfo = Map<String, dynamic>.from(result);
        print('Device Info: $_deviceInfo');
        devicesinfo["sender"] = "ios";
        devicesinfo["android_version"] = _deviceInfo!["ios_version"];
        devicesinfo["storage_info"]["total_storage"] =
            _deviceInfo!["storage_info"]["total_storage"];
        devicesinfo["storage_info"]["available_storage"] =
            _deviceInfo!["storage_info"]["free_storage"];
        devicesinfo["cpu_information"]["count_cores"] =
            _deviceInfo!["cpu_information"]["processor_count"];
        devicesinfo["time_zone"] = _deviceInfo!["time_zone"];
        devicesinfo["battery_information"]["battery_percentage"] =
            _deviceInfo!["battery_information"]["battery_level"];
        devicesinfo["device_model"] = _deviceInfo!["name"];
        debugPrint("this is dzzata$deviceInfoMap");
        _fetchCurrentLocation();
      } else {
        _deviceInfo = null;
      }

      notifyListeners();
    } on PlatformException catch (e) {
      print("Failed to get device info: '${e.message}'.");
    }
  }

  double _screenWidth = 0;
  double _screenHeight = 0;

  double get screenWidth => _screenWidth;
  double get screenHeight => _screenHeight;

  void setScreenSize(double width, double height) {
    _screenWidth = width;
    _screenHeight = height;
    devicesinfo["device_resolution"] = "$_screenWidth x $screenHeight";

    notifyListeners();
  }

  Future<void> getSystemDataForWindows() async {
    _debugLog('getSystemDataForWindows: starting WMI query...');
    try {
      final result = await getAllSystemInfo();
      _debugLog(
          'getSystemDataForWindows: PowerShell exitCode=${result.exitCode}, stderr=${result.stderr}');
      if (result.exitCode == 0) {
        final output = result.stdout.trim();
        _debugLog('getSystemDataForWindows: raw WMI JSON: $output');

        final Map<String, dynamic> systemInfo = jsonDecode(output);
        devicesinfo["sender"] = "windows";
        devicesinfo["time_zone"] = systemInfo["TimeZone"];
        devicesinfo["mac_address"]["platform"] = "Windows";
        devicesinfo["mac_address"]["macAddress"][0]["interface"] = "wlan0";
        if (devicesinfo["mac_address"]["macAddress"][0]["interface"] ==
            "wlan0") {
          devicesinfo["mac_address"]["macAddress"][0]["mac"] =
              systemInfo["DeviceID"];
        }
        devicesinfo["ram_info"] = systemInfo["InstalledRAM"].toString();

        // device_model is a separate top-level field from
        // hardware_details.model -- Android sends both (getDeviceModel()
        // vs Build.MODEL) and only the top-level one was never populated
        // for Windows.
        devicesinfo["device_model"] = systemInfo["DeviceName"];
        devicesinfo["hardware_details"]["model"] = systemInfo["DeviceName"];
        print(systemInfo["TimeZone"]);
        devicesinfo["hardware_details"]["device_id"] = systemInfo["DeviceID"];
        devicesinfo["hardware_details"]["manufacturer"] =
            systemInfo["Manufacturer"] ?? "";
        devicesinfo["storage_info"]["total_storage"] =
            systemInfo["Drives"][0]["TotalSpaceGB"].toString();

        devicesinfo["storage_info"]["available_storage"] =
            systemInfo["Drives"][0]["FreeSpaceGB"].toString();
        print(systemInfo["TimeZone"]);
        devicesinfo["hardware_details"]["ram"] = systemInfo["InstalledRAM"];
        devicesinfo["cpu_information"]["cpu_architecture"] =
            systemInfo["CPUArchitecture"];
        devicesinfo["cpu_information"]["processor"] = systemInfo["CPUInfo"];
        devicesinfo["system_version"] =
            "${systemInfo["OSCaption"] ?? "Windows"} (${systemInfo["OSVersion"] ?? ""})";
        _applyWindowsDynamicStats(systemInfo);
        systemInfo.forEach((key, value) {
          print('$key: $value');
        });
        _debugLog(
            'getSystemDataForWindows: after population, manufacturer=${devicesinfo["hardware_details"]["manufacturer"]}, model=${devicesinfo["hardware_details"]["model"]}, device_model=${devicesinfo["device_model"]}, system_version=${devicesinfo["system_version"]}');

        _fetchCurrentLocation();
        await _checkPairingStatus();
      } else {
        print('Error: ${result.stderr}');
        _debugLog('getSystemDataForWindows: PowerShell FAILED, exitCode=${result.exitCode}');
      }
    } catch (e) {
      print('An error occurred: $e');
      _debugLog('getSystemDataForWindows: EXCEPTION $e');
    }
  }

  // Fills in the fields Resource Usage/Player Info actually chart -- these
  // used to only ever get set once at pairing time and then go stale.
  void _applyWindowsDynamicStats(Map<String, dynamic> systemInfo) {
    final totalBytes = _asNum(systemInfo["InstalledRAM"]);
    final availableKb = _asNum(systemInfo["AvailableMemory"]);
    if (totalBytes != null) {
      final availableBytes =
          availableKb != null ? (availableKb * 1024).round() : null;
      devicesinfo["memory_information"]["total_memory"] = totalBytes.round();
      if (availableBytes != null) {
        devicesinfo["memory_information"]["available_memory"] =
            availableBytes;
        devicesinfo["memory_information"]["used_memory"] =
            totalBytes.round() - availableBytes;
      }
    }
    // Win32_Battery returns nothing at all on a desktop with no battery --
    // that's a real "no battery" answer, not a bug, so battery_percentage
    // correctly stays whatever it already was (0 by default) in that case.
    final batteryPercent = _asNum(systemInfo["BatteryPercent"]);
    if (batteryPercent != null) {
      devicesinfo["battery_information"]["battery_percentage"] =
          batteryPercent.round();
    }
    devicesinfo["last_seen"] = DateTime.now().toIso8601String();
  }

  num? _asNum(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }

  // Re-samples CPU/memory/last-seen and re-publishes deviceInfoMap without
  // re-running the full pairing handshake (unlike getSystemDataForWindows).
  Future<void> _refreshWindowsHeartbeatStats() async {
    try {
      final result = await getAllSystemInfo();
      if (result.exitCode != 0) return;
      final systemInfo =
          jsonDecode((result.stdout as String).trim()) as Map<String, dynamic>;
      devicesinfo["cpu_information"]["processor"] = systemInfo["CPUInfo"];
      _applyWindowsDynamicStats(systemInfo);
    } catch (e) {
      debugPrint("Heartbeat stats refresh failed: $e");
    }
  }

  // Matches the working Android player's dedicated "resource_usage" MQTT
  // message -- the Resource Usage dashboard charts read from this action
  // specifically, not from the general "player_details" device-info blob.
  // Sent every 5 minutes, same interval Android uses.
  Future<void> _sendResourceUsage() async {
    if (globleTopic.isEmpty || !Platform.isWindows) return;
    try {
      final result = await _getWindowsResourceUsageInfo();
      if (result.exitCode != 0) return;
      final info =
          jsonDecode((result.stdout as String).trim()) as Map<String, dynamic>;

      final payload = {
        "action": "resource_usage",
        "timestamp": DateTime.now().toUtc().toIso8601String(),
        "resourceUsage": {
          "memory": {
            "free": info["FreeMemMB"] ?? 0,
            "used": info["UsedMemMB"] ?? 0,
          },
          "networkTraffic": {
            "inKB": info["RxKB"] ?? 0,
            "outKB": info["TxKB"] ?? 0,
          },
          "connectivity": {
            "successRequests": _mqttClientService.successRequests,
            "failedRequests": _mqttClientService.failedRequests,
            "timeConnectedPercent": _mqttClientService.timeConnectedPercent,
          },
          "disk": {
            "free": info["DiskFreeKB"] ?? 0,
            "used": info["DiskUsedKB"] ?? 0,
          },
          "cpu": {
            "idlePercent": info["IdlePercent"] ?? 0,
            "usedPercent": info["UsedPercent"] ?? 0,
          },
          "uptime": {
            "system": info["UptimeSec"] ?? 0,
            "app": DateTime.now().difference(_appStartTime).inSeconds,
          },
          "battery": {
            "time_charging": 0,
            "level": info["BatteryLevel"] ?? 0,
          },
          "temperature": {"value": null},
        },
      };

      publishMessage(globleTopic, jsonEncode(payload));
    } catch (e) {
      debugPrint("Resource usage collection failed: $e");
    }
  }

  Future<ProcessResult> _getWindowsResourceUsageInfo() {
    return Process.run('powershell', [
      '-Command',
      '''
    \$cpu = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
    if (-not \$cpu) { \$cpu = 0 }
    \$usedPercent = [math]::Round(\$cpu)
    \$idlePercent = 100 - \$usedPercent

    \$os = Get-CimInstance Win32_OperatingSystem
    \$totalMemMB = [math]::Round(\$os.TotalVisibleMemorySize / 1024)
    \$freeMemMB = [math]::Round(\$os.FreePhysicalMemory / 1024)
    \$usedMemMB = \$totalMemMB - \$freeMemMB
    \$uptimeSec = [math]::Round((New-TimeSpan -Start \$os.LastBootUpTime -End (Get-Date)).TotalSeconds)

    \$rxBytes = 0
    \$txBytes = 0
    Get-NetAdapterStatistics -ErrorAction SilentlyContinue | ForEach-Object {
      \$rxBytes += \$_.ReceivedBytes
      \$txBytes += \$_.SentBytes
    }
    \$rxKB = [math]::Round(\$rxBytes / 1024)
    \$txKB = [math]::Round(\$txBytes / 1024)

    \$drive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
    \$diskFreeKB = [math]::Round(\$drive.FreeSpace / 1024)
    \$diskUsedKB = [math]::Round((\$drive.Size - \$drive.FreeSpace) / 1024)

    \$battery = Get-WmiObject Win32_Battery -ErrorAction SilentlyContinue
    \$batteryLevel = 0
    if (\$battery) { \$batteryLevel = \$battery.EstimatedChargeRemaining }

    \$result = @{
      "UsedPercent" = \$usedPercent
      "IdlePercent" = \$idlePercent
      "FreeMemMB" = \$freeMemMB
      "UsedMemMB" = \$usedMemMB
      "UptimeSec" = \$uptimeSec
      "RxKB" = \$rxKB
      "TxKB" = \$txKB
      "DiskFreeKB" = \$diskFreeKB
      "DiskUsedKB" = \$diskUsedKB
      "BatteryLevel" = \$batteryLevel
    }
    \$result | ConvertTo-Json
    '''
    ]);
  }

  Future<ProcessResult> getAllSystemInfo() {
    return Process.run('powershell', [
      '-Command',
      '''
    # Get drive information
    \$drives = Get-WmiObject -Class Win32_LogicalDisk | ForEach-Object {
      [PSCustomObject]@{
        "DriveLetter" = \$_."DeviceID"
        "TotalSpaceGB" = [math]::round(\$_."Size" / 1GB, 2)
        "FreeSpaceGB" = [math]::round(\$_."FreeSpace" / 1GB, 2)
        "FileSystem" = \$_."FileSystem"
      }
    }

    # Get other system information
    \$info = @{
      "CPUInfo" = (Get-WmiObject -Class Win32_Processor | Select-Object -ExpandProperty Name);
      "CPUArchitecture" = (Get-WmiObject -Class Win32_Processor | Select-Object -ExpandProperty Architecture);
      "AvailableMemory" = (Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -ExpandProperty FreePhysicalMemory);
      "TimeZone" = (Get-TimeZone).Id;
      "OSCaption" = (Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -ExpandProperty Caption);
      "OSVersion" = (Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -ExpandProperty Version);

      "DeviceName" = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Name);
      "InstalledRAM" = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty TotalPhysicalMemory);
      "Manufacturer" = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Manufacturer);
      "DeviceID" = (Get-WmiObject -Class Win32_ComputerSystemProduct | Select-Object -ExpandProperty UUID);
      "BatteryPercent" = (Get-WmiObject -Class Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty EstimatedChargeRemaining -ErrorAction SilentlyContinue);
      "Drives" = \$drives
    }

    # Output the information as JSON
    \$info | ConvertTo-Json
    '''
    ]);
  }

  Future<void> getDataForLinux() async {
    try {
      final result = await getAllSystemInfoFLinux();
      if (result.exitCode == 0) {
        final output = result.stdout.trim();

        // Parse the JSON output
        final Map<String, dynamic> systemInfo = jsonDecode(output);

        devicesinfo["sender"] = "Linux";
        devicesinfo["time_zone"] = systemInfo["TimeZone"];
        devicesinfo["mac_address"]["platform"] = "Linux";
        devicesinfo["mac_address"]["macAddress"][0]["interface"] = "wlan0";
        if (devicesinfo["mac_address"]["macAddress"][0]["interface"] ==
            "wlan0") {
          devicesinfo["mac_address"]["macAddress"][0]["mac"] =
              systemInfo["MacAddress"];
        }
        devicesinfo["ram_info"] = systemInfo["InstalledRAM"].toString();

        devicesinfo["hardware_details"]["model"] = systemInfo["DeviceName"];
        print(systemInfo["TimeZone"]);
        devicesinfo["hardware_details"]["device_id"] = systemInfo["MacAddress"];
        devicesinfo["storage_info"]["total_storage"] =
            systemInfo["DiskCapacity"].toString();

        print(systemInfo["TimeZone"]);
        devicesinfo["hardware_details"]["ram"] = systemInfo["InstalledRAM"];
        devicesinfo["cpu_information"]["cpu_architecture"] =
            systemInfo["CPUArchitecture"];
        devicesinfo["cpu_information"]["processor"] = systemInfo["CPUInfo"];

        // Print all the system information
        systemInfo.forEach((key, value) {
          print('$key: $value');
        });

        _fetchCurrentLocation();
        await _checkPairingStatus();
      } else {
        print('Error: ${result.stderr}');
      }
    } catch (e) {
      print('An error occurred: $e');
    }
  }

  Future<String> getDeviceIDForLinux() async {
    final result =
        await Process.run('bash', ['-c', 'sudo dmidecode -s system-uuid']);

    if (result.exitCode != 0) {
      return 'Error: ${result.stderr}';
    }

    return result.stdout.trim();
  }

  Future<ProcessResult> getAllSystemInfoFLinux() {
    return Process.run('bash', [
      '-c',
      '''
    # Get system information
    mac_address=\$(ip addr show | grep 'link/ether' | awk '{print \$2}' | head -n 1)
    serial_number=\$(sudo dmidecode -s system-serial-number)
    os_version=\$(uname -r)
    cpu_info=\$(lscpu | grep 'Model name' | awk -F: '{print \$2}' | xargs)
    cpu_architecture=\$(uname -m)
    available_memory=\$(free -m | grep 'Mem:' | awk '{print \$7}')
    ram_info=\$(sudo dmidecode -t memory | grep -A16 'Memory Device' | grep -E 'Size|Manufacturer|Speed' | grep -v 'No Module Installed')
    network_adapters=\$(ip link show | awk -F: '/^[0-9]+:/{print \$2}' | xargs)
    time_zone=\$(timedatectl | grep 'Time zone' | awk '{print \$3}')
    device_name=\$(hostname)
    installed_ram=\$(free -m | grep 'Mem:' | awk '{print \$2}')
    product_id=\$(sudo dmidecode -s system-product-name)
    disk_capacity=\$(df -h --total | grep 'total' | awk '{print \$2}')

    # Create JSON structure including Disk Capacity
    info=\$(cat <<EOF
    {
      "MacAddress": "\$mac_address",
      "SerialNumber": "\$serial_number",
      "OSVersion": "\$os_version",
      "CPUInfo": "\$cpu_info",
      "CPUArchitecture": "\$cpu_architecture",
      "AvailableMemory": "\$available_memory MB",
      "RAMInfo": "\$ram_info",
      "NetworkAdapters": "\$network_adapters",
      "TimeZone": "\$time_zone",
      "DeviceName": "\$device_name",
      "InstalledRAM": "\$installed_ram MB",
      "ProductID": "\$product_id",
      "DiskCapacity": "\$disk_capacity"
    }
EOF
    )

    # Output JSON
    echo "\$info"
    '''
    ]);
  }

  Future<Map<String, dynamic>?> getDeviceIdentifiersForMac() async {
    try {
      const channel = MethodChannel('com.example/systemInfo');

      // Fetch all system info (as a Map)
      final Map<dynamic, dynamic>? systemInfo =
          await channel.invokeMethod('getSystemInfo');
      // final battery = Battery();
      // final batteryLevel = await battery.batteryLevel;
      // final batteryStatus = await battery.batteryState;
      // final batteryPlugged = await battery.onBatteryStateChanged;
      // print(
      //     "this is batterydata $batteryLevel....$batteryPlugged...$batteryStatus");
      if (systemInfo != null) {
        // devicesinfo["mac_address"]["platform"] = "iOS";
        // devicesinfo["battery_information"]["battery_percentage"] = batteryLevel;
        devicesinfo["mac_address"]["macAddress"][0]["interface"] = "wlan0";
        if (devicesinfo["mac_address"]["macAddress"][0]["interface"] ==
            "wlan0") {
          devicesinfo["mac_address"]["macAddress"][0]["mac"] =
              systemInfo["uuid"];
        }
        print("System Info: $systemInfo");
        devicesinfo["android_version"] = systemInfo["os_version"];
        devicesinfo["platform"] = "macos";
        devicesinfo["device_resolution"] = systemInfo["device_resolution"];
        devicesinfo["time_zone"] = systemInfo["time_zone"];
        devicesinfo["cpu_information"] = systemInfo["cpu_information"];
        devicesinfo["memory_information"] = systemInfo["memory_information"];
        devicesinfo["storage_info"] = systemInfo["storage_info"];

        _fetchCurrentLocation();
        return Map<String, dynamic>.from(systemInfo);
      } else {
        print("Failed to retrieve system info.");
        return null;
      }
    } on PlatformException catch (e) {
      print("Failed to get device identifier: '${e.message}'.");
      return null;
    }
  }

  static Future<String?> getDeviceIdentifiers() async {
    try {
      final String? identifier =
          await _channel.invokeMethod('getDeviceIdentifier');
      print("Unique ID: $identifier");
      return identifier;
    } on PlatformException catch (e) {
      print("Failed to get device identifier: '${e.message}'.");
      return null;
    }
  }

  String get receivedMessage =>
      _mqttClientService.receivedMessageNotifier.value;

  // Guards against a recovery tick firing while the previous attempt is
  // still in flight (each attempt does real network I/O and can outlast the
  // interval), which would otherwise stack overlapping connects.
  bool _mqttConnecting = false;
  Timer? _networkRecoveryTimer;
  // Whether a connect attempt has failed and not yet succeeded. This, not
  // _state, is what the recovery timer stops on -- see _startNetworkRecovery.
  bool _needsReconnect = false;

  // The stored-content branches of the connectivity listener below called
  // _mqttClientService.connect() bare. A throw there is an unhandled async
  // error inside a stream listener callback: it aborts the REST of that
  // callback (the subscribe + device-info publish that follow it) and
  // schedules no retry, so an already-paired player that happened to start
  // while the network was still settling would render its stored content
  // but never reconnect to MQTT -- silently stuck on old content, with no
  // no-internet screen to even hint at it. Same root gap as the catch in
  // _mqttConnection(), just on the path that affects already-paired
  // devices rather than fresh installs.
  Future<bool> _tryConnect(String where) async {
    try {
      await _mqttClientService.connect();
      return true;
    } catch (error) {
      _debugLog('$where: connect FAILED: ${error.runtimeType} -- $error '
          '-- scheduling recovery retry');
      _startNetworkRecovery();
      return false;
    }
  }

  Future<void> _mqttConnection() async {
    if (_mqttConnecting) return;
    _mqttConnecting = true;
    try {
      debugPrint("Attempting to reconnect to MQTT.");
      await _mqttClientService.connect();
      _state = MqttState.connectionScreen;
      notifyListeners();
      if (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isWindows) {
        await _checkPairingStatus();
      }
      // Got through a full connect + pairing check, so whatever was wrong
      // has cleared -- stop retrying.
      _needsReconnect = false;
      _networkRecoveryTimer?.cancel();
      _networkRecoveryTimer = null;
    } catch (error) {
      _state = MqttState.noInternet;
      notifyListeners();
      debugPrint("Error during MQTT reinitialization: $error");
      _debugLog('_mqttConnection FAILED: ${error.runtimeType} -- $error '
          '-- scheduling recovery retry');
      _startNetworkRecovery();
    } finally {
      _mqttConnecting = false;
    }
  }

  // Reproduced end-to-end in Windows Sandbox: launching the player
  // immediately on a fresh boot lands on "no internet", while launching the
  // SAME build on the SAME sandbox about a minute later (after unrelated
  // HTTPS requests had been made) connects and shows the pairing code
  // normally. The network was verifiably fine in both cases -- a direct
  // POST to the very pairing endpoint this blocks on returned HTTP 200 from
  // inside that sandbox.
  //
  // So the first attempt can simply be too early: Windows hasn't finished
  // establishing internet status (NCSI) when the player starts, and
  // whatever the attempt sees at that instant used to be FINAL. This catch
  // set MqttState.noInternet and scheduled nothing at all, so the only
  // thing that could ever rescue the player was the OS connectivity stream
  // firing again -- which on Windows does not reliably fire for an
  // internet-reachability change (as opposed to an adapter appearing or
  // disappearing). One unlucky moment at startup stranded the player
  // permanently, which is exactly the "stuck on no internet over Ethernet"
  // report.
  //
  // A plain periodic retry removes that entire class of failure: it no
  // longer matters why the first attempt failed (too early, transient DNS,
  // backend blip, adapter still negotiating), because the player keeps
  // trying until it genuinely works and cancels itself the moment it does.
  //
  // Stops on _needsReconnect rather than on _state: the paired path arms
  // this while the player is happily rendering stored content
  // (_state == campaignScreen), so a state-based stop condition would
  // cancel the timer on its very first tick and fix nothing.
  void _startNetworkRecovery() {
    _needsReconnect = true;
    _networkRecoveryTimer ??=
        Timer.periodic(const Duration(seconds: 15), (_) async {
      if (!_needsReconnect) {
        _networkRecoveryTimer?.cancel();
        _networkRecoveryTimer = null;
        return;
      }
      _debugLog('network recovery tick -- retrying (state=$_state)');
      if (_state == MqttState.noInternet ||
          _state == MqttState.failure ||
          _state == MqttState.initial) {
        // Nothing on screen worth preserving -- run the full flow, which
        // also re-runs the pairing check and moves the UI off the
        // no-internet screen once it succeeds.
        await _mqttConnection();
      } else {
        // Already rendering content. Restore the MQTT session ONLY, and
        // deliberately leave _state alone: flipping a playing campaign back
        // to the Connecting screen to repair a background transport problem
        // would be a visible regression on a screen that is otherwise fine.
        await _reconnectSession();
      }
    });
  }

  /// Re-establishes the MQTT session (connect + resubscribe + republish
  /// device info, mirroring what the connectivity listener does) without
  /// touching the UI state.
  Future<void> _reconnectSession() async {
    if (_mqttConnecting) return;
    _mqttConnecting = true;
    try {
      await _mqttClientService.connect();
      if (_topic.isNotEmpty) {
        subsibeMessage(_topic);
      }
      if (globleTopic.isNotEmpty) {
        publishMessage(globleTopic, jsonEncode(deviceInfoMap));
      }
      _needsReconnect = false;
      _networkRecoveryTimer?.cancel();
      _networkRecoveryTimer = null;
      _debugLog('network recovery: MQTT session restored (state=$_state)');
    } catch (error) {
      _debugLog('network recovery: still failing -- ${error.runtimeType} -- $error');
    } finally {
      _mqttConnecting = false;
    }
  }

  double _progress = 0.0;
  bool _isDownloading = false;
  String _downloadedFilePath = '';

  double get progress => _progress;
  bool get isDownloading => _isDownloading;
  String get downloadedFilePath => _downloadedFilePath;

  int _downloadCount = 0;
  double _overallProgress = 0.0;
  int _completedDownloadCount = 0;
  double _currentFileProgress = 0.0;
  DateTime? _lastProgressNotify;

  int get downloadCount => _downloadCount;
  int get completedDownloadCount => _completedDownloadCount;
  double get overallProgress => _overallProgress;

  final Map<String, List<String>> _mediaPath = {};
  Map<String, List<String>> get mediaPath => _mediaPath;

  void _startDownloadingForPlaylist() async {
    // W07: see the matching comment in _startDownloadingForCampaign --
    // bumping (not bailing out on _state == downloading) is deliberate,
    // so a newer publication's own download pass always gets to run
    // instead of being silently dropped while an older one is still in
    // flight.
    final myGeneration = ++_contentGeneration;

    _downloadCount = _playListModel!.data.playlist.fold(
      0,
      (count, playlist) => count + (playlist.media?.length ?? 0),
    );

    Map<String, dynamic> sendLog = {
      "action": "player_logs",
      "log": "Download Playlist",
      "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      "type": "info",
      "date_time": DateTime.now().toIso8601String(),
    };
    _mqttClientService.publish(topic, jsonEncode(sendLog));
    print("Total media files to download: $_downloadCount");

    if (_downloadCount > 0) {
      _state = MqttState.downloading;
      notifyListeners();
    } else {
      _state = MqttState.noContent;
      notifyListeners();
      return;
    }

    int completedDownloads = 0;
    _overallProgress = 0.0;
    _completedDownloadCount = 0;
    _currentFileProgress = 0.0;

    for (var playlist in _playListModel!.data.playlist) {
      _mediaPath[playlist.id] = [];

      for (var media in playlist.media!) {
        String mediaUrl = media.mediaUrl;

        // For web-based media types, do NOT download; keep remote URL so they load in WebView.
        final mediaType = (media.mediaType).toLowerCase();
        if (mediaType == 'web_app_instance' || mediaType == 'text/html') {
          print(
              'Skipping download for web media type: $mediaType, url: $mediaUrl');
          _mediaPath[playlist.id]!.add(mediaUrl);
          completedDownloads++;
          _updateOverallProgress(completedDownloads);
          continue;
        }
        String filePath = await _cacheFilePathFor(mediaUrl);
        bool fileExists = await File(filePath).exists();

        if (fileExists) {
          _mediaPath[playlist.id]!.add(filePath);
          completedDownloads++;
          _updateOverallProgress(completedDownloads);
        } else {
          try {
            await downloadFileForPlaylist(mediaUrl, playlist.id);
            _mediaPath[playlist.id]!.add(filePath);
            completedDownloads++;
            _updateOverallProgress(completedDownloads);
          } catch (error) {
            print("Error downloading file: $error");
            Map<String, dynamic> errorLog = {
              "action": "player_logs",
              "log": "Download Playlist",
              "name":
                  "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
              "type": "error",
              "date_time": DateTime.now().toIso8601String(),
            };

            _mqttClientService.publish(topic, jsonEncode(errorLog));
            _state = MqttState.failure;
            notifyListeners();
          }
        }
      }
    }

    if (completedDownloads == _downloadCount) {
      print("All media files for all playlists have been downloaded.");
      if (myGeneration != _contentGeneration) {
        // W07: superseded by a newer publication.
        return;
      }
      _updateMediaModelForPlaylist(); // Update model with local file paths
      if (_state == MqttState.playerStopped) {
        // W08: a stop command can arrive while a download that started
        // before it is still in flight -- this completion must not
        // silently resume playback. Only the authorized resume path
        // (paired:true on the next poll, in _checkPairingStatus) may
        // leave playerStopped.
        return;
      }
      _state = MqttState.playlistScreen;
      notifyListeners();
    }
  }

  void _updateOverallProgress(int completedDownloads) {
    _completedDownloadCount = completedDownloads;
    _currentFileProgress = 0.0;
    _overallProgress =
        _downloadCount > 0 ? completedDownloads / _downloadCount : 0.0;
    print(
        'Overall progress: ${(_overallProgress * 100).toStringAsFixed(2)}% ($completedDownloads/$_downloadCount)');
    notifyListeners();
  }

  void _updateCurrentFileProgress(int received, int total) {
    if (total <= 0) return;
    _currentFileProgress = received / total;
    _overallProgress = _downloadCount > 0
        ? (_completedDownloadCount + _currentFileProgress) / _downloadCount
        : 0.0;
    final now = DateTime.now();
    if (_lastProgressNotify == null ||
        now.difference(_lastProgressNotify!).inMilliseconds >= 100) {
      _lastProgressNotify = now;
      notifyListeners();
    }
  }

  void _updateMediaModelForPlaylist() {
    if (_playListModel != null) {
      for (var playlist in _playListModel!.data.playlist) {
        if (_mediaPath.containsKey(playlist.id)) {
          List<String> playlistMediaPaths = _mediaPath[playlist.id]!;
          for (int i = 0; i < playlist.media!.length; i++) {
            if (i < playlistMediaPaths.length) {
              String localPath = playlistMediaPaths[i];
              if (File(localPath).existsSync()) {
                playlist.media![i].mediaUrl = localPath; // Update to local path
              } else {
                print("File not found: $localPath");
              }
            }
          }
        }
      }
      _playListModel!.data.playlist.forEach((playlist) {
        playlist.media!.forEach((media) {
          print("Updated Media URL: ${media.mediaUrl}");
        });
      });
      notifyListeners();
    }
  }

  Future<void> downloadFileForPlaylist(String url, String playlistId,
      {int retries = 3}) async {
    int attempt = 0;
    while (attempt < retries) {
      try {
        attempt++;
        print('Downloading from URL: $url (attempt $attempt/$retries)');

        _currentFileProgress = 0.0;
        notifyListeners();

        // Temp file + atomic rename inside _downloadToCache (W09): a
        // crash/interruption mid-download can no longer leave a corrupt
        // file sitting at the cache path a later run would treat as
        // already-downloaded.
        final filePath = await _downloadToCache(
          url,
          onProgress: _updateCurrentFileProgress,
        );

        print('Download complete: $filePath');
        return; // Exit on successful download
      } catch (e) {
        print('Download attempt $attempt failed: $e');
        if (attempt >= retries) {
          print('Maximum retry attempts reached. Download failed.');
          throw Exception('Download failed after $retries attempts: $e');
        } else {
          print('Retrying download...');
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }
  }

  void _startDownloadingForCampaign() async {
    // W07: bumping (not bailing out when _state is already `downloading`)
    // is deliberate -- the old `if (_state == downloading) return;` guard
    // blocked exactly the case that needed to keep working: campaign B
    // published while campaign A's download pass was still running used
    // to make B's own call return immediately without ever downloading
    // B's assets, leaving only A's (stale, and about to be superseded)
    // download pass running -- whichever completes last then wins,
    // regardless of which was actually published last. Bumping the
    // generation here lets B's own pass proceed, and lets A's pass
    // recognize at its own completion (below) that it's been superseded.
    final myGeneration = ++_contentGeneration;

    Map<String, dynamic> sendLog = {
      "action": "player_logs",
      "log": "Download Campaign",
      "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      "type": "info",
      "date_time": DateTime.now().toIso8601String(),
    };

    _mqttClientService.publish(topic, jsonEncode(sendLog));

    // Collect ALL downloadable media items (including nested sub-zones inside campaign media).
    final downloadTargets = _collectCampaignMediaItemsForDownload(
      _campaignModel?.data?.playerCampaigns ?? const [],
    );
    _downloadCount = downloadTargets.length;

    print("Total files to download: $_downloadCount");

    final campaigns = _campaignModel?.data?.playerCampaigns ?? const [];
    final hasPlayableCampaignMedia = _campaignHasPlayableMediaItems(campaigns);

    // #region agent log
    _mqttAgentDebugLog(
      'mqtt_view_model.dart:_startDownloadingForCampaign',
      'download target summary',
      {
        'downloadCount': _downloadCount,
        'campaignCount': campaigns.length,
        'hasPlayableCampaignMedia': hasPlayableCampaignMedia,
      },
      'C',
    );
    // #endregion

    if (_downloadCount > 0) {
      _state = MqttState.downloading;
      notifyListeners();
    } else if (hasPlayableCampaignMedia) {
      // W07: a newer publication has since started -- this one is stale,
      // don't let it commit state for content that's no longer current.
      if (myGeneration != _contentGeneration) {
        // Confirmed real-world symptom: a web-app-only campaign was
        // received and parsed correctly, but the screen didn't switch to
        // it for 5+ minutes with zero prior evidence of why. This guard is
        // the one place a legitimate, fresh publish_campaign's own state-
        // commit gets silently dropped -- including by
        // _monitorConnectivity's connectivity-restore path, which ALSO
        // calls this same function (using possibly-stale storedJsonObj)
        // and would bump _contentGeneration out from under this call if it
        // fires concurrently. If this line shows up right after a
        // publish_campaign that never displays, that race is confirmed.
        _debugLog(
            'campaign download: myGeneration=$myGeneration != current='
            '$_contentGeneration -- discarding this campaign\'s own state commit');
        return;
      }
      // W08: don't let a stale in-flight publication resume playback out
      // from under an active stop command -- see the matching guard in
      // the playlist download-completion path above.
      if (_state == MqttState.playerStopped) return;
      print(
          'No downloadable files; showing campaign with web/inline media '
          '(${campaigns.length} campaign(s)).');
      _debugLog('campaign download: setting campaignScreen '
          '(${campaigns.length} campaign(s), generation=$myGeneration)');
      _selectCompositionCampaignIndexIfPresent();
      _state = MqttState.campaignScreen;
      notifyListeners();
      return;
    } else {
      _state = MqttState.noContent;
      notifyListeners();
      return;
    }

    int completedDownloads = 0;
    _overallProgress = 0.0;
    _completedDownloadCount = 0;
    _currentFileProgress = 0.0;

    for (final media in downloadTargets) {
      String? originalUrl;
      final dlMediaType = media.mediaType?.toLowerCase();
      if (dlMediaType == 'sticker' || dlMediaType == 'shape') {
        originalUrl = media.settings?.remoteSrc ?? media.mediaUrl;
      } else {
        originalUrl = media.mediaUrl;
      }

      if (originalUrl == null || originalUrl.isEmpty) {
        completedDownloads++;
        _overallProgress = completedDownloads / _downloadCount;
        notifyListeners();
        continue;
      }

      _completedDownloadCount = completedDownloads;
      _currentFileProgress = 0.0;
      notifyListeners();

      try {
        final localPath = await ensureLocalMediaUrl(
          originalUrl,
          onProgress: _updateCurrentFileProgress,
        );
        // Update the appropriate URL field
        if (dlMediaType == 'sticker' || dlMediaType == 'shape') {
          // Stickers/shapes: always store local path in settings.remoteSrc so the UI uses it at render time
          media.settings ??= Settings();
          media.settings!.remoteSrc = localPath;
          media.mediaUrl = localPath; // keep mediaUrl in sync for fallback
        } else if (media.isAd || idLooksLikeAdSlot(media.id)) {
          media.settings ??= Settings();
          if (originalUrl.startsWith('http')) {
            media.settings!.creativeUrl = originalUrl;
          }
          media.mediaUrl = localPath;
        } else {
          media.mediaUrl = localPath;
        }
        completedDownloads++;
        _overallProgress = completedDownloads / _downloadCount;
        print(
            'Overall progress: ${(_overallProgress * 100).toStringAsFixed(2)}%');
        notifyListeners();
      } catch (error) {
        print("Error downloading file: $error");
        Map<String, dynamic> sendLog = {
          "action": "player_logs",
          "log": "Download Campaign",
          "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
          "type": "error",
          "date_time": DateTime.now().toIso8601String(),
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
        // Keep original URL so campaign view can still try to load from network.
        // Don't set failure – continue and show campaign with partial downloads.
        completedDownloads++;
        _overallProgress = completedDownloads / _downloadCount;
        notifyListeners();
      }
    }

    print("All files processed.");
    // Land on a non-paused campaign now that downloads are done, instead of
    // whatever _currentIndexOfCapmaign was left at -- otherwise a Paused
    // campaign that happened to be selected before downloading kicked in
    // would still be shown once playback actually starts.
    _selectCompositionCampaignIndexIfPresent();
    if (myGeneration != _contentGeneration) {
      // W07: superseded by a newer publication -- don't commit state for
      // content that's no longer current.
      return;
    }
    if (_state == MqttState.playerStopped) {
      // W08: same guard as the other two download-completion paths -- a
      // stop command that arrived while this download was in flight must
      // not be resumed by its completion.
      return;
    }
    final campaignsAfterDownload = _campaignModel?.data?.playerCampaigns ?? const [];
    if (campaignsAfterDownload.isNotEmpty &&
        !_campaignIsPlayable(campaignsAfterDownload[_currentIndexOfCapmaign])) {
      _state = MqttState.noContent;
    } else {
      _state = MqttState.campaignScreen;
    }
    notifyListeners();
  }

  bool _isNestedCampaignMediaItem(MediaItem media) {
    final type = (media.mediaType ?? '').toLowerCase();
    return type == 'campaign' ||
        type == 'composition' ||
        (media.zones != null && media.zones!.isNotEmpty);
  }

  List<MediaItem> _collectCampaignMediaItemsForDownload(
      List<Campaign> campaigns) {
    final result = <MediaItem>[];

    void visitZones(List<CampaignZone> zones) {
      for (final zone in zones) {
        final items = zone.mediaItems ?? const <MediaItem>[];
        for (final media in items) {
          // Skip purely web-based / inline media: keep remote URLs or render in-app.
          final mediaType = (media.mediaType ?? '').toLowerCase();
          if (mediaType == 'web_app_instance' ||
              mediaType == 'text/html' ||
              mediaType == 'text') {
            continue;
          }
          if (mediaType == 'content' && mediaItemIsWebAppIframe(media)) {
            continue;
          }
          if (_isNestedCampaignMediaItem(media)) {
            visitZones(media.zones ?? const <CampaignZone>[]);
            continue;
          }
          // For stickers and shapes, prefer settings.remoteSrc (the CMS's
          // real pre-rendered asset URL, populated from download_url/
          // downloadUrl) over mediaUrl -- for shapes, mediaUrl is often
          // already-synthesized inline SVG markup with nothing left to
          // download, so the inline-svg check below must run against
          // whichever URL is actually selected here, not raw mediaUrl.
          String? url;
          if (media.isAd || idLooksLikeAdSlot(media.id)) {
            url = media.adCreativeUrl;
          } else if (mediaType == 'sticker' || mediaType == 'shape') {
            url = media.settings?.remoteSrc ?? media.mediaUrl;
          } else {
            url = media.mediaUrl;
          }
          if (url == null || url.isEmpty || url.contains('<svg')) {
            continue;
          }
          result.add(media);
        }
      }
    }

    for (final c in campaigns) {
      visitZones(c.zones ?? const <CampaignZone>[]);
    }
    return result;
  }

  bool _campaignHasPlayableMediaItems(List<Campaign> campaigns) {
    for (final campaign in campaigns) {
      if (campaign.isPaused == true) continue;
      final zones = campaign.zones;
      if (zones == null || zones.isEmpty) continue;

      bool zoneHasMedia(List<CampaignZone> zoneList) {
        for (final zone in zoneList) {
          final items = zone.mediaItems;
          if (items != null && items.isNotEmpty) return true;
        }
        return false;
      }

      if (zoneHasMedia(zones)) return true;
    }
    return false;
  }

  /// Downloads [url] to local storage and returns the cached file path, or
  /// the original URL if every retry failed. Public so widgets (e.g.
  /// VideoPlayerWidget) can self-heal a video that reaches them as a raw
  /// network URL -- because the upstream campaign-wide download pass
  /// missed it, or a retry is worth it -- instead of streaming it directly
  /// over the network on every play, which is slow and can hang for tens
  /// of seconds on a flaky connection.
  Future<String> ensureLocalMediaUrl(String url,
      {void Function(int received, int total)? onProgress}) async {
    final trimmed = url.trim();

    if (trimmed.startsWith('<svg') ||
        (trimmed.contains('<svg') && trimmed.contains('</svg>'))) {
      return trimmed;
    }

    String fullUrl = trimmed;
    if (trimmed.startsWith('/') &&
        !trimmed.startsWith('http://') &&
        !trimmed.startsWith('https://')) {
      fullUrl = 'https://$apiHost$trimmed';
      print('Converting relative path to full URL: $trimmed -> $fullUrl');
    }

    if (!fullUrl.startsWith('http://') && !fullUrl.startsWith('https://')) {
      if (fullUrl.startsWith('/Users') ||
          fullUrl.startsWith('/tmp') ||
          fullUrl.startsWith('/var')) {
        return fullUrl;
      }
      // Otherwise, it might be a relative path we couldn't resolve
      return fullUrl;
    }

    final filePath = await _cacheFilePathFor(fullUrl);
    final exists = await File(filePath).exists();
    if (exists) {
      print('File already exists: $filePath');
      return filePath;
    }

    // W11: this used to run the *whole* URL through Uri.encodeFull, which
    // re-encodes already-valid percent-escapes too -- confirmed to turn
    // "video%20one.mp4?token=a%2Fb" into "video%2520one.mp4?token=a%252Fb".
    // That silently corrupts any URL that arrived already correctly
    // encoded, in particular a signed query parameter: a %2F inside a
    // signature becoming %252F invalidates it against whatever backend
    // verifies it, turning a previously-working asset into a 404/403.
    // The actual, confirmed real-world problem is narrower: a literal
    // unencoded space in a CMS asset path (e.g.
    // "/_next/static/media/Leaf 4.6bb812d5.svg") is invalid in the actual
    // HTTP request line, which made the download fail silently for every
    // asset whose filename happened to contain one ("some stickers load,
    // some don't" -- all 10 counted as "downloaded" in the progress UI
    // regardless, since a failed download still increments that counter --
    // see the catch block further down in this file). Encoding only
    // whitespace characters -- never touching an existing "%" escape, or
    // any other already-valid URI character -- fixes that specific,
    // confirmed problem without corrupting everything else.
    String downloadUrl = encodeUrlWhitespaceOnly(fullUrl);
    try {
      Uri.parse(downloadUrl);
    } catch (_) {
      // Still-illegal percent encoding (e.g. a lone "%" not followed by two
      // hex digits) despite the whitespace fix above -- escape any bare "%"
      // so the URL is at least parseable, without touching % sequences
      // that are already valid.
      downloadUrl = downloadUrl.replaceAllMapped(
          RegExp(r'%(?![0-9A-Fa-f]{2})'), (_) => '%25');
    }

    // W10: connectTimeout bounds a hanging-headers stall (connection
    // opens but the server never responds); receiveTimeout bounds a
    // hanging-body stall (gap between received chunks). Neither alone
    // bounds a slow-but-steady trickle transfer that never gaps long
    // enough to trip receiveTimeout -- the outer .timeout() below on the
    // whole download call is the actual overall deadline for that case.
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ));
    // Unique per call (not a fixed "$filePath.part"): two concurrent
    // callers resolving the same URL (W09 -- "concurrent requests for one
    // asset") each get their own temp file, so neither can corrupt the
    // other's write, and a stale .part left by a previous crashed run
    // can't collide with a fresh attempt either.
    final tempPath = '$filePath.${DateTime.now().microsecondsSinceEpoch}.part';
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      print(
          'Downloading from URL: $downloadUrl to $filePath (attempt $attempt/$maxAttempts)');
      try {
        // Temp file + atomic rename (W09): an interruption mid-download can
        // no longer leave a corrupt file at $filePath that a later call
        // would treat as already-cached via the exists() check above.
        await dio.download(
          downloadUrl,
          tempPath,
          onReceiveProgress: (received, total) {
            if (total > 0) onProgress?.call(received, total);
          },
        ).timeout(const Duration(minutes: 5)); // W10: overall deadline
        await File(tempPath).rename(filePath);
        print('Download complete: $filePath');
        return filePath;
      } catch (e) {
        print('Error downloading $downloadUrl (attempt $attempt/$maxAttempts): $e');
        try {
          if (await File(tempPath).exists()) await File(tempPath).delete();
        } catch (_) {}
        if (attempt >= maxAttempts) {
          // Out of retries -- return the original URL so the widget can try
          // to stream it directly as a last resort.
          return fullUrl;
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    return fullUrl;
  }

  Future<void> requestStoragePermission() async {
    var status = await Permission.storage.status;
    if (!status.isGranted) {
      var result = await Permission.storage.request();
      if (result.isGranted) {
        print('Storage permission granted');
      } else {
        print('Storage permission denied');
        throw Exception('Storage permission not granted');
      }
    }

    // For Android 11 and above
    if (Platform.isAndroid &&
        await Permission.manageExternalStorage.isGranted == false) {
      var result = await Permission.manageExternalStorage.request();
      if (result.isGranted) {
        print('External storage management permission granted');
      } else {
        print('External storage management permission denied');
        throw Exception('External storage management permission not granted');
      }
    }
  }

  // ── content-addressed media cache (W02 / W09) ───────────────────────────
  // The cache filename used to be extracted straight from the URL's own
  // basename (split on '/', strip a small set of characters) and written
  // under the user's real Downloads/Documents folder. That had two
  // separate problems:
  //   W02 - the decoded URL was only ever split on forward slash, so a
  //   backslash arriving from a source URL (e.g. a percent-encoded
  //   "..%5Coutside.mp4") passed straight through -- Windows treats a
  //   backslash as a path separator regardless of how the extraction code
  //   split the string, so that filename could write outside the intended
  //   directory. Reserved Windows device names and trailing dots weren't
  //   rejected either.
  //   W09 - two different URLs that happen to share a final path segment
  //   (e.g. .../a/video.mp4 and .../b/video.mp4) shared one cache file, an
  //   existing file was trusted on name+existence alone with no content
  //   identity/version check, and downloads wrote directly to the final
  //   path -- an interrupted write left a corrupt file that looked cached.
  //
  // The fix: the cache key is a hash of the *whole source URL*, not its
  // basename (different URLs can never collide), the extension is
  // extracted separately and validated against a strict whitelist (a
  // hash + a whitelisted 1-8 character extension can never contain a
  // path separator, a ".." segment, or resolve to a reserved device
  // name), the cache lives in a dedicated app-private directory instead
  // of the user's real Downloads/Documents, and writes land in a ".part"
  // temp file first, atomically renamed into place only once the download
  // actually completes -- so a crash/interruption mid-download can never
  // leave a corrupt file at the final path that a later run would treat
  // as already cached.

  Directory? _cacheRootCached;

  // A dedicated, app-private cache directory -- not the user's real
  // Downloads/Documents folder (W09), so cached media can never collide
  // with, be tampered with by, or be mistaken for the user's own files,
  // and a future eviction policy can safely operate on this directory
  // alone.
  Future<Directory> _cacheRootDirectory() async {
    if (_cacheRootCached != null) return _cacheRootCached!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/media_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheRootCached = dir;
    return dir;
  }

  /// Resolves the safe, content-addressed cache path for [url]. Every
  /// download/reuse call site must go through this -- never build a cache
  /// path from a URL's raw basename directly. The actual filename logic
  /// lives in cache_path_utils.dart (pure, unit-tested independently of
  /// this class).
  Future<String> _cacheFilePathFor(String url, {String? mediaType}) async {
    final name = cacheFilenameFor(url, mediaType: mediaType);
    final root = await _cacheRootDirectory();
    return '${root.path}/$name';
  }

  // Keyed by the resolved cache path (not the raw URL) so two different
  // URLs that happen to resolve to the same content-addressed path (i.e.
  // literally the same URL) share one in-flight download instead of two
  // concurrent writers racing on the same temp file (W09 -- "concurrent
  // requests for one asset").
  final Map<String, Future<String>> _inFlightCacheDownloads = {};

  /// Downloads [url] to its content-addressed cache path via a temp file
  /// plus atomic rename, so an interrupted write can never leave a
  /// corrupt file at the final path (W09). Returns the final path.
  /// Reuses an existing completed file without re-downloading -- a real
  /// freshness check needs a server-provided version/hash (see W09's
  /// backend-dependency note); this only guards against a *different* URL
  /// reusing another URL's file, not the same URL's bytes changing
  /// upstream.
  Future<String> _downloadToCache(
    String url, {
    String? mediaType,
    void Function(int received, int total)? onProgress,
  }) async {
    final finalPath = await _cacheFilePathFor(url, mediaType: mediaType);
    if (await File(finalPath).exists()) {
      return finalPath;
    }
    final existing = _inFlightCacheDownloads[finalPath];
    if (existing != null) {
      return existing;
    }
    final future = _downloadToCacheUncached(url, finalPath, onProgress);
    _inFlightCacheDownloads[finalPath] = future;
    try {
      return await future;
    } finally {
      _inFlightCacheDownloads.remove(finalPath);
    }
  }

  Future<String> _downloadToCacheUncached(
    String url,
    String finalPath,
    void Function(int received, int total)? onProgress,
  ) async {
    // Unique per attempt (not just "$finalPath.part"): even with the
    // in-flight dedup above, a previous crashed run could have left a
    // stale .part file around, and this guarantees a fresh download never
    // collides with it.
    final tempPath =
        '$finalPath.${DateTime.now().microsecondsSinceEpoch}.part';
    // W10: see the matching comment on the Dio instance in
    // ensureLocalMediaUrl -- connect/receive timeouts plus an outer overall
    // deadline, so a single unresponsive asset can't strand playback
    // preparation indefinitely.
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ));
    try {
      await dio.download(
        url,
        tempPath,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received, total);
        },
      ).timeout(const Duration(minutes: 5));
      // Rename is atomic on the same volume (both paths share the cache
      // root), so a reader can never observe a partially-written file at
      // the final path.
      await File(tempPath).rename(finalPath);
      return finalPath;
    } catch (e) {
      try {
        if (await File(tempPath).exists()) await File(tempPath).delete();
      } catch (_) {}
      rethrow;
    }
  }

  // W17: reportAdProofOfPlay's catch block used to just print and drop the
  // report on any HTTP/network error -- a slot that failed to report during
  // a network blip was simply never recorded, with nothing to ever retry
  // it. This persists a failed report (SharedPreferences, capped size, one
  // entry per dedupKey so repeated failures for the same slot don't pile
  // up duplicates) and drains it opportunistically: on connectivity
  // restore (_monitorConnectivity's own reachability listener already
  // fires exactly when this becomes worth retrying) and once at startup.
  //
  // What this does NOT establish: proof the server actually recorded a
  // given report exactly once. postData treats any non-throwing response as
  // success with no receipt/idempotency key echoed back, so if a request
  // reached the server and it failed only on the response round-trip (e.g.
  // the connection dropped after the server committed it), a queued retry
  // could cause a real server-side duplicate. That needs a backend-side
  // idempotency contract this player can't unilaterally create.
  static const String _kAdProofOfPlayQueueKey = 'ad_proof_of_play_retry_queue';
  static const int _kMaxQueuedAdProofOfPlay = 50;

  Future<void> reportAdProofOfPlay(AdProofOfPlayRequest request) async {
    final url = '$baseurl$adCampaignProofOfPlayPath';
    if (playerCode.isEmpty) {
      print('[AdPoP] Skipped: player_code is empty (POST $url)');
      return;
    }
    final sent = await _postAdProofOfPlay(request);
    if (!sent) {
      await _enqueueFailedAdProofOfPlay(request);
    }
  }

  Future<bool> _postAdProofOfPlay(AdProofOfPlayRequest request) async {
    final url = '$baseurl$adCampaignProofOfPlayPath';
    try {
      final body = request.toJson();
      print('[AdPoP] POST $url');
      print('[AdPoP] Payload: $body');
      final response = await ApiRepository().postData(
        adCampaignProofOfPlayPath,
        body,
        null,
      );
      print('[AdPoP] Response: $response');
      print('[AdPoP] Report sent successfully');
      return true;
    } catch (e, st) {
      print('[AdPoP] HTTP/network error: $e');
      print('[AdPoP] Stack: $st');
      return false;
    }
  }

  Future<void> _enqueueFailedAdProofOfPlay(AdProofOfPlayRequest request) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kAdProofOfPlayQueueKey) ?? [];
      final queue = raw
          .map((e) {
            try {
              return AdProofOfPlayRequest.fromJson(
                  jsonDecode(e) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<AdProofOfPlayRequest>()
          .toList();
      queue.removeWhere((q) => q.dedupKey == request.dedupKey);
      queue.add(request);
      // Bounded, oldest-dropped-first -- this is best-effort delivery, not a
      // durable audit log; an unbounded queue on a device that's offline for
      // a long stretch would otherwise grow forever.
      while (queue.length > _kMaxQueuedAdProofOfPlay) {
        queue.removeAt(0);
      }
      await prefs.setStringList(
        _kAdProofOfPlayQueueKey,
        queue.map((q) => jsonEncode(q.toJson())).toList(),
      );
      print('[AdPoP] Queued for retry (queue size=${queue.length}): '
          '${request.dedupKey}');
    } catch (e) {
      print('[AdPoP] Failed to persist retry queue entry: $e');
    }
  }

  /// Drains the persisted proof-of-play retry queue -- called on
  /// connectivity restore and once at startup. Each entry is attempted at
  /// most once per call; a still-failing entry stays queued for the next
  /// call instead of being retried in a tight loop against a network that
  /// just proved it's still down.
  Future<void> retryQueuedAdProofOfPlay() async {
    List<String> raw;
    try {
      final prefs = await SharedPreferences.getInstance();
      raw = prefs.getStringList(_kAdProofOfPlayQueueKey) ?? [];
    } catch (e) {
      print('[AdPoP] retryQueuedAdProofOfPlay: failed to read queue: $e');
      return;
    }
    if (raw.isEmpty) return;

    print('[AdPoP] Retrying ${raw.length} queued proof-of-play report(s)');
    final stillFailed = <String>[];
    for (final entry in raw) {
      AdProofOfPlayRequest? request;
      try {
        request =
            AdProofOfPlayRequest.fromJson(jsonDecode(entry) as Map<String, dynamic>);
      } catch (_) {
        continue; // corrupt entry -- drop it, nothing to retry
      }
      final sent = await _postAdProofOfPlay(request);
      if (!sent) stillFailed.add(entry);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      if (stillFailed.isEmpty) {
        await prefs.remove(_kAdProofOfPlayQueueKey);
      } else {
        await prefs.setStringList(_kAdProofOfPlayQueueKey, stillFailed);
      }
    } catch (e) {
      print('[AdPoP] retryQueuedAdProofOfPlay: failed to save queue: $e');
    }
  }

  Future<void> _checkPairingStatus() async {
    Map<String, dynamic> requestBody;

    if (Platform.isAndroid) {
      requestBody = {
        "platform": "android",
        "macAddress": [
          {"mac": macAddresses['wlan0'] ?? "123123", "interface": "wlan0"},
          {"mac": macAddresses['eth0'] ?? "123213", "interface": "eth0"}
        ]
      };
    } else if (Platform.isIOS || Platform.isMacOS) {
      final uuid = Platform.isIOS
          ? await getDeviceIdentifiers()
          : (await getDeviceIdentifiersForMac())?["uuid"];

      requestBody = {"platform": "ios", "uuid": uuid ?? "unknown"};
      print(requestBody);
    } else if (Platform.isWindows) {
      requestBody = {"platform": "windows", "uuid": await getDeviceID()};
      print("windows$requestBody");
    } else if (Platform.isLinux) {
      requestBody = {"platform": "linux", "uuid": await getDeviceIDForLinux()};
      print("windows$requestBody");
    } else {
      debugPrint("Unsupported platform");

      return;
    }

    debugPrint("Request body: $requestBody");

    try {
      final response = await ApiRepository().postData(
        "player/connection/",
        requestBody,
        null,
      );
      final jsonResponse = jsonEncode(response);

      SharedPreferences prefs = await SharedPreferences.getInstance();
      bool isSaved = await prefs.setString('apiResponse', jsonResponse);
      print("check status ::::$isSaved");

      _topic = response["player_code"] ?? "";

      if (_topic.isEmpty) {
        debugPrint("Warning: player_code is empty or null in API response");
        _state = MqttState.failure;
        notifyListeners();
        return;
      }

      globleTopic = _topic;

      // The MQTT socket is normally connected by the backend-reachability
      // listener in _monitorConnectivity(), but that's an independent async
      // race against this pairing check -- on Windows, getSystemDataForWindows()
      // calls _checkPairingStatus() directly from the constructor path with no
      // guarantee that listener has fired yet. If it hasn't, subsibeMessage()
      // below calls into a client that was never told to connect, which
      // throws and gets swallowed by the catch block as if the pairing
      // request itself had failed -- leaving the state stuck on
      // "connecting" even though this HTTP response came back fine.
      if (!_mqttClientService.isConnected) {
        _debugLog('_checkPairingStatus: MQTT not connected yet, connecting before subscribe');
        await _mqttClientService.connect();
      }

      subsibeMessage(_topic);
      _mqttClientService.publish(
        '$globleTopic/player_status',
        jsonEncode({'status': 'online'}),
      );
      _debugLog(
          '_checkPairingStatus: published online presence to $globleTopic/player_status');
      _debugLog('_checkPairingStatus: publishing deviceInfoMap to $globleTopic: ${jsonEncode(deviceInfoMap)}');
      publishMessage(globleTopic, jsonEncode(deviceInfoMap));

      // Reset retry counter on successful connection
      _pairingRetryCount = 0;

      if (response["paired"] == false &&
          response["action"] == "action_stop_player") {
        // PLAYER_STOP_REASON_CONTRACT: this player IS paired -- the backend
        // stopped it for a licence/subscription/account reason, which is
        // completely different from never having been paired at all.
        // Deliberately does NOT touch storeState/prefs (that would make
        // action_setup_player's `storeState == false` gate re-run
        // _checkPairingStatus and, worse, would make the pairedScreen QR
        // code briefly flash on every resume too), does NOT call
        // _stopPeriodicReporting() (the player is still up and reporting
        // fine, it's just not displaying anything), and does NOT clear any
        // cached campaign/media state -- _getScreenForState swapping to
        // PlayerStoppedView is what actually stops the content from
        // showing; nothing underneath it is torn down, so a resume is
        // instant. An unrecognised reason value still lands here and is
        // handled generically by PlayerStoppedView -- never falls through
        // to the pairing-code screen.
        _stopReason = (response["reason"] ?? "").toString();
        _state = MqttState.playerStopped;

        // Same poll-until-resumed mechanism as the unpaired case below --
        // per the contract there's no push on restore, only the next poll.
        _pairingPollTimer ??=
            Timer.periodic(const Duration(seconds: 10), (_) async {
          await _checkPairingStatus();
        });
      } else if (response["paired"] == false) {
        print("this is state screeen ${response["paired"]}");
        await prefs.setBool('storeState', response["paired"]);
        storeState = false;

        _stopPeriodicReporting();
        _state = MqttState.pairedScreen;

        _pairingPollTimer ??=
            Timer.periodic(const Duration(seconds: 10), (_) async {
          await _checkPairingStatus();
        });
      } else if (response["paired"] == true) {
        _stopReason = null;
        _pairingPollTimer?.cancel();
        _pairingPollTimer = null;

        // Persist paired=true so the action_setup_player handler's
        // `storeState == false` gate (mqtt_view_model.dart ~2280) stops
        // re-running this whole pairing check on every subsequent
        // action_setup_player message from the broker. Without this, storeState
        // stayed false forever once a device had ever been unpaired, so every
        // action_setup_player echo re-ran _checkPairingStatus and forced
        // _state back to MqttState.noContent below -- blanking whatever
        // campaign/video was actively playing, repeatedly, which is what
        // looked like "video not playing".
        await prefs.setBool('storeState', true);
        storeState = true;

        if (_state == MqttState.playerStopped) {
          // PLAYER_STOP_REASON_CONTRACT: "there is no separate resume
          // message... the poll is the entire mechanism" -- nothing
          // re-sends the campaign on restore, so falling through to the
          // generic noContent branch below would leave the screen stuck
          // there forever (nothing else would ever move it back to
          // campaignScreen). _campaignModel/_playListModel were never
          // touched while stopped, so they're exactly what has to bring
          // the screen back -- resume instantly from that instead.
          _startPeriodicReporting();
          if (_campaignModel != null) {
            _state = MqttState.campaignScreen;
          } else if (_playListModel != null) {
            _state = MqttState.playlistScreen;
          } else {
            _state = MqttState.noContent;
          }
        } else if (_state != MqttState.campaignScreen &&
            _state != MqttState.playlistScreen &&
            _state != MqttState.downloading) {
          // Only the initial pairing handshake should drop to noContent --
          // once already showing real content, a redundant pairing
          // confirmation shouldn't blank the screen out from under it.
          _startPeriodicReporting();
          _state = MqttState.noContent;
        }
      } else {
        _state = MqttState.failure;
      }
      notifyListeners();
    } catch (error) {
      debugPrint("Error during pairing check: $error");
      // This catch is what puts the player on the "Connecting..." screen,
      // and until now it only ever explained itself through debugPrint --
      // invisible in a release build. That made every "it won't connect"
      // report (notably: works on Wi-Fi, stuck on Connecting over
      // Ethernet) an unreadable black box: no way to tell a DNS failure
      // from a TLS failure from a timeout from an HTTP 4xx/5xx, which are
      // four completely different problems with four different fixes.
      // The error's runtimeType matters as much as its message here --
      // SocketException vs HandshakeException vs TimeoutException is
      // exactly the distinction that identifies an Ethernet-specific
      // network fault.
      _debugLog('_checkPairingStatus FAILED: ${error.runtimeType} -- $error '
          '(retryCount=$_pairingRetryCount state=$_state)');

      // Don't restart or retry if already on the pairing screen, or
      // currently stopped -- both already have _pairingPollTimer quietly
      // retrying every 10s, so a transient network error here shouldn't
      // force a disruptive full app restart on top of that.
      if (_state == MqttState.pairedScreen ||
          _state == MqttState.playerStopped) {
        debugPrint(
            "Device is already paired or stopped. Skipping retry and restart.");
        return;
      }

      _pairingRetryCount++;

      // Check if error is a 500 server error
      final errorString = error.toString();
      final isServerError = errorString.contains('500') ||
          errorString.contains('Error During Communication');

      if (isServerError && _pairingRetryCount >= _maxPairingRetries) {
        debugPrint(
            "Max retries ($_maxPairingRetries) reached for pairing check. "
            "Attempting restartApp (no confirmed Windows handler -- see "
            "restartApp) and falling back to periodic recovery polling "
            "regardless of whether that actually restarts anything.");
        _pairingRetryCount = 0; // Reset counter
        await Future.delayed(const Duration(seconds: 2));
        await restartApp();
        // W21: if restartApp actually works on this platform, the process
        // is about to end anyway and this never matters. If it's a no-op
        // (confirmed: no matching Windows handler), this is what actually
        // recovers the device instead of leaving it stuck forever.
        _state = MqttState.connectionScreen;
        notifyListeners();
        _pairingPollTimer ??=
            Timer.periodic(const Duration(seconds: 10), (_) async {
          await _checkPairingStatus();
        });
        return;
      }

      // Retry with exponential backoff
      if (_pairingRetryCount < _maxPairingRetries) {
        final delaySeconds = _pairingRetryCount * 2; // 2, 4, 6 seconds
        debugPrint(
            "Retrying pairing check in $delaySeconds seconds (attempt $_pairingRetryCount/$_maxPairingRetries)");
        await Future.delayed(Duration(seconds: delaySeconds));
        // Retry the pairing check
        _state = MqttState.connectionScreen;
        notifyListeners();
        await _checkPairingStatus();
        return;
      }

      // W21: retries exhausted for a non-server error (DNS failure, generic
      // timeout, unreachable host, etc.) -- this used to just show
      // connectionScreen and stop, with nothing ever calling
      // _checkPairingStatus() again until some unrelated external trigger
      // (a connectivity-change event, a manual restart) happened to fire.
      // A fresh player could stay stuck on "connecting" indefinitely.
      // Falling back to the same periodic-poll recovery used for the
      // paired:false/playerStopped cases means this is never a dead end.
      _state = MqttState.connectionScreen;
      debugPrint("Error: $error");
      _pairingPollTimer ??=
          Timer.periodic(const Duration(seconds: 10), (_) async {
        await _checkPairingStatus();
      });
    }

    // Reset retry counter on success
    _pairingRetryCount = 0;
    notifyListeners();
  }

  void subsibeMessage(String topic) {
    if (topic.isEmpty || topic.trim().isEmpty) {
      print('MQTT_LOGS:: Cannot subscribe - topic is empty');
      return;
    }
    _mqttClientService.subscribe(topic);
  }

  void publishMessage(String topic, String message) {
    if (topic.isEmpty || topic.trim().isEmpty) {
      print('MQTT_LOGS:: Cannot publish - topic is empty');
      return;
    }
    _mqttClientService.publish(topic, message);
  }

  Future<void> restartApp() async {
    try {
      await _channel.invokeMethod('com.example/restartApp');
    } catch (e) {
      // W21: was `on PlatformException catch` only -- a channel with no
      // matching native-side handler at all (confirmed: no handler for
      // this method in the Windows runner) throws MissingPluginException,
      // a different type that specific clause never caught, so this could
      // propagate as an unhandled error out of an already-in-progress
      // catch block in _checkPairingStatus. Catching broadly here is what
      // actually makes this a safe no-op on a platform without a handler,
      // instead of a second, unrelated crash on top of the original error.
      print("Failed to restart app: $e");
    }
  }

  String? _msg;
  String? get msg => _msg;
  String? _key;
  String? get key => _key;
  double? tapX;
  double? tapY;

  // Retry counter for pairing status check
  int _pairingRetryCount = 0;
  static const int _maxPairingRetries = 3;

  // Polls _checkPairingStatus while stuck on the pairing/QR screen instead of
  // relying solely on the backend pushing an action_setup_player MQTT
  // message once the device is paired in the CMS. That push is a single,
  // unacknowledged, best-effort message -- if it's ever missed (subscribe
  // timing, broker hiccup, or the pairing action landing on a different
  // environment's backend than this build talks to), the device sat on the
  // pairing screen forever with no way to recover except an app restart,
  // which looked identical to "player not connecting" from the CMS side.
  Timer? _pairingPollTimer;

  void setTapPosition(double x, double y) {
    tapX = x;
    tapY = y;
    notifyListeners();
    // W22: the region hit-test was entirely commented out -- a configured
    // hotspot could never match a tap at all, regardless of coordinates.
    _matchAndFireInteractivity(x: x, y: y);
  }

  void getKey(String keydata) {
    _key = keydata;
    notifyListeners();
    // W22: matching was logged ("I am in interactivity by key") but never
    // actually dispatched the configured trigger(s).
    _matchAndFireInteractivity(key: keydata);
  }

  double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  // W22: content shown on top of the current campaign in response to a
  // matched hotspot tap or key press, for the firing Trigger's own
  // configured duration. Only ever the FIRST Content entry of the FIRST matching
  // trigger -- a Trigger can carry multiple Content items and/or nested
  // Zone/MediaItem compositions (Content.zones), but resolving those fully
  // would mean re-implementing this app's whole zone/media rendering
  // pipeline a second time against a completely separate, much thinner
  // model (intractivity_model.dart's own MediaItem/Settings, hidden on
  // import specifically because they don't match compaign_model.dart's
  // richer ones). A single flat image/video Content -- by far the common
  // case for a hotspot popup/promo -- is what this actually supports.
  //
  // Also unsupported, confirmed rather than assumed: Trigger.namedRegion
  // (the CMS's way of saying "show this inside a specific zone", not
  // full-screen) can't be resolved at all -- CampaignZone (compaign_model.
  // dart) has no name field anywhere, so there is no data in this app that
  // maps a name back to on-screen zone bounds. Every trigger this fires
  // shows full-screen, regardless of namedRegion.
  Content? _activeInteractivityContent;
  Content? get activeInteractivityContent => _activeInteractivityContent;
  Timer? _interactivityOverlayTimer;

  void _matchAndFireInteractivity({
    double? x,
    double? y,
    String? key,
  }) {
    final list = _interactivityModel?.data.interactivity;
    if (list == null || list.isEmpty) return;

    for (final interactivity in list) {
      // pause is the one reliable, fully-modeled on/off gate available here.
      // startTime/endTime/startDate/endDate are untyped (dynamic) and
      // InteractivityDays only ever parses "monday" (a pre-existing gap in
      // this model, not something introduced or fixed here) -- not safe to
      // evaluate blindly, so alwaysPlay/day/time scheduling for
      // interactivity is intentionally NOT enforced here beyond `pause`.
      if (interactivity.pause) continue;

      bool matched;
      if (key != null) {
        matched = keyMatches(interactivity.keyPress, key);
      } else if (x != null && y != null) {
        if (interactivity.anyRegion == true) {
          matched = true;
        } else {
          final rx = _asDouble(interactivity.regionX);
          final ry = _asDouble(interactivity.regionY);
          final rw = _asDouble(interactivity.regionWidth);
          final rh = _asDouble(interactivity.regionHeight);
          matched = rx != null &&
              ry != null &&
              rw != null &&
              rh != null &&
              isPointInRegion(
                  x: x,
                  y: y,
                  regionX: rx,
                  regionY: ry,
                  regionWidth: rw,
                  regionHeight: rh);
        }
      } else {
        matched = false;
      }
      if (!matched) continue;

      print('[Interactivity] Matched "${interactivity.name}" '
          '(${interactivity.triggers.length} trigger(s))');
      for (final trigger in interactivity.triggers) {
        _fireInteractivityTrigger(trigger);
      }
      return; // first match wins -- matches getKey's prior single-match intent
    }
  }

  void _fireInteractivityTrigger(Trigger trigger) {
    if (trigger.content.isEmpty) {
      print('[Interactivity] Trigger has no content -- nothing to show');
      return;
    }
    final content = trigger.content.first;
    final mediaType = content.mediaType.toLowerCase();
    if (mediaType.startsWith('video')) {
      // Not implemented -- see the class doc above _activeInteractivityContent.
      print('[Interactivity] Trigger content is video ($mediaType) -- '
          'video interactivity overlays are not supported, skipping');
      return;
    }
    _interactivityOverlayTimer?.cancel();
    _activeInteractivityContent = content;
    notifyListeners();
    final durationSeconds = trigger.duration > 0 ? trigger.duration : 10;
    _interactivityOverlayTimer =
        Timer(Duration(seconds: durationSeconds), () {
      _activeInteractivityContent = null;
      notifyListeners();
    });
  }

  // Keys that mean "this payload carries Player Configuration settings",
  // whether they arrive properly wrapped as {"action":"action_setup_player",
  // "settings":{...}} or -- confirmed from a real captured payload on the
  // player's own device-info topic -- as a flat, un-wrapped player record
  // with no "action" field at all (volume/brightness/reboot/screen_rotation
  // sitting as top-level siblings of the device-info fields). The second
  // shape used to hit the "no action field -- ignoring" early return below
  // and get silently dropped, which is why volume/brightness/rotation
  // updates from the CMS often never reached the player at all.
  static const _settingsKeys = [
    'mute_audio',
    'brightness',
    'volume',
    'screen_rotation',
    'touch_feedback',
    'hide_no_campaign_messages',
  ];

  // The backend echoes the full player record (including brightness/volume/
  // screen_rotation) back on essentially every heartbeat cycle, not just
  // when a setting actually changes -- confirmed from the debug log,
  // showing setWindowsVolume() firing 5 times within 5 seconds and
  // brightness's stored value jumping around between consecutive echoes a
  // few seconds apart. Unconditionally re-applying on every echo meant
  // brightness (and everything else) kept getting silently forced back to
  // whatever the backend currently had stored, on its own cadence,
  // completely independent of and unrelated to any actual volume change --
  // which is what looked like "changing volume changes brightness". Only
  // actually call the OS-level setter when the value differs from the last
  // one we applied.
  bool? _lastAppliedMute;
  int? _lastAppliedBrightness;
  int? _lastAppliedVolume;

  Future<void> _applySettingsMap(Map<String, dynamic>? settings) async {
    if (settings == null) return;
    _debugLog('applySettingsMap: ${jsonEncode(settings)}');

    // The Player Configuration form in the CMS submits mute_audio,
    // brightness, and volume together in a single settings payload -- these
    // used to be one big if/else-if chain, so whichever setting was checked
    // first (mute_audio, then brightness) "won" and silently swallowed the
    // rest. That's why brightness worked but volume never applied:
    // brightness's branch matched first and volume's branch never even ran.
    // Independent ifs so every setting present in the payload actually gets
    // applied.
    if (settings["mute_audio"] == true && _lastAppliedMute != true) {
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Mute Audio",
        "name": "Player ${deviceInfo?["hardware_details"]?["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };
      _mqttClientService.publish(topic, jsonEncode(sendLog));
      if (Platform.isMacOS) {
        deviceSettings.muteVolumeForMac();
        _lastAppliedMute = true;
      } else if (Platform.isAndroid) {
        deviceSettings.muteVolumeForAndroid();
        _lastAppliedMute = true;
      } else if (Platform.isWindows) {
        // W16: only record this as applied once the native call actually
        // reports success (awaited -- was previously fired without
        // awaiting at all) -- a failed mute used to still be marked
        // applied, so a retried/re-echoed identical settings payload would
        // be silently skipped by the != _lastAppliedMute guard above and
        // never actually retried.
        if (await deviceSettings.muteVolumeForWindows()) {
          _lastAppliedMute = true;
        }
      } else if (Platform.isLinux) {
        deviceSettings.muteVolumeForLinux();
        _lastAppliedMute = true;
      }
    }
    if (settings["mute_audio"] == false && _lastAppliedMute != false) {
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Unmute Audio",
        "name": "Player $globleTopic}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };
      _mqttClientService.publish(topic, jsonEncode(sendLog));
      if (Platform.isMacOS) {
        deviceSettings.unmuteVolumeForMac();
        _lastAppliedMute = false;
      } else if (Platform.isAndroid) {
        deviceSettings.unmuteVolumeForAndroid();
        _lastAppliedMute = false;
      } else if (Platform.isWindows) {
        if (await deviceSettings.unmuteVolumeForWindows()) {
          _lastAppliedMute = false;
        }
      } else if (Platform.isLinux) {
        deviceSettings.unmuteVolumeForLinux();
        _lastAppliedMute = false;
      }
    }
    final brightnessValue = settings["brightness"] != null
        ? _asNum(settings["brightness"]['value'])?.round()
        : null;
    if (brightnessValue != null && brightnessValue != _lastAppliedBrightness) {
      _lastAppliedBrightness = brightnessValue;
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "brightness",
        "name": "Player ${deviceInfo?["hardware_details"]?["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };
      _mqttClientService.publish(topic, jsonEncode(sendLog));
      if (Platform.isMacOS) {
        print("No brightness For Mac");
      } else if (Platform.isAndroid) {
        deviceSettings.setAppBrightnessForAndroid(brightnessValue.toDouble());
      } else if (Platform.isWindows) {
        deviceSettings.adjustBrightnessForWindows(brightnessValue);
      } else if (Platform.isLinux) {
        deviceSettings.changeBrightnessForLinux(brightnessValue.toString());
      }
    }
    final volumeValue =
        settings["volume"] != null ? _asNum(settings["volume"])?.round() : null;
    if (volumeValue != null && volumeValue != _lastAppliedVolume) {
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Volume",
        "name": "Player ${deviceInfo?["hardware_details"]?["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };
      _mqttClientService.publish(topic, jsonEncode(sendLog));
      if (Platform.isMacOS) {
        deviceSettings.setVolumeForMac(volumeValue);
        _lastAppliedVolume = volumeValue;
      } else if (Platform.isAndroid) {
        deviceSettings.setVolumeForAndroid(volumeValue);
        _lastAppliedVolume = volumeValue;
      } else if (Platform.isWindows) {
        // W16: same "record success only after checking the result" fix as
        // mute above.
        if (await deviceSettings.changeVolumeForWindows(volumeValue)) {
          _lastAppliedVolume = volumeValue;
        }
      } else if (Platform.isLinux) {
        deviceSettings.changeVolumeForLinux(volumeValue.toString());
        _lastAppliedVolume = volumeValue;
      }
    }
    // Screen Rotation / Show touch feedback / Hide helpful messages --
    // field names (screen_rotation, touch_feedback,
    // hide_no_campaign_messages) confirmed against the working Android
    // player's Setting model. These are pure Flutter widget-tree concerns
    // (a RotatedBox around the whole app, a tap-feedback overlay, a
    // no-campaign-screen gate), so they apply the same way on every
    // platform rather than needing a per-platform native call like
    // volume/brightness do.
    if (settings["screen_rotation"] != null) {
      final raw = settings["screen_rotation"].toString();
      final normalized = raw.toLowerCase() == "landscape" ? "0" : raw;
      final degrees = int.tryParse(normalized);
      if (degrees != null) {
        screenRotationDegrees.value = ((degrees % 360) + 360) % 360;
        _debugLog('screen_rotation applied: $degrees degrees');
      }
    }
    if (settings["touch_feedback"] != null) {
      touchFeedbackEnabled.value = settings["touch_feedback"] == true;
    }
    if (settings["hide_no_campaign_messages"] != null) {
      hideNoCampaignMessages.value = settings["hide_no_campaign_messages"] == true;
    }
  }

  void _handleIncomingMessage(String message) async {
    print('Received message in ViewModel: $message');

    print('Received message in store state: $storeState');
    print('i am in recive msgss:');
// await restartApp();
    Map<String, dynamic> jsonObj;
    try {
      jsonObj = jsonDecode(message) as Map<String, dynamic>;
    } catch (e) {
      _debugLog('_handleIncomingMessage: FAILED to decode JSON -- $e');
      return;
    }

    print('Saving JSON Object: $jsonObj');

    // Check if message has an action field
    if (jsonObj["action"] == null) {
      // A real captured payload on this player's own device-info topic
      // showed the backend echoing back the full player record with
      // volume/brightness/screen_rotation/mute_audio as flat top-level
      // fields and no "action" wrapper at all -- apply those instead of
      // dropping the message just because "action" is missing.
      if (_settingsKeys.any((k) => jsonObj[k] != null)) {
        await _applySettingsMap(jsonObj);
        return;
      }
      // Message doesn't have an action field - likely device info or other data
      // Just log it and return, don't process it as a command
      print('MQTT_LOGS:: Received message without action field - ignoring');
      return;
    }

    // Remote View + its interactive controls, matching the working Android
    // player's action names (case-insensitive there; normalized to
    // lowercase here) and its start/stop-on-demand handshake instead of a
    // fixed timer -- the backend only wants frames while its Remote View
    // panel for this player is actually open.
    final normalizedAction = (jsonObj["action"] ?? "").toString().toLowerCase();
    switch (normalizedAction) {
      case "start_remote_view":
        _startRemoteView();
        return;
      case "stop_remote_view":
        _stopRemoteView();
        return;
      case "press_home":
        if (Platform.isWindows) deviceSettings.showDesktopForWindows();
        return;
      case "press_back":
        if (Platform.isWindows) deviceSettings.restoreWindowsForWindows();
        return;
      case "send_text":
        {
          // W22: previously only wrote the clipboard -- nothing ever
          // actually typed/pasted it anywhere, so remote text entry never
          // reached a real input regardless of what had focus.
          final text = (jsonObj["message"] ?? "").toString();
          if (text.isNotEmpty) {
            await Clipboard.setData(ClipboardData(text: text));
            if (Platform.isWindows) {
              await deviceSettings.simulatePasteForWindows();
            }
          }
        }
        return;
      case "click":
        {
          if (Platform.isWindows) {
            final x = (jsonObj["x"] as num?)?.round();
            final y = (jsonObj["y"] as num?)?.round();
            if (x != null && y != null) {
              deviceSettings.simulateClickForWindows(x, y);
            }
          }
        }
        return;
    }

    if (jsonObj["action"] == "publish_playlist" ||
        jsonObj["action"] == "publish_campaign") {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      bool isSaved = await prefs.setString('jsonObj', jsonEncode(jsonObj));
      // Keep the in-memory restore payload in sync with what was just published.
      // Previously only SharedPreferences was updated, so a later connectivity
      // change (which restores playback from storedJsonObj) could revert to the
      // PREVIOUS campaign/playlist.
      storedJsonObj = jsonObj;

      if (isSaved) {
        print('Data successfully saved to SharedPreferences');
      } else {
        print('Failed to save data to SharedPreferences');
      }
    }
    print(jsonObj["action"]);
    if (jsonObj["action"] == "action_reboot") {
      print("action rebooot");
      Map<String, dynamic> sendLog = {
        "action": "Action Reboot",
        // deviceInfo is only populated by the iOS-oriented getDeviceInfo path;
        // Windows fills a different map, so deviceInfo can be null here. The
        // force-unwrap threw before the reboot command was ever issued -- make
        // the log line null-safe so the reboot below actually runs.
        "name": "Player ${deviceInfo?["hardware_details"]?["model"] ?? ""}",
        "type": "info",
        "dateTime": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      var data = {"success": true};
      publishMessage(globleTopic, jsonEncode(data));

      if (Platform.isMacOS) {
        deviceSettings.rebootDeviceForMacOS();
      } else if (Platform.isAndroid) {
        print("i am here for andorind");
        deviceSettings.rebootDeviceForAndroid();
      } else if (Platform.isWindows) {
        deviceSettings.rebootDeviceForWindows();
      } else if (Platform.isLinux) {
        deviceSettings.rebootDeviceForLinux();
      }
    } else if (jsonObj["action"] == "action_setup_player") {
      Map<String, dynamic> sendLog = {
        "action": "Action Setup Player",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "dateTime": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      if (storeState != null) {
        if (storeState == false) {
          await _checkPairingStatus();
        }
      }
      await _applySettingsMap(jsonObj["settings"] as Map<String, dynamic>?);
      var data = {"success": true};
      publishMessage(globleTopic, jsonEncode(data));
    } else if (jsonObj["action"] == "action click") {
      print(" i am in action  click");
    } else if (jsonObj["action"] == "publish_playlist") {
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Publish Playlist",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
// Deserialize the JSON into the model
      // await _checkPairingStatus();
      _playListModel = playListModelFromJson(jsonEncode(jsonObj));
      // W14: a fresh playlist can be shorter than the previous one -- reset
      // rather than leaving _currentIndex pointing past the end of the new
      // list, which would throw a RangeError on the very next
      // currentDuration/_durationForPlaylistAt access.
      _currentIndex = 0;
      _timer?.cancel();
      final hasPlaylistMedia = _playListModel!.data.playlist.any(
        (playlist) => playlist.media?.isNotEmpty ?? false,
      );
      if (!hasPlaylistMedia) {
        _state = MqttState.noContent;
        notifyListeners();
        return;
      }
      // Ensure any listening UI updates immediately
      notifyListeners();
      // if (_playListModel!.data.playlist.isEmpty) {
      //   debugPrint("remove playlist and update screen");
      //   Map<String, dynamic> sendLog = {
      //     "action": "player_logs",
      //     "log": "Remove Campaign",
      //     "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      //     "type": "info",
      //     "date_time": DateTime.now().toIso8601String(),
      //   };

      //   _mqttClientService.publish(topic, jsonEncode(sendLog));
      //   SharedPreferences prefs = await SharedPreferences.getInstance();
      //   prefs.clear();
      //   await _checkPairingStatus();
      // }
      print("model data ${_playListModel!.data.playlist}");

      // W07 follow-up: _startDownloadingForPlaylist() already iterates every
      // playlist/media item itself -- calling it once per media item queued
      // one full redundant download pass per item (an N-item playlist
      // launched N complete passes, with only the last generation allowed to
      // commit final state). hasPlaylistMedia was already computed above.
      _startDownloadingForPlaylist();
    } else if (jsonObj["action"] == "publish_campaign") {
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Publish Campaign",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      _msg = jsonObj["action"];
      final incomingCampaignModel = normalizeCampaignResponse(
        campaignModelFromJson(jsonEncode(jsonObj)),
        jsonObj,
      );
      final campaigns = incomingCampaignModel.data?.playerCampaigns;
      final count = campaigns?.length ?? 0;
      _debugLog(
          'publish_campaign received: $count campaign(s) currentIndex=$_currentIndexOfCapmaign '
          '${campaigns?.map((c) => "[id=${c.campaignId} name=${c.campaignName} composition=${c.isCompositionLayout}]").join(" ")}');
      if (count == 0) {
        _campaignModel = incomingCampaignModel;
        _timerOfCampaign?.cancel();
        _timerOfCampaign = null;
        _currentIndexOfCapmaign = 0;
        _state = MqttState.noContent;
        _debugLog(
            'publish_campaign contains no campaigns; showing no-content screen');
        notifyListeners();
        return;
      }
      _campaignModel = incomingCampaignModel;
      for (var i = 0; i < count; i++) {
        final c = campaigns![i];
        print(
            '[CampaignList] $i: ${c.campaignName} '
            'zones=${c.zones?.length ?? 0} '
            'composition=${c.isCompositionLayout} '
            'alwaysPlay=${c.campaignSchedule?.alwaysPlay}');
      }
      // #region agent log
      _mqttAgentDebugLog(
        'mqtt_view_model.dart:publish_campaign',
        'rotation campaign list',
        {
          'count': count,
          'campaigns': campaigns
                  ?.map(
                    (c) => {
                      'name': c.campaignName,
                      'zones': c.zones?.length ?? 0,
                      'composition': c.isCompositionLayout,
                      'alwaysPlay': c.campaignSchedule?.alwaysPlay,
                    },
                  )
                  .toList() ??
              [],
        },
        'H',
      );
      // #endregion
      // Keep campaign index in bounds when campaign list changes (e.g. single campaign)
      if (count > 0) {
        _selectCompositionCampaignIndexIfPresent();
        if (_currentIndexOfCapmaign >= count) {
          _currentIndexOfCapmaign = 0;
        }
      }
      // Deliberately NOT calling notifyListeners() here (before downloads
      // for any newly-added media even start) -- CampaignView listens
      // reactively via Provider.of<MqttViewModel>(context), so this would
      // rebuild it with _campaignModel already pointing at zones/stickers
      // whose files haven't been fetched yet. On a fresh app start that
      // race can't happen: _startDownloadingForCampaign() gates the whole
      // campaign behind MqttState.downloading until every file is on disk,
      // and only then flips to campaignScreen. But for a LIVE update on an
      // already-running player (e.g. adding stickers to a campaign that's
      // already showing), this used to notify immediately and only call
      // _startDownloadingForCampaign() several lines later, so newly-added
      // zones rendered right away against not-yet-downloaded files --
      // confirmed via signagex_debug.log as the cause of "downloaded 10
      // stickers but only 5 displayed, fixed by restarting the app" (a
      // fresh start doesn't hit this race; a live update did). Every branch
      // inside _startDownloadingForCampaign() (below) already calls
      // notifyListeners() itself once state is actually ready to show, so
      // this one is redundant, not just early.
      //
      // (This call used to matter for a different reason -- avoiding a
      // Phoenix.rebirth() full-app restart on every publish_campaign
      // message, which used to tear down and reconnect the MQTT client on
      // every CMS edit. That's still fixed; it just doesn't require an
      // immediate notifyListeners() here specifically.)
      // Safely check media URL with proper null/empty checks
      String? mediaUrl = 'N/A';
      try {
        final campaigns = _campaignModel?.data?.playerCampaigns;
        if (campaigns != null && campaigns.isNotEmpty) {
          final zones = campaigns[0].zones;
          if (zones != null && zones.isNotEmpty) {
            final mediaItems = zones[0].mediaItems;
            if (mediaItems != null && mediaItems.isNotEmpty) {
              mediaUrl = mediaItems[0].mediaUrl ?? 'N/A';
            }
          }
        }
      } catch (e) {
        debugPrint('MQTT_LOGS:: Error checking media URL: $e');
        mediaUrl = 'N/A';
      }
      print("checking media on model $mediaUrl");
      // if (_campaignModel!.data.playerCampaigns.isEmpty) {
      //   debugPrint("remove playlist and update screen");
      //   Map<String, dynamic> sendLog = {
      //     "action": "player_logs",
      //     "log": "Remove Campaign",
      //     "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
      //     "type": "info",
      //     "date_time": DateTime.now().toIso8601String(),
      //   };

      //   _mqttClientService.publish(topic, jsonEncode(sendLog));
      //   SharedPreferences prefs = await SharedPreferences.getInstance();
      //   prefs.clear();
      //   await _checkPairingStatus();
      // }

      print("i am in ccccccc");

      // await _checkPairingStatus();
      if (count > 0) {
        _startDownloadingForCampaign();
      }
    } else if (jsonObj["action"] == "publish_interactivity") {
      _interactivityModel = interactivityModelFromJson(jsonEncode(jsonObj));
      print("i am in intractvity");
    } else if (jsonObj["action"] == "remove_playlist") {
      debugPrint("remove playlist and update screen");
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Remove Playlist",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      // W06: this used to only clear prefs and re-check pairing --
      // _playListModel, storedJsonObj, and the rotation timer were left
      // intact, so a paired response deliberately preserving an active
      // playlist screen kept the removed playlist rendering, and it could
      // even be restored from the in-memory payload on the next reconnect.
      // Mirrors the targeted in-memory cancellation remove_campaign
      // already does below.
      _timer?.cancel();
      _timer = null;
      _currentIndex = 0;
      _playListModel = null;
      storedJsonObj = {};
      _state = MqttState.noContent;
      notifyListeners();

      SharedPreferences prefs = await SharedPreferences.getInstance();
      // Only the persisted content payload -- prefs.clear() wiped every
      // other key too (app_environment, updater retry budget, pairing
      // cache), none of which "remove this playlist" should touch.
      await prefs.remove('jsonObj');

      await _checkPairingStatus();
    } else if (jsonObj["action"] == "action_delete") {
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Action Delete",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      debugPrint("remove playlist and update screen");
      SharedPreferences prefs = await SharedPreferences.getInstance();
      prefs.clear();
      await _checkPairingStatus();
      await getStoredState();
    } else if (jsonObj["action"] == "remove_campaign") {
      debugPrint("remove playlist and update screen");
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Remove Campaign",
        "name": "Player ${deviceInfo?["hardware_details"]?["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      // Actually stop what's playing. Previously this only cleared prefs and
      // re-checked pairing, but the in-memory campaign/playlist kept rendering
      // (a paired poll response deliberately preserves active content), so
      // remove_campaign alone could leave content on screen. Mirror the
      // empty-publish no-content path, and clear the restore payload so a later
      // reconnect can't bring the removed content back.
      _timerOfCampaign?.cancel();
      _timerOfCampaign = null;
      // Also cancel the playlist rotation timer. Its callback _updateIndex()
      // force-unwraps _playListModel, so leaving it running after we null the
      // model below would crash on the very next tick.
      _timer?.cancel();
      _timer = null;
      _currentIndexOfCapmaign = 0;
      _campaignModel = null;
      _playListModel = null;
      storedJsonObj = {};
      _state = MqttState.noContent;
      notifyListeners();

      SharedPreferences prefs = await SharedPreferences.getInstance();
      // W06: as with remove_playlist above -- only the persisted content
      // payload, not every other key prefs.clear() used to wipe.
      await prefs.remove('jsonObj');
      await _checkPairingStatus();
    }
    notifyListeners();
  }

  // W07: bumped by every fresh _startDownloadingForCampaign/
  // _startDownloadingForPlaylist call, so an overlapping publication
  // (campaign A still downloading when campaign B is published) can tell
  // its own download pass is stale once a newer one has started, and
  // discard its completion instead of overwriting B's state with A's
  // data (or vice versa, whichever finishes "second" by wall-clock time
  // rather than by publication order).
  int _contentGeneration = 0;

  int _currentIndexOfCapmaign = 0;

  // isPaused was parsed off every campaign but never actually checked
  // anywhere the player decides what to show -- a Paused campaign rotated
  // into view and played exactly like any other, which is what QA reported
  // as "Pause not working" (Unpublish was already handled separately by the
  // count==0 branch above).
  bool _campaignIsPlayable(Campaign c) => c.isPaused != true;

  /// Index of the next playable (non-paused) campaign at or after [start],
  /// wrapping around at most once. Null if every campaign is paused.
  int? _nextPlayableCampaignIndex(List<Campaign> campaigns, int start) {
    final count = campaigns.length;
    if (count == 0) return null;
    for (var i = 0; i < count; i++) {
      final idx = (start + i) % count;
      if (_campaignIsPlayable(campaigns[idx])) return idx;
    }
    return null;
  }

  void _selectCompositionCampaignIndexIfPresent() {
    final campaigns = _campaignModel?.data?.playerCampaigns;
    if (campaigns == null || campaigns.isEmpty) return;

    if (_currentIndexOfCapmaign >= campaigns.length) {
      _currentIndexOfCapmaign = 0;
    }

    if (!_campaignIsPlayable(campaigns[_currentIndexOfCapmaign])) {
      final playableIdx =
          _nextPlayableCampaignIndex(campaigns, _currentIndexOfCapmaign);
      if (playableIdx != null) {
        _currentIndexOfCapmaign = playableIdx;
      }
      // If every campaign is paused, leave the index as-is -- callers check
      // playability themselves before committing to campaignScreen.
    }

    final current = campaigns[_currentIndexOfCapmaign];
    print(
        '[Campaign] Active campaign index $_currentIndexOfCapmaign '
        '(${current.campaignName}, composition=${current.isCompositionLayout}, '
        '${current.zones?.length ?? 0} zones)');

    // #region agent log
    _mqttAgentDebugLog(
      'mqtt_view_model.dart:_selectCompositionCampaignIndexIfPresent',
      'campaign index resolved',
      {
        'index': _currentIndexOfCapmaign,
        'totalCampaigns': campaigns.length,
        'compositionCount':
            campaigns.where((c) => c.isCompositionLayout).length,
        'regularCount':
            campaigns.where((c) => !c.isCompositionLayout).length,
        'campaignName': current.campaignName,
        'isComposition': current.isCompositionLayout,
      },
      'G',
    );
    // #endregion
  }
  Timer? _timerOfCampaign;

  Timer? _heartbeatTimer;
  Timer? _screenshotTimer;
  Timer? _resourceUsageTimer;
  final DateTime _appStartTime = DateTime.now();

  // Device info/resource stats used to only ever be sent once, right after
  // pairing -- after that the backend had no way to tell the player apart
  // from one that had gone offline, so it kept reporting Sync Issue /
  // Offline / empty Resource Usage graphs even while content was actively
  // playing. Re-send both on a recurring basis instead.
  //
  // Remote View: Android only streams screenshots on an explicit
  // start_remote_view/stop_remote_view command from the backend, but that's
  // unconfirmed for this platform -- there's no evidence the dashboard
  // actually sends that command for a "windows" player. Rather than bet
  // Remote View entirely on an unverified inbound command, always send a
  // baseline low-rate screenshot (so Remote View has *something* even if
  // that command never arrives), and speed up to Android's ~2s cadence if
  // start_remote_view does show up.
  void _startPeriodicReporting() {
    _debugLog('_startPeriodicReporting: heartbeat/resource-usage/screenshot timers starting for topic $globleTopic');
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (globleTopic.isEmpty) return;
      // {'status': 'online'} used to be published to <topic>/player_status
      // exactly once, inside _checkPairingStatus() -- which, after the
      // storeState==true persistence fix, now only ever runs on the very
      // first successful pairing check for the whole app session. If the
      // backend treats that topic as a presence/TTL signal (a common MQTT
      // pattern, e.g. paired with a last-will "offline" default), it would
      // go stale and flip to offline after some idle window even while the
      // heartbeat below and actual playback keep going fine -- which is
      // what QA reported as "status shows offline even though it's
      // playing". Republish it on every heartbeat tick so presence keeps
      // refreshing for as long as the player is actually alive.
      _mqttClientService.publish(
        '$globleTopic/player_status',
        jsonEncode({'status': 'online'}),
      );
      if (Platform.isWindows) {
        await _refreshWindowsHeartbeatStats();
      } else {
        devicesinfo["last_seen"] = DateTime.now().toIso8601String();
      }
      await fetchNetworkInfo();
      _debugLog('heartbeat: publishing deviceInfoMap: ${jsonEncode(deviceInfoMap)}');
      publishMessage(globleTopic, jsonEncode(deviceInfoMap));
    });

    _resourceUsageTimer?.cancel();
    _resourceUsageTimer =
        Timer.periodic(const Duration(minutes: 5), (_) => _sendResourceUsage());
    _sendResourceUsage();

    _startBaselineScreenshots();
  }

  void _stopPeriodicReporting() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _resourceUsageTimer?.cancel();
    _resourceUsageTimer = null;
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
    _remoteViewActive = false;
  }

  bool _remoteViewActive = false;

  void _startBaselineScreenshots() {
    _screenshotTimer?.cancel();
    _screenshotTimer =
        Timer.periodic(const Duration(seconds: 15), (_) async {
      if (globleTopic.isEmpty) return;
      await captureAndSendScreenshot(globleTopic);
    });
    if (globleTopic.isNotEmpty) captureAndSendScreenshot(globleTopic);
  }

  void _startRemoteView() {
    if (globleTopic.isEmpty) return;
    _remoteViewActive = true;
    _screenshotTimer?.cancel();
    // Matches the working Android player's ~1-2s capture rate while a
    // Remote View session is actually open on the dashboard.
    _screenshotTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await captureAndSendScreenshot(globleTopic);
    });
    captureAndSendScreenshot(globleTopic);
  }

  void _stopRemoteView() {
    _remoteViewActive = false;
    // Drop back to the baseline rate rather than stopping entirely --
    // still paired and playing, so Remote View should still show
    // something if opened again without a fresh start_remote_view.
    _startBaselineScreenshots();
  }

  int get currentIndexOfCapmaign => _currentIndexOfCapmaign;

  int get currentDurationOfCampaign =>
      _durationForCampaignAt(_currentIndexOfCapmaign);

  // W04: split out of the currentDurationOfCampaign getter so the bounded
  // eligibility scan in _updateIndexForCampain can evaluate a *candidate*
  // index's duration without first mutating _currentIndexOfCapmaign to
  // point at it.
  int _durationForCampaignAt(int index) {
    final currentCampaign = campaignModel?.data?.playerCampaigns?[index];
    if (currentCampaign == null) return 0;

    final campaignSchedule = currentCampaign.campaignSchedule;
    if (campaignSchedule == null) {
      print(
          'Index: $index, Duration: 15 seconds, '
          'Always Play: true (default, no schedule)');
      return 15;
    }

    int durationcampagin = 0;

    // W12 (the part that was never actually fixed): this rotation-side
    // eligibility check and CampaignView._buildScreen's render-side check
    // were two completely different systems answering the same question,
    // and they disagreed for any restriction-scheduled campaign.
    //
    // _buildScreen decides "can this campaign play" as:
    //     alwaysPlay ? yes : (restrictions.isNotEmpty ? checkRestrictions(...) : no)
    // while this function only ever looked at alwaysPlay or the LEGACY
    // `period` block (date/days/time), never at `restrictions` at all.
    //
    // Confirmed end-to-end on a real device: a campaign with
    // alwaysPlay=false, no period, and one time/is-after restriction that
    // had genuinely passed rendered correctly (state -> campaignScreen,
    // checkRestrictions -> true), and then ~200ms later CampaignView's own
    // initState post-frame callback ran startPlaylistTimerForCampaign(),
    // landed here, scored the campaign duration 0 because `restrictions`
    // was invisible to this code, and _updateIndexForCampain concluded
    // "no playable+eligible campaign" and set MqttState.noContent --
    // tearing down the very screen the render path had just approved, and
    // then re-confirming that same wrong answer every 30s forever. That is
    // the "published with a restriction, player says No Content" report.
    //
    // Restrictions are checked here in the same order _buildScreen uses,
    // and only when a non-empty restrictions list actually exists, so the
    // legacy period path below is untouched for payloads that still use it.
    final restrictions = campaignSchedule.restrictions;
    final hasRestrictions = restrictions != null && restrictions.isNotEmpty;

    // Check if the item is in the schedule or should always play
    if ((campaignSchedule.alwaysPlay ?? false) ||
        (hasRestrictions && checkRestrictions(restrictions)) ||
        (campaignSchedule.period != null &&
            campaignSchedule.period!.date != null &&
            campaignSchedule.period!.date!.start != null &&
            campaignSchedule.period!.date!.end != null &&
            _isPlaylistDateInRangeForCampagin(
                DateTime.parse(campaignSchedule.period!.date!.start!),
                DateTime.parse(campaignSchedule.period!.date!.end!)) &&
            _isCurrentDayAllowedForCampain(
              campaignSchedule.period!.days,
              DateTime.now(),
            ) &&
            campaignSchedule.period!.time != null &&
            campaignSchedule.period!.time!.from != null &&
            campaignSchedule.period!.time!.to != null &&
            _isTimeInRangeForCampaign(
              campaignSchedule.period!.time!.from!,
              campaignSchedule.period!.time!.to!,
            ))            ) {
      final durationValue = currentCampaign.campaignSettings?.duration;
      if (durationValue != null) {
        durationcampagin = int.tryParse(durationValue) ?? 0;
      }
      if (durationcampagin <= 0) {
        durationcampagin = 15;
      }
    }

    // Log the state
    print(
        "Index: $index, Duration: $durationcampagin seconds, Always Play: ${campaignSchedule.alwaysPlay}");
    _debugLog('_durationForCampaignAt($index) -> $durationcampagin '
        '(alwaysPlay=${campaignSchedule.alwaysPlay} '
        'restrictions=${restrictions?.length ?? 0} '
        'hasPeriod=${campaignSchedule.period != null})');

    // #region agent log
    _mqttAgentDebugLog(
      'mqtt_view_model.dart:currentDurationOfCampaign',
      'resolved campaign duration',
      {
        'campaignIndex': index,
        'durationSeconds': durationcampagin,
        'alwaysPlay': campaignSchedule.alwaysPlay,
        'rawDuration': currentCampaign.campaignSettings?.duration,
      },
      'F',
    );
    // #endregion

    return durationcampagin;
  }

  void startPlaylistTimerForCampaign() {
    _timerOfCampaign?.cancel();

    final duration = currentDurationOfCampaign;
    if (duration <= 0) {
      _updateIndexForCampain();
      print("Campaign not in schedule, skipping timer setup.");
    } else {
      _timerOfCampaign =
          Timer(Duration(seconds: duration), _updateIndexForCampain);
    }
  }

  void publishLogsForPlayList(String name) {
    Map<String, dynamic> sendLog = {
      "action": "Playlist",
      "name": "$name",
      "type": "info",
      "dateTime": DateTime.now().toIso8601String(),
    };

    _mqttClientService.publish(topic, jsonEncode(sendLog));
  }

  void publishLogsForCampaign(String name) {
    Map<String, dynamic> sendLog = {
      "action": "Campaign",
      "name": "$name",
      "type": "info",
      "dateTime": DateTime.now().toIso8601String(),
    };

    _mqttClientService.publish(topic, jsonEncode(sendLog));
  }

  void _updateIndexForCampain() {
    final campaigns = _campaignModel?.data?.playerCampaigns;
    final count = campaigns?.length ?? 0;

    // If all campaigns are unpublished/removed, stop the timer and move to noContent.
    if (count == 0) {
      debugPrint(
          'MQTT_LOGS:: _updateIndexForCampain skipped (no campaigns). Cancelling campaign timer.');
      _timerOfCampaign?.cancel();
      _timerOfCampaign = null;
      _currentIndexOfCapmaign = 0;
      _state = MqttState.noContent;
      notifyListeners();
      return;
    }

    final playableCampaigns = campaigns!;

    // W04: bounded scan (at most `count` candidates) for the next campaign
    // that is BOTH not paused AND currently schedule-eligible (a positive
    // duration) -- this used to only check "not paused" here, then rely on
    // startPlaylistTimerForCampaign() calling straight back into this
    // function whenever the chosen candidate turned out to be
    // schedule-ineligible (duration <= 0). That recursion had no bound: if
    // every campaign was currently outside its schedule window (or none
    // were ever eligible), it synchronously spun through the whole
    // rotation over and over -- reproduced at 1,000+ synchronous rotations
    // in the audit's standalone check, enough to starve the event loop or
    // overflow the stack. Folding both checks into one bounded loop means
    // this function always returns after at most `count` iterations,
    // never recurses into itself, and explicitly parks on a recheck timer
    // when nothing qualifies instead of spinning.
    int? eligibleIndex;
    int eligibleDuration = 0;
    for (var i = 1; i <= count; i++) {
      final idx = (_currentIndexOfCapmaign + i) % count;
      if (!_campaignIsPlayable(playableCampaigns[idx])) continue;
      final duration = _durationForCampaignAt(idx);
      if (duration > 0) {
        eligibleIndex = idx;
        eligibleDuration = duration;
        break;
      }
    }

    if (eligibleIndex == null) {
      // Nothing is both unpaused and inside its schedule window right
      // now. A restriction window can open on its own with no new content
      // ever being published, so recheck later instead of leaving this
      // permanently stuck -- but never by immediately recursing.
      debugPrint(
          'MQTT_LOGS:: _updateIndexForCampain: no playable+eligible campaign right now. Rechecking in 30s.');
      // This line silently tore down an actively-rendering campaign screen
      // and only ever announced it through debugPrint -- invisible in a
      // release build, which is why "state -> noContent" appeared in the
      // logs with no accompanying reason for it anywhere.
      _debugLog(
          '_updateIndexForCampain: no playable+eligible campaign among $count '
          '(durations all 0) -> noContent, recheck in 30s');
      _timerOfCampaign?.cancel();
      _timerOfCampaign =
          Timer(const Duration(seconds: 30), _updateIndexForCampain);
      _state = MqttState.noContent;
      notifyListeners();
      return;
    }
    _currentIndexOfCapmaign = eligibleIndex;

    final nextCampaign = playableCampaigns[_currentIndexOfCapmaign];
    print(
        '[Campaign] Rotating to index $_currentIndexOfCapmaign of $count '
        '(${nextCampaign.campaignName}, '
        'composition=${nextCampaign.isCompositionLayout})');

    // #region agent log
    _mqttAgentDebugLog(
      'mqtt_view_model.dart:_updateIndexForCampain',
      'campaign rotated',
      {
        'newIndex': _currentIndexOfCapmaign,
        'totalCampaigns': count,
        'campaignName': nextCampaign.campaignName,
        'isComposition': nextCampaign.isCompositionLayout,
      },
      'G',
    );
    // #endregion

    final currentCampaignName = (_currentIndexOfCapmaign < count)
        ? (playableCampaigns[_currentIndexOfCapmaign].campaignName ?? "")
        : "";

    Map<String, dynamic> sendLog = {
      "action": "player_logs",
      "log": "Current Campaign",
      "name": currentCampaignName,
      "type": "info",
      "date_time": DateTime.now().toIso8601String(),
      "is_composition": nextCampaign.isCompositionLayout,
    };

    _mqttClientService.publish(topic, jsonEncode(sendLog));

    // publishLogsForCampaign was written for exactly this ("Playing Loop"
    // representation) but was never actually called -- compositions were
    // rotating through _updateIndexForCampain like everything else, but
    // never reported here, so the dashboard timeline never saw them.
    publishLogsForCampaign(currentCampaignName);

    notifyListeners();
    // Sets the timer directly from the duration the bounded scan above
    // already confirmed is positive for this index, rather than calling
    // startPlaylistTimerForCampaign() again (which would just re-read the
    // same value via the getter) -- avoids recomputing it and keeps this
    // function's only path back into itself as a plain Timer callback,
    // never a synchronous call.
    _timerOfCampaign?.cancel();
    _timerOfCampaign =
        Timer(Duration(seconds: eligibleDuration), _updateIndexForCampain);
  }

  void resetTimerForCapmpain() {
    _timerOfCampaign?.cancel();
    notifyListeners();
  }

  bool _isPlaylistDateInRangeForCampagin(DateTime startDate, DateTime endDate) {
    DateTime now = DateTime.now();
    return now.isAfter(startDate) &&
        now.isBefore(endDate.add(const Duration(days: 1)));
  }

  bool _isCurrentDayAllowedForCampain(dynamic days, DateTime now) {
    switch (now.weekday) {
      case 1:
        return days.monday ?? false;
      case 2:
        return days.tuesday ?? false;
      case 3:
        return days.wednesday ?? false;
      case 4:
        return days.thursday ?? false;
      case 5:
        return days.friday ?? false;
      case 6:
        return days.saturday ?? false;
      case 7:
        return days.sunday ?? false;
      default:
        return false;
    }
  }

  bool _isTimeInRangeForCampaign(String timeFrom, String timeTo) {
    return isNowInTimeRange(timeFrom, timeTo);
  }

  void _updateMessage() {
    notifyListeners();
  }

  void reloadApp(BuildContext context) {
    Phoenix.rebirth(context); // App restart
  }

  int _currentIndex = 0;
  Timer? _timer;

  int get currentIndex => _currentIndex;

  int get currentDuration => _durationForPlaylistAt(_currentIndex);

  // W04: split out of the currentDuration getter (mirrors
  // _durationForCampaignAt above) so the bounded eligibility scan in
  // _updateIndex can evaluate a candidate index without first mutating
  // _currentIndex to point at it. Also fixes a real collision: the old
  // version used a literal `2` as both the "not eligible" sentinel
  // (checked via `if (currentDuration == 2)` in startPlaylistTimer) *and*
  // a value a genuinely-configured playlistDefault.duration could
  // legitimately parse to -- a real two-second playlist item was
  // therefore treated as "not in schedule" and skipped. `0` is the
  // sentinel now, and a configured non-positive duration is clamped to a
  // sane default instead of colliding with it.
  int _durationForPlaylistAt(int index) {
    final currentPlaylist = _playListModel!.data.playlist[index];
    final playlistSchedule = currentPlaylist.playlistSchedule;

    int duration = 0;

    // Check if the item is in the schedule or should always play
    if (playlistSchedule!.alwaysPlay ||
        _isPlaylistDateInRange(
              playlistSchedule.period!.date.start,
              playlistSchedule.period!.date.end,
            ) &&
            _isCurrentDayAllowed(
              playlistSchedule.period!.days,
              DateTime.now(),
            ) &&
            _isTimeInRange(
              playlistSchedule.period!.time.from,
              playlistSchedule.period!.time.to,
            )) {
      duration = int.tryParse(currentPlaylist.playlistDefault!.duration) ?? 0;
      if (duration <= 0) duration = 15;
    }

    // Log the state
    print(
        "Index: $index, Duration: $duration seconds, Always Play: ${playlistSchedule.alwaysPlay}");

    return duration;
  }

  void startPlaylistTimer() {
    _timer?.cancel();
    final duration = currentDuration;
    print("this is duration$duration");
    if (duration <= 0) {
      _updateIndex();
      print("Playlist item not in schedule, skipping timer setup.");
    } else {
      _timer = Timer(Duration(seconds: duration), _updateIndex);
    }
  }

  void _updateIndex() {
    final total = _playListModel?.data.playlist.length ?? 0;
    if (total == 0) {
      _timer?.cancel();
      notifyListeners();
      return;
    }

    // W04: bounded scan (at most `total` candidates) -- this used to
    // advance by exactly one and unconditionally call startPlaylistTimer()
    // again, which called straight back into this function whenever the
    // new index was ineligible. With no bound, that recursion could spin
    // synchronously through the whole playlist forever whenever nothing
    // was ever eligible -- reproduced at 1,000+ synchronous rotations in
    // the audit's standalone check. This version always returns after at
    // most `total` iterations and parks on a recheck timer instead of
    // spinning when nothing qualifies.
    int? eligibleIndex;
    int eligibleDuration = 0;
    for (var i = 1; i <= total; i++) {
      final idx = (_currentIndex + i) % total;
      final duration = _durationForPlaylistAt(idx);
      if (duration > 0) {
        eligibleIndex = idx;
        eligibleDuration = duration;
        break;
      }
    }

    if (eligibleIndex == null) {
      debugPrint(
          'MQTT_LOGS:: _updateIndex: no eligible playlist item right now. Rechecking in 30s.');
      _timer?.cancel();
      _timer = Timer(const Duration(seconds: 30), _updateIndex);
      notifyListeners();
      return;
    }

    _currentIndex = eligibleIndex;
    print(
        "current playlist ${_playListModel!.data.playlist[_currentIndex].name} ");

    Map<String, dynamic> sendLog = {
      "action": "player_logs",
      "log": "Current Playlist",
      "name": "${_playListModel!.data.playlist[_currentIndex].name}",
      "type": "info",
      "date_time": DateTime.now().toIso8601String(),
    };

    _mqttClientService.publish(topic, jsonEncode(sendLog));

    notifyListeners();
    _timer?.cancel();
    _timer = Timer(Duration(seconds: eligibleDuration), _updateIndex);
  }

  void resetTimer() {
    _timer?.cancel();
    notifyListeners();
  }

// Clean up timer
  @override
  void dispose() {
    _timerOfCampaign?.cancel();
    _timer?.cancel();
    _pairingPollTimer?.cancel();
    _interactivityOverlayTimer?.cancel();
    _networkRecoveryTimer?.cancel();
    _stopPeriodicReporting();
    // W03: releases the MQTT updates subscription too, not just this
    // view model's own timers.
    _mqttClientService.dispose();
    super.dispose();
  }

  bool _isPlaylistDateInRange(DateTime startDate, DateTime endDate) {
    DateTime now = DateTime.now();
    return now.isAfter(startDate) &&
        now.isBefore(endDate.add(const Duration(days: 1)));
  }

  bool _isCurrentDayAllowed(dynamic days, DateTime now) {
    switch (now.weekday) {
      case 1:
        return days.monday ?? false;
      case 2:
        return days.tuesday ?? false;
      case 3:
        return days.wednesday ?? false;
      case 4:
        return days.thursday ?? false;
      case 5:
        return days.friday ?? false;
      case 6:
        return days.saturday ?? false;
      case 7:
        return days.sunday ?? false;
      default:
        return false;
    }
  }

  bool _isTimeInRange(String timeFrom, String timeTo) {
    return isNowInTimeRange(timeFrom, timeTo);
  }

  /// Check if restrictions allow the campaign/media to play
  ///
  /// Every decision here previously only went through print() -- invisible
  /// in a release-mode Windows exe (no console), confirmed by a real device
  /// debug log from a session where a restriction had been configured: zero
  /// lines from this function anywhere in it. _debugLog goes to the actual
  /// persisted signagex_debug.log file instead, so the next report of
  /// "restrictions aren't working" has real evidence instead of another
  /// unlogged black box.
  bool checkRestrictions(List<Restriction>? restrictions) {
    const String reset = '\x1B[0m';
    const String red = '\x1B[31m';
    const String green = '\x1B[32m';
    const String yellow = '\x1B[33m';
    const String blue = '\x1B[34m';

    if (restrictions == null || restrictions.isEmpty) {
      print('$yellow⚠️  RESTRICTION: No restrictions provided → Allowed$reset');
      _debugLog('checkRestrictions: no restrictions provided -> true');
      return true; // No restrictions means allowed
    }

    DateTime now = DateTime.now();
    bool allRestrictionsPass = true;

    print(
        '$blue🔍 RESTRICTION: Checking ${restrictions.length} restriction(s)...$reset');

    for (var restriction in restrictions) {
      if (restriction.type == null ||
          restriction.operator == null ||
          restriction.values == null) {
        print(
            '$yellow⚠️  RESTRICTION: Skipping invalid restriction (missing type/operator/values)$reset');
        _debugLog('checkRestrictions: skipping invalid restriction '
            '(type=${restriction.type} operator=${restriction.operator} values=${restriction.values})');
        continue; // Skip invalid restrictions
      }

      bool restrictionPass = false;

      // Only apply restrictions for "date" or "time" types
      if (restriction.type == "date") {
        restrictionPass = _checkDateRestriction(restriction, now);
      } else if (restriction.type == "time") {
        restrictionPass = _checkTimeRestriction(restriction, now);
      } else {
        // If type is not "date" or "time", treat as always play
        restrictionPass = true;
        print(
            "$yellow⚠️  RESTRICTION: Type '${restriction.type}' is not date/time → Treating as always play$reset");
        _debugLog(
            "checkRestrictions: type '${restriction.type}' is not date/time -> treated as pass");
      }

      _debugLog('checkRestrictions: type=${restriction.type} '
          'operator=${restriction.operator} values=${restriction.values} '
          'now=$now -> ${restrictionPass ? "PASS" : "FAIL"}');

      // All restrictions must pass (AND logic)
      if (!restrictionPass) {
        allRestrictionsPass = false;
        print(
            '$red❌ RESTRICTION: Failed - type: ${restriction.type}, operator: ${restriction.operator}, values: ${restriction.values}$reset');
        break;
      } else {
        print(
            '$green✅ RESTRICTION: Passed - type: ${restriction.type}, operator: ${restriction.operator}, values: ${restriction.values}$reset');
      }
    }

    if (allRestrictionsPass) {
      print('$green✅ RESTRICTION: All restrictions PASSED$reset');
    } else {
      print('$red❌ RESTRICTION: At least one restriction FAILED$reset');
    }
    _debugLog('checkRestrictions: final result -> $allRestrictionsPass');

    return allRestrictionsPass;
  }

  /// Check date restriction based on operator
  bool _checkDateRestriction(Restriction restriction, DateTime now) {
    if (restriction.values == null || restriction.values!.isEmpty) {
      return false;
    }

    final operator = _normalizeRestrictionOperator(restriction.operator);
    final values = restriction.values!;

    try {
      switch (operator) {
        case "is-between":
          if (values.length >= 2) {
            final startDate = DateTime.parse(values[0]);
            final endDate = DateTime.parse(values[1]);
            final startDateOnly =
                DateTime(startDate.year, startDate.month, startDate.day);
            final endDateOnly =
                DateTime(endDate.year, endDate.month, endDate.day);
            final nowDateOnly = DateTime(now.year, now.month, now.day);

            final shouldPlay = (nowDateOnly.isAfter(startDateOnly) ||
                    nowDateOnly.isAtSameMomentAs(startDateOnly)) &&
                (nowDateOnly.isBefore(endDateOnly) ||
                    nowDateOnly.isAtSameMomentAs(endDateOnly));

            print(
                "DATE_CHECK:: is-between - start: ${startDateOnly.toString().split(' ')[0]}, end: ${endDateOnly.toString().split(' ')[0]}, current: ${nowDateOnly.toString().split(' ')[0]}, shouldPlay: $shouldPlay");
            return shouldPlay;
          }
          return false;

        case "on":
          if (values.isNotEmpty) {
            final targetDate = DateTime.parse(values[0]);
            final targetDateOnly =
                DateTime(targetDate.year, targetDate.month, targetDate.day);
            final nowDateOnly = DateTime(now.year, now.month, now.day);

            final shouldPlay = nowDateOnly.isAtSameMomentAs(targetDateOnly) ||
                nowDateOnly.isAfter(targetDateOnly);

            print(
                "DATE_CHECK:: on - target: ${targetDateOnly.toString().split(' ')[0]}, current: ${nowDateOnly.toString().split(' ')[0]}, shouldPlay: $shouldPlay");
            return shouldPlay;
          }
          return false;

        case "is-before":
          if (values.isNotEmpty) {
            final targetDate = DateTime.parse(values[0]);
            return now.isBefore(targetDate);
          }
          return false;

        case "is-after":
          if (values.isNotEmpty) {
            final targetDate = DateTime.parse(values[0]);
            final targetDateOnly =
                DateTime(targetDate.year, targetDate.month, targetDate.day);
            final nowDateOnly = DateTime(now.year, now.month, now.day);

            final shouldPlay = nowDateOnly.isAfter(targetDateOnly) ||
                nowDateOnly.isAtSameMomentAs(targetDateOnly);

            print(
                "DATE_CHECK:: is-after - target: ${targetDateOnly.toString().split(' ')[0]}, current: ${nowDateOnly.toString().split(' ')[0]}, shouldPlay: $shouldPlay");
            return shouldPlay;
          }
          return false;

        case "not-on":
          if (values.isNotEmpty) {
            final targetDate = DateTime.parse(values[0]);
            final targetDateOnly =
                DateTime(targetDate.year, targetDate.month, targetDate.day);
            final nowDateOnly = DateTime(now.year, now.month, now.day);
            return !(nowDateOnly.isAtSameMomentAs(targetDateOnly));
          }
          return false;

        default:
          print("Unknown date restriction operator: $operator");
          return false;
      }
    } catch (e) {
      print("Error parsing date restriction: $e");
      return false;
    }
  }

  /// Check time restriction based on operator
  bool _checkTimeRestriction(Restriction restriction, DateTime now) {
    const String reset = '\x1B[0m';
    const String red = '\x1B[31m';
    const String cyan = '\x1B[36m';

    if (restriction.values == null || restriction.values!.isEmpty) {
      print("${red}TIME_CHECK:: No values provided for time restriction$reset");
      return false;
    }

    final operator = _normalizeRestrictionOperator(restriction.operator);
    final values = restriction.values!;

    print(
        "${cyan}TIME_CHECK:: Checking time restriction - operator: $operator, values: $values, current time: ${now.hour}:${now.minute.toString().padLeft(2, '0')}$reset");

    try {
      switch (operator) {
        case "is-between":
          if (values.length >= 2) {
            final startTime = _parseTimeString(values[0]);
            final endTime = _parseTimeString(values[1]);
            final currentTime =
                DateTime(now.year, now.month, now.day, now.hour, now.minute);
            // W12: both start/end are anchored to *today's* date by
            // _parseTimeString, so an overnight window (e.g. 22:00-06:00)
            // used to always fail: end (06:00 today) is chronologically
            // before start (22:00 today), so "start <= now <= end" can
            // never be true no matter what "now" actually is (confirmed:
            // 22:00-06:00 at 23:00 returned false). When end is before
            // start, the valid range wraps past midnight -- it's "at/after
            // start" OR "at/before end", not AND.
            final result = endTime.isBefore(startTime)
                ? (!currentTime.isBefore(startTime) ||
                    !currentTime.isAfter(endTime))
                : (!currentTime.isBefore(startTime) &&
                    !currentTime.isAfter(endTime));
            print(
                "${cyan}TIME_CHECK:: is-between - start: ${startTime.hour}:${startTime.minute.toString().padLeft(2, '0')}, end: ${endTime.hour}:${endTime.minute.toString().padLeft(2, '0')}, current: ${currentTime.hour}:${currentTime.minute.toString().padLeft(2, '0')}, result: $result$reset");
            return result;
          }
          return false;

        case "on":
          if (values.isNotEmpty) {
            final targetTime = _parseTimeString(values[0]);
            final targetHour = targetTime.hour;
            final targetMinute = targetTime.minute;
            final currentHour = now.hour;
            final currentMinute = now.minute;

            final shouldPlay =
                currentHour == targetHour && currentMinute == targetMinute;

            print(
                "${cyan}TIME_CHECK:: on - target: ${targetHour.toString().padLeft(2, '0')}:${targetMinute.toString().padLeft(2, '0')}, current: ${currentHour.toString().padLeft(2, '0')}:${currentMinute.toString().padLeft(2, '0')}, result: $shouldPlay$reset");
            return shouldPlay;
          }
          return false;

        case "is-before":
          if (values.isNotEmpty) {
            final targetTime = _parseTimeString(values[0]);
            final currentTime =
                DateTime(now.year, now.month, now.day, now.hour, now.minute);
            final result = currentTime.isBefore(targetTime);
            print(
                "TIME_CHECK:: is-before - target: ${targetTime.hour}:${targetTime.minute.toString().padLeft(2, '0')}, current: ${currentTime.hour}:${currentTime.minute.toString().padLeft(2, '0')}, result: $result");
            return result;
          }
          return false;

        case "is-after":
          if (values.isNotEmpty) {
            final targetTime = _parseTimeString(values[0]);
            final currentTime =
                DateTime(now.year, now.month, now.day, now.hour, now.minute);
            final result = currentTime.isAfter(targetTime) ||
                currentTime.isAtSameMomentAs(targetTime);
            print(
                "${cyan}TIME_CHECK:: is-after - target: ${targetTime.hour}:${targetTime.minute.toString().padLeft(2, '0')}, current: ${currentTime.hour}:${currentTime.minute.toString().padLeft(2, '0')}, result: $result$reset");
            return result;
          }
          return false;

        case "not-on":
          if (values.isNotEmpty) {
            final targetTime = _parseTimeString(values[0]);
            final currentTime =
                DateTime(now.year, now.month, now.day, now.hour, now.minute);
            final result = !(currentTime.isAtSameMomentAs(targetTime));
            print(
                "TIME_CHECK:: not-on - target: ${targetTime.hour}:${targetTime.minute.toString().padLeft(2, '0')}, current: ${currentTime.hour}:${currentTime.minute.toString().padLeft(2, '0')}, result: $result");
            return result;
          }
          return false;

        default:
          print("TIME_CHECK:: Unknown time restriction operator: $operator");
          return false;
      }
    } catch (e) {
      print("TIME_CHECK:: Error parsing time restriction: $e");
      return false;
    }
  }

  /// Parse time string (HH:mm or HH:mm:ss) to DateTime
  DateTime _parseTimeString(String timeStr) {
    // Trim whitespace from the time string to handle cases like "07: 04"
    final trimmed = timeStr.trim();
    final parts = trimmed.split(':');
    if (parts.length < 2) {
      throw FormatException("Invalid time format: $timeStr");
    }
    // Trim whitespace from each part to handle cases like "07: 04"
    final hour = int.parse(parts[0].trim());
    final minute = int.parse(parts[1].trim());
    final second = parts.length > 2 ? int.parse(parts[2].trim()) : 0;
    return DateTime(DateTime.now().year, DateTime.now().month,
        DateTime.now().day, hour, minute, second);
  }

  /// Normalize operator strings coming from backend.
  /// Accepts variants like: isbetween / is-between / is_between, noton / not-on, etc.
  String _normalizeRestrictionOperator(String? op) {
    if (op == null) return '';
    final raw = op.trim().toLowerCase();
    final compact = raw
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('_', '')
        .replaceAll('-', '');

    switch (compact) {
      case 'isbetween':
        return 'is-between';
      case 'isbefore':
        return 'is-before';
      case 'isafter':
        return 'is-after';
      case 'noton':
        return 'not-on';
      default:
        // Best-effort: normalize underscores to hyphens.
        return raw.replaceAll('_', '-');
    }
  }

  Future<void> launchUrl(String url) async {
    if (await canLaunch(url)) {
      await launch(url);
    } else {
      throw 'Could not launch $url';
    }
  }
}
