import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:digital_signage/utils/debug_log.dart' as debug;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:battery_plus/battery_plus.dart';
import 'package:image/image.dart' as img;
import 'package:dio/dio.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_phoenix/flutter_phoenix.dart';
import 'package:geolocator/geolocator.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'package:network_info_plus/network_info_plus.dart';
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
import 'package:digital_signage/utils/globle_variable.dart';
import 'package:digital_signage/view_models/system_apply_settings_vm.dart';

import '../data/api_repository/api_repository.dart';
import '../services/mqtt_client_service.dart';
import '../utils/constants.dart';

/// Result of shrinking a remote-view screenshot: the smaller encoded bytes,
/// plus the ratio needed to scale a click received in this frame's pixel
/// space back up to real screen coordinates (real = received * scale).
class _RemoteViewFrame {
  final Uint8List bytes;
  final double scaleX;
  final double scaleY;

  _RemoteViewFrame({
    required this.bytes,
    required this.scaleX,
    required this.scaleY,
  });
}

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
    File('/tmp/debug-25797a.log')
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
  // Release builds have no console -- print() output goes nowhere visible on
  // Linux just as on Windows -- so diagnostics go to a file next to the
  // app's support directory instead. See debug_log.dart.
  Future<void> _debugLog(String message) =>
      debug.debugLog('MqttViewModel', message);

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

  Timer? _pairingRevalidationTimer;

  Timer? _remoteViewTimer;
  bool _remoteViewActive = false;

  // Ratio of real screen pixels to the (shrunk) pixels actually sent in the
  // last remote-view frame — real = received * scale. Click/scroll
  // coordinates from the CMS are in the space of whatever frame it last
  // saw, so incoming positions must be scaled back up by this before
  // being handed to xdotool.
  double _remoteViewScaleX = 1.0;
  double _remoteViewScaleY = 1.0;

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
  Map<String, dynamic>? _storedApiResponse;
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
      _captureRestrictionContext(jsonResponse);
      debugPrint("This is the response from the$topic API: $jsonResponse");
      if (_topic.isNotEmpty) {
        globleTopic = _topic;
      }
      _storedApiResponse = jsonResponse;
      return jsonResponse;
    } else {
      print('No stored response found.');
      return null;
    }
  }

  Future<void> loadDeviceInfoFromSharedPreferences() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? jsonString = prefs.getString('deviceInfoMap');
    await prefs.remove('deviceInfoMap');
    if (jsonString != null) {
      deviceInfoMap = Map<String, dynamic>.from(jsonDecode(jsonString));
      print('Loaded device info from SharedPreferences: $deviceInfoMap');
    } else {
      print('No device info found in SharedPreferences.');
    }
  }

  MqttViewModel(this._mqttClientService) {
    _mqttClientService.receivedMessageNotifier.addListener(_updateMessage);
    _mqttClientService.onMessageReceived = _handleIncomingMessage;

    fetchAllInfo();
    _initializeBasedOnPlatform();
    _monitorConnectivity();
  }

  Future<void> captureAndSendScreenshot(String topic) async {
    try {
      RenderRepaintBoundary boundary = boundaryKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;

      if (boundary.debugNeedsPaint) {
        debugPrint("Widget not rendered yet. Waiting for rendering...");
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final image =
          await boundary.toImage(pixelRatio: 0.5); // Reduce pixel ratio

      final ByteData? byteData =
          await image.toByteData(format: ImageByteFormat.png);

      if (byteData != null) {
        final Uint8List imageBytes = byteData.buffer.asUint8List();
        debugPrint("Original image size: ${imageBytes.length}");

        // Compress the image further (not supported on Linux — skip compression)
        final Uint8List compressedImageBytes;
        if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
          compressedImageBytes = await _compressImage(imageBytes);
        } else {
          compressedImageBytes = imageBytes;
        }
        debugPrint("Compressed image size: ${compressedImageBytes.length}");

        // Convert to Base64 string
        final base64String = base64Encode(compressedImageBytes);

        // Publish the Base64-encoded string
        Map<String, dynamic> sendLog = {
          "action": "screenShot",
          "name": "screenshot",
          "type": "screenShot",
          "dateTime": DateTime.now()
              .toIso8601String(), // Current date and time in ISO 8601 format
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
        _mqttClientService.publishMessage(topic, utf8.encode(base64String));
      } else {
        debugPrint("Failed to capture screenshot: ByteData is null.");
      }
    } catch (error) {
      debugPrint("Error capturing or sending screenshot: $error");
    }
  }

  /// Starts periodic screenshot capture for remote view, matching the
  /// Android app's protocol: publishes `{action:"image", img_url:<base64>}`
  /// to `{playerCode}/remote` (non-retained) roughly once a second. The
  /// CMS renders the received frames; click/scroll/send_text commands sent
  /// back on the same topic are handled in _handleIncomingMessage and
  /// injected via xdotool.
  void _startRemoteView() {
    if (_remoteViewActive) {
      debugPrint('MQTT_LOGS:: Remote view already active, ignoring duplicate start');
      return;
    }
    _remoteViewActive = true;
    _remoteViewScaleX = 1.0;
    _remoteViewScaleY = 1.0;
    debugPrint('MQTT_LOGS:: Remote view started');
    _remoteViewTimer?.cancel();
    _captureAndPublishRemoteViewFrame();
    _remoteViewTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _captureAndPublishRemoteViewFrame();
    });
  }

  void _stopRemoteView() {
    _remoteViewActive = false;
    _remoteViewTimer?.cancel();
    _remoteViewTimer = null;
    debugPrint('MQTT_LOGS:: Remote view stopped');
  }

  // Matches the Android app cancelling its capture coroutine Job and
  // nulling its screenshot callback on stop (ScreenCaptureManager.stop()):
  // an in-flight capture that finishes just after stop_remote_view arrives
  // must not still publish a stray frame. Also prevents captures from
  // stacking up if scrot + resize/encode ever takes longer than the 1s
  // timer interval — the CMS toggling start/stop rapidly (to avoid the
  // base64 stream "loading infinitely") means overlapping captures are a
  // real scenario, not just a theoretical one.
  bool _remoteViewCaptureInFlight = false;

  Future<void> _captureAndPublishRemoteViewFrame() async {
    if (!_remoteViewActive) return;
    if (_topic.isEmpty || !_mqttClientService.isConnected) return;
    if (_remoteViewCaptureInFlight) return;
    _remoteViewCaptureInFlight = true;

    try {
      Uint8List? imageBytes;

      if (Platform.isLinux) {
        // This player embeds native platform-view surfaces (CEF webview,
        // fvp/libmpv video) that are composited outside Flutter's own
        // Skia canvas — RenderRepaintBoundary.toImage() can't rasterize
        // them and throws inside the engine on this build ("LateInitiali-
        // zationError: Local 'result' has not been initialized") on every
        // attempt. Capture the real, fully-composited X11 desktop instead,
        // same principle as the Android app shelling out to screencap
        // instead of using a Flutter-level snapshot. This also keeps
        // capture and xdotool cursor injection in the same coordinate
        // space (raw X11 screen pixels), avoiding a separate DPI/pixel-
        // ratio mismatch between the two.
        //
        // The CEF webview region specifically still comes back black from
        // scrot (X11's XGetImage) even though it's genuinely visible on
        // the real screen. Tried rasterizing just the webview's own
        // RepaintBoundary via toImage() to patch that region in — same
        // LateInitializationError as the whole-app boundary. So this is
        // an engine-level limitation (Skia can't snapshot a render tree
        // containing ANY Linux-embedder-registered texture, not just
        // platform views), not something fixable by isolating the
        // texture in its own boundary. See MQTT_LOGS for the abandoned
        // attempt; a real fix needs webview_cef's native plugin to expose
        // its already-in-memory CEF pixel buffer directly (it has one —
        // see WebviewTextureRenderer::onFrame in webview_cef_plugin.cc),
        // which means forking that package.
        imageBytes = await _captureScreenshotForLinux();
      } else {
        final boundaryContext = boundaryKey.currentContext;
        if (boundaryContext == null) return;
        final renderObject = boundaryContext.findRenderObject();
        if (renderObject is! RenderRepaintBoundary) return;
        if (renderObject.debugNeedsPaint) return;

        final image = await renderObject.toImage(pixelRatio: 1.0);
        final byteData = await image.toByteData(format: ImageByteFormat.png);
        if (byteData == null) return;
        imageBytes = byteData.buffer.asUint8List();
      }

      if (imageBytes == null) return;

      final Uint8List compressedBytes;
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        compressedBytes = await _compressImage(imageBytes);
        _remoteViewScaleX = 1.0;
        _remoteViewScaleY = 1.0;
      } else if (Platform.isLinux) {
        // A full-resolution screenshot can still be hundreds of KB even at
        // low JPEG quality — that's too large for the broker's/CMS's max
        // message size and was getting silently dropped/truncated instead
        // of reaching the CMS at all. Shrink actual pixel dimensions, not
        // just quality, and remember the scale factor so incoming click
        // coordinates (in the space of this smaller frame) can be mapped
        // back to real screen pixels.
        final resized = _resizeAndCompressForRemoteView(imageBytes);
        if (resized != null) {
          compressedBytes = resized.bytes;
          _remoteViewScaleX = resized.scaleX;
          _remoteViewScaleY = resized.scaleY;
        } else {
          compressedBytes = imageBytes;
          _remoteViewScaleX = 1.0;
          _remoteViewScaleY = 1.0;
        }
      } else {
        compressedBytes = imageBytes;
        _remoteViewScaleX = 1.0;
        _remoteViewScaleY = 1.0;
      }
      final base64Image = base64Encode(compressedBytes);

      final payload = jsonEncode({
        'action': 'image',
        'img_url': base64Image,
        // DIAGNOSTIC: matching Android's exact sender value as a test.
        // Android's remote view works against this same CMS; ours doesn't,
        // despite an otherwise identical payload shape (action/img_url/
        // sender — that's the whole message on both sides). If the CMS
        // frontend has any logic keyed on sender == "android" (a render
        // branch, a decode path), an unrecognized "linux" value could
        // explain both the failed render and the crash-like reconnect
        // loop. If this fixes it, the correct long-term fix is for the
        // CMS to add a real "linux" case rather than leaving this here
        // permanently.
        'sender': 'android',
      });

      // Re-check after all the async/CPU-bound capture+encode work above —
      // stop_remote_view may have arrived while this was in flight, in
      // which case this frame is stale and must be discarded, not
      // published.
      if (!_remoteViewActive) {
        debugPrint('MQTT_LOGS:: Remote view stopped mid-capture, discarding frame');
        return;
      }

      // publishMessage (not publish) — remote-view frames must never be
      // retained, or the last frame would linger on the broker and get
      // redelivered to the next viewer even after remote view stops.
      _mqttClientService.publishMessage(
        '$_topic/remote',
        utf8.encode(payload),
      );
    } catch (e) {
      debugPrint('MQTT_LOGS:: Failed to capture/publish remote view frame: $e');
    } finally {
      _remoteViewCaptureInFlight = false;
    }
  }

  /// OS-level X11 screenshot via scrot — requires `sudo apt install scrot`
  /// and an X11 session (matches the xdotool cursor-injection requirement).
  Future<Uint8List?> _captureScreenshotForLinux() async {
    try {
      final tempDir = await getTemporaryDirectory();
      // .jpg extension — scrot picks its output format from the file
      // extension (imlib2-backed), so this gets real JPEG compression for
      // free instead of raw/lossless PNG. Matches the Android app sending
      // JPEG quality 80 rather than PNG, and keeps each frame small enough
      // not to strain the CMS's browser-side MQTT connection over
      // WebSocket once a second.
      final file = File('${tempDir.path}/signagex_remote_view_frame.jpg');
      if (await file.exists()) {
        await file.delete();
      }

      // --overwrite is the only flag we actually need; an unverified extra
      // flag here previously caused scrot to fail on some invocations with
      // no stderr output at all. --quality controls JPEG compression
      // (0-100, scrot default is 75).
      final result = await Process.run(
        'scrot',
        ['--overwrite', '--quality', '60', file.path],
        environment: {'DISPLAY': Platform.environment['DISPLAY'] ?? ':0'},
      );
      if (result.exitCode != 0) {
        debugPrint('MQTT_LOGS:: scrot failed (exit ${result.exitCode}): '
            'stderr="${result.stderr}" stdout="${result.stdout}"');
        return null;
      }
      if (!await file.exists()) {
        debugPrint('MQTT_LOGS:: scrot reported success but output file is missing');
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        // scrot can report exit 0 while still writing an empty file (e.g.
        // if it couldn't reach the X server) — never let this through as
        // a "successful" capture, or we publish a blank image silently.
        debugPrint('MQTT_LOGS:: scrot produced an empty file, treating as failure');
        return null;
      }
      return bytes;
    } catch (e) {
      debugPrint('MQTT_LOGS:: scrot exception: $e');
      return null;
    }
  }

  /// Shrinks a captured frame's actual pixel dimensions (not just JPEG
  /// quality) so the published payload reliably fits under whatever
  /// max-message-size the broker/CMS enforces, and reports the scale
  /// factor needed to map received click coordinates back to real screen
  /// pixels. The exact limit isn't known, so this tries progressively
  /// smaller tiers until the encoded size is comfortably under
  /// [maxBytes], instead of guessing one fixed size up front.
  _RemoteViewFrame? _resizeAndCompressForRemoteView(
    Uint8List bytes, {
    int maxBytes = 15 * 1024,
  }) {
    const tiers = [
      (width: 640, quality: 45),
      (width: 480, quality: 40),
      (width: 320, quality: 35),
      (width: 240, quality: 30),
    ];
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        debugPrint('MQTT_LOGS:: Failed to decode remote view frame for resize');
        return null;
      }

      Uint8List? smallestSoFar;
      double smallestScaleX = 1.0;
      double smallestScaleY = 1.0;

      for (final tier in tiers) {
        if (decoded.width <= tier.width && smallestSoFar == null) {
          // Already smaller than this tier — encode once at native size
          // and quality matching the tier, no resize needed.
          final jpgBytes =
              Uint8List.fromList(img.encodeJpg(decoded, quality: tier.quality));
          smallestSoFar = jpgBytes;
          smallestScaleX = 1.0;
          smallestScaleY = 1.0;
          if (jpgBytes.length <= maxBytes) break;
          continue;
        }
        final resized = img.copyResize(decoded, width: tier.width);
        final jpgBytes = Uint8List.fromList(
          img.encodeJpg(resized, quality: tier.quality),
        );
        smallestSoFar = jpgBytes;
        smallestScaleX = decoded.width / resized.width;
        smallestScaleY = decoded.height / resized.height;
        debugPrint('MQTT_LOGS:: remote view frame tier width=${tier.width} '
            'quality=${tier.quality} -> ${jpgBytes.length} bytes');
        if (jpgBytes.length <= maxBytes) break;
      }

      if (smallestSoFar == null) return null;
      return _RemoteViewFrame(
        bytes: smallestSoFar,
        scaleX: smallestScaleX,
        scaleY: smallestScaleY,
      );
    } catch (e) {
      debugPrint('MQTT_LOGS:: Failed to resize/compress remote view frame: $e');
      return null;
    }
  }

  Future<Uint8List> _compressImage(Uint8List imageBytes) async {
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
    await _loadStoredJsonObj();
    await getStoredState();
    await retrieveStoredResponse();
    await loadDeviceInfoFromSharedPreferences();

    if (await InternetConnectionChecker().hasConnection) {
      await _handleConnectivityChange(true);
    }

    InternetConnectionChecker().onStatusChange.listen((status) async {
      await _handleConnectivityChange(
        status == InternetConnectionStatus.connected,
      );
    });

    // Safety net: once paired with a cached campaign, _checkPairingStatus
    // never runs again on its own (it early-returns unless called with
    // refresh:true, which itself is only reached when there's no cached
    // campaign — i.e. almost never in practice). If the player/player
    // group gets deleted on the CMS and the corresponding remove_campaign/
    // action_delete MQTT message is missed (player offline at that
    // moment, or the CMS's delete flow doesn't publish one at all for
    // group deletion), there is otherwise no way for the player to ever
    // find out — it just replays the last cached campaign forever.
    // Periodically re-verify against the server independent of MQTT.
    _pairingRevalidationTimer?.cancel();
    _pairingRevalidationTimer =
        Timer.periodic(const Duration(seconds: 30), (_) {
      if (_topic.isNotEmpty) {
        _checkPairingStatus(refresh: true);
      }
    });
  }

  Future<void> _handleConnectivityChange(bool hasConnection) async {
    if (hasConnection) {
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

        for (var playlist in _playListModel!.data.playlist) {
          if (playlist.media != null && playlist.media!.isNotEmpty) {
            for (var media in playlist.media!) {
              print("Media URL: ${media.mediaUrl}");
              _startDownloadingForPlaylist();
            }
          }
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
        // Device tags ride on the campaign payload, not the pairing
        // response -- adopt them before any player_tag restriction is
        // evaluated against them.
        _adoptPlayerTagsFromCampaigns(
            _campaignModel?.data?.playerCampaigns);
        _selectCompositionCampaignIndexIfPresent();

        print(_mediaList);
        for (var campaign in _campaignModel?.data?.playerCampaigns ?? []) {
          for (var zone in campaign.zones ?? []) {
            for (var media in zone.mediaItems ?? []) {
              print("Media URL: ${media.mediaUrl}");
              _startDownloadingForCampaign();
            }
          }
        }
      } else if (_topic.isNotEmpty) {
        await _restoreSessionFromStorage();
      } else {
        print("elssssssssssssssssssssse caseeeeeee}");
        await _mqttConnection();
      }
    } else {
      if (storedJsonObj["action"] == "publish_playlist") {
        _playListModel = playListModelFromJson(jsonEncode(storedJsonObj));
        print(_mediaList);
        for (var playlist in _playListModel!.data.playlist) {
          if (playlist.media != null && playlist.media!.isNotEmpty) {
            for (var media in playlist.media!) {
              print("Media URL: ${media.mediaUrl}");
              _startDownloadingForPlaylist();
            }
          }
        }
      } else if (storedJsonObj["action"] == "publish_campaign") {
        _campaignModel = normalizeCampaignResponse(
          campaignModelFromJson(jsonEncode(storedJsonObj)),
          storedJsonObj,
        );
        // Device tags ride on the campaign payload, not the pairing
        // response -- adopt them before any player_tag restriction is
        // evaluated against them.
        _adoptPlayerTagsFromCampaigns(
            _campaignModel?.data?.playerCampaigns);
        _selectCompositionCampaignIndexIfPresent();

        for (var campaign in _campaignModel?.data?.playerCampaigns ?? []) {
          for (var zone in campaign.zones ?? []) {
            for (var media in zone.mediaItems ?? []) {
              print("Media URL: ${media.mediaUrl}");
              _startDownloadingForCampaign();
            }
          }
        }
      } else if (_topic.isNotEmpty && storeState == false) {
        _state = MqttState.pairedScreen;
        notifyListeners();
      } else {
        // With no stored content to restore, a "disconnected" reading used
        // to go straight to MqttState.noInternet without attempting a
        // single network call -- so nothing could ever disprove that
        // reading or recover from it. The player was blocked by the flag
        // itself, not by any actual network failure.
        //
        // That reading is not proof. InternetConnectionChecker decides by
        // probing public DNS resolvers, which a managed or firewalled
        // network blocks outright while the backend stays perfectly
        // reachable -- the classic "works at home, dead in the office"
        // shape. The Android reference player can gate on the OS
        // connectivity answer because on Android that answer is
        // authoritative; a reachability probe against third-party hosts is
        // not the same thing.
        //
        // So the signal is now advisory: it triggers a connection ATTEMPT,
        // and only the attempt decides the outcome. _mqttConnection()
        // already sets noInternet from its own catch when a connection
        // genuinely fails, so a real outage still lands on exactly the same
        // screen -- the difference is that it is decided by a network call
        // that actually failed rather than by a probe that can be, and in
        // the field provably is, wrong.
        _debugLog(
            'connectivity reported disconnected and there is no stored '
            'content -- attempting to connect anyway rather than trusting '
            'the reachability probe');
        await _mqttConnection();
      }
    }
  }

  Future<void> _restoreSessionFromStorage() async {
    await _checkPairingStatus(refresh: true);
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

      devicesinfo["network_name"] = networkName ?? "";

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
    try {
      final result = await getAllSystemInfo();
      if (result.exitCode == 0) {
        final output = result.stdout.trim();

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

        devicesinfo["hardware_details"]["model"] = systemInfo["DeviceName"];
        print(systemInfo["TimeZone"]);
        devicesinfo["hardware_details"]["device_id"] = systemInfo["DeviceID"];
        devicesinfo["storage_info"]["total_storage"] =
            systemInfo["Drives"][0]["TotalSpaceGB"].toString();

        devicesinfo["storage_info"]["available_storage"] =
            systemInfo["Drives"][0]["FreeSpaceGB"].toString();
        print(systemInfo["TimeZone"]);
        devicesinfo["hardware_details"]["ram"] = systemInfo["InstalledRAM"];
        devicesinfo["cpu_information"]["cpu_architecture"] =
            systemInfo["CPUArchitecture"];
        devicesinfo["cpu_information"]["processor"] = systemInfo["CPUInfo"];
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
      
      "DeviceName" = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Name);
      "InstalledRAM" = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty TotalPhysicalMemory);
      "DeviceID" = (Get-WmiObject -Class Win32_ComputerSystemProduct | Select-Object -ExpandProperty UUID);
      "Drives" = \$drives
    }

    # Output the information as JSON
    \$info | ConvertTo-Json
    '''
    ]);
  }

  Future<void> getDataForLinux() async {
    try {
      final systemInfo = await _collectLinuxSystemInfo();
      _applyLinuxSystemInfo(systemInfo);
      systemInfo.forEach((key, value) {
        print('$key: $value');
      });
    } catch (e) {
      print('Linux system info collection failed: $e');
    }

    _fetchCurrentLocation();
    if (_topic.isEmpty) {
      await _checkPairingStatus();
    } else {
      await _restoreSessionFromStorage();
    }
  }

  Future<String> _runLinuxShell(String command) async {
    final result = await Process.run('bash', ['-c', command]);
    if (result.exitCode != 0) {
      return '';
    }
    return result.stdout.toString().trim();
  }

  Future<Map<String, String>> _collectLinuxSystemInfo() async {
    final machineId = await getDeviceIDForLinux();
    final macAddress = await _runLinuxShell(
      "ip addr show | grep 'link/ether' | awk '{print \$2}' | head -n 1",
    );
    final osVersion = await _runLinuxShell('uname -r');
    final cpuInfo = await _runLinuxShell(
      "lscpu | grep 'Model name' | awk -F: '{print \$2}' | xargs",
    );
    final cpuArchitecture = await _runLinuxShell('uname -m');
    final availableMemory = await _runLinuxShell(
      "free -m | grep 'Mem:' | awk '{print \$7}'",
    );
    final networkAdapters = await _runLinuxShell(
      "ip link show | awk -F: '/^[0-9]+:/{print \$2}' | xargs",
    );
    final timeZone = await _runLinuxShell(
      "timedatectl 2>/dev/null | grep 'Time zone' | awk '{print \$3}'",
    );
    final deviceName = await _runLinuxShell('hostname');
    final installedRam = await _runLinuxShell(
      "free -m | grep 'Mem:' | awk '{print \$2}'",
    );
    final diskCapacity = await _runLinuxShell(
      "df -h --total 2>/dev/null | grep 'total' | awk '{print \$2}'",
    );

    return {
      'MachineId': machineId,
      'MacAddress': macAddress,
      'OSVersion': osVersion,
      'CPUInfo': cpuInfo,
      'CPUArchitecture': cpuArchitecture,
      'AvailableMemory': availableMemory.isEmpty ? '' : '$availableMemory MB',
      'NetworkAdapters': networkAdapters,
      'TimeZone': timeZone,
      'DeviceName': deviceName,
      'InstalledRAM': installedRam.isEmpty ? '' : '$installedRam MB',
      'DiskCapacity': diskCapacity,
    };
  }

  void _applyLinuxSystemInfo(Map<String, String> systemInfo) {
    final macAddress = systemInfo['MacAddress'] ?? '';
    final machineId = systemInfo['MachineId'] ?? '';

    devicesinfo['sender'] = 'Linux';
    devicesinfo['time_zone'] = systemInfo['TimeZone'] ?? '';
    devicesinfo['mac_address']['platform'] = 'Linux';
    devicesinfo['mac_address']['macAddress'][0]['interface'] = 'wlan0';
    devicesinfo['mac_address']['macAddress'][0]['mac'] =
        macAddress.isNotEmpty ? macAddress : machineId;
    devicesinfo['ram_info'] = systemInfo['InstalledRAM'] ?? '';
    devicesinfo['hardware_details']['model'] =
        systemInfo['DeviceName'] ?? 'Linux';
    devicesinfo['hardware_details']['device_id'] =
        machineId.isNotEmpty ? machineId : macAddress;
    devicesinfo['storage_info']['total_storage'] =
        systemInfo['DiskCapacity'] ?? '';
    devicesinfo['hardware_details']['ram'] = systemInfo['InstalledRAM'] ?? '';
    devicesinfo['cpu_information']['cpu_architecture'] =
        systemInfo['CPUArchitecture'] ?? '';
    devicesinfo['cpu_information']['processor'] = systemInfo['CPUInfo'] ?? '';
    devicesinfo['android_version'] = systemInfo['OSVersion'] ?? '';
  }

  Future<String> getDeviceIDForLinux() async {
    for (final path in ['/etc/machine-id', '/var/lib/dbus/machine-id']) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final id = (await file.readAsString()).trim();
          if (id.isNotEmpty) {
            return id;
          }
        }
      } catch (e) {
        print('Failed to read Linux machine id from $path: $e');
      }
    }

    final hostname = await _runLinuxShell('hostname');
    if (hostname.isNotEmpty) {
      return hostname;
    }

    return 'linux-${DateTime.now().millisecondsSinceEpoch}';
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

  // The stored-content branches of the connectivity handler call
  // _mqttClientService.connect() bare. A throw there is an unhandled async
  // error inside a stream listener callback: it aborts the REST of that
  // callback (the subscribe and device-info publish that follow it) and
  // schedules no retry, so an already-paired player that happened to start
  // while the network was still settling would render its stored content
  // and never reconnect to MQTT -- silently stuck on old content, with no
  // no-internet screen to even hint at it.
  Future<bool> _tryConnect(String where) async {
    try {
      await _mqttClientService.connect(playerCode: _topic);
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
      if (_topic.isNotEmpty) {
        await _restoreSessionFromStorage();
        return;
      }
      await _mqttClientService.connect(playerCode: _topic);
      _state = MqttState.connectionScreen;
      notifyListeners();
      await _checkPairingStatus();
      // Got through a full connect and pairing check, so whatever was wrong
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

  /// Retries a failed connection until it works, instead of giving up.
  ///
  /// The catch above used to set MqttState.noInternet and schedule nothing,
  /// so whatever the very first attempt saw was FINAL and the only thing
  /// that could ever rescue the player was the connectivity stream firing
  /// again. That makes startup timing decisive: a player launched from a
  /// desktop session or a systemd unit routinely starts before
  /// NetworkManager has finished bringing the link up and DHCP has settled,
  /// so the first attempt fails for a reason that clears itself seconds
  /// later -- and the player sat on "no internet" indefinitely with a
  /// perfectly working network.
  ///
  /// A plain periodic retry removes that whole class of failure: it no
  /// longer matters why the first attempt failed (too early, transient DNS,
  /// backend blip, link still negotiating), because the player keeps trying
  /// until it genuinely works and cancels itself the moment it does.
  ///
  /// Stops on _needsReconnect rather than on _state: the paired path arms
  /// this while the player is happily rendering stored content
  /// (_state == campaignScreen), so a state-based stop condition would
  /// cancel the timer on its very first tick and fix nothing.
  void _startNetworkRecovery() {
    _needsReconnect = true;
    // Slightly longer than the service's 20s connect timeout, so a tick
    // normally lands between attempts rather than on top of one still
    // running.
    _networkRecoveryTimer ??=
        Timer.periodic(const Duration(seconds: 25), (_) async {
      if (!_needsReconnect) {
        _networkRecoveryTimer?.cancel();
        _networkRecoveryTimer = null;
        return;
      }
      // A connect attempt can outlast a tick, and the ticks that land on
      // top of one hit the _mqttConnecting guard and return silently --
      // which in a log reads as a retry that is broken rather than one that
      // is merely busy. Say which it is.
      if (_mqttConnecting) {
        _debugLog('network recovery tick -- SKIPPED, attempt still in flight');
        return;
      }
      _debugLog('network recovery tick -- retrying (state=$_state)');
      // Rebuild the client before retrying. Retrying against the same
      // poisoned client makes no progress, while a fresh process connects
      // in under a second -- see resetClient().
      await _mqttClientService.resetClient();
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

  /// Re-establishes the MQTT session (connect, resubscribe, republish device
  /// info, mirroring what the connectivity handler does) without touching
  /// the UI state.
  Future<void> _reconnectSession() async {
    if (_mqttConnecting) return;
    _mqttConnecting = true;
    try {
      await _mqttClientService.connect(playerCode: _topic);
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
      _debugLog(
          'network recovery: still failing -- ${error.runtimeType} -- $error');
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
    if (_state == MqttState.downloading) {
      print("Downloads are already in progress.");
      return;
    }

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
    // Counted separately so the end of the loop can tell "some assets were
    // unreachable" apart from "nothing downloaded at all".
    int failedDownloads = 0;
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
          completedDownloads++;
          _updateOverallProgress(completedDownloads);
          continue;
        }
        String filename = _extractFilename(mediaUrl);
        Directory? directory = await _getDirectory();
        if (directory == null) {
          print('Unable to determine directory');
          throw Exception('Unable to determine directory');
        }

        String filePath = '${directory.path}/$filename';
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
          } catch (error, stackTrace) {
            print("Error downloading file: $error");
            // Was print() only, so on a release build a failed asset left no
            // evidence anywhere -- a playlist stuck mid-download looked
            // identical to one still downloading, with nothing in the log
            // between heartbeats. The URL matters most: it names which asset
            // is unreachable.
            failedDownloads++;
            _debugLog('downloadFileForPlaylist FAILED playlist=${playlist.id} '
                'url=$mediaUrl -- ${error.runtimeType}: $error\n$stackTrace');

            Map<String, dynamic> errorLog = {
              "action": "player_logs",
              "log": "Download Playlist",
              "name":
                  "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
              "type": "error",
              "date_time": DateTime.now().toIso8601String(),
            };
            _mqttClientService.publish(topic, jsonEncode(errorLog));

            // Counted even though it failed. Without this the check below
            // can never satisfy completedDownloads == _downloadCount, so the
            // playlist is never committed and the player sits on the
            // downloading screen at whatever percentage the last success
            // reached -- permanently. Seen in the field as "stuck at 29%".
            //
            // One unreachable asset must not take the whole playlist down: a
            // screen showing the rest of its content is strictly better than
            // a screen showing a frozen progress bar. The per-file
            // `_state = MqttState.failure` that used to sit here is gone
            // with it -- it fought the progress UI on every subsequent file
            // and described the whole playlist as failed on the strength of
            // one missing asset.
            completedDownloads++;
            _updateOverallProgress(completedDownloads);
          }
        }
      }
    }

    if (failedDownloads > 0) {
      _debugLog('playlist download finished with $failedDownloads of '
          '$_downloadCount asset(s) unavailable -- playing the rest');
      if (failedDownloads == _downloadCount) {
        // Nothing arrived, so there is genuinely nothing to show.
        _debugLog('playlist download: every asset failed -> failure state');
        _state = MqttState.failure;
        notifyListeners();
        return;
      }
    }

    if (completedDownloads == _downloadCount) {
      print("All media files for all playlists have been downloaded.");
      _updateMediaModelForPlaylist(); // Update model with local file paths
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
        String filename = _extractFilename(url);
        Directory? directory = await _getDirectory();
        if (directory == null) {
          print('Unable to determine directory');
          throw Exception('Unable to determine directory');
        }

        String filePath = '${directory.path}/$filename';
        print('Downloading from URL: $url to $filePath');

        _currentFileProgress = 0.0;
        notifyListeners();

        Dio dio = Dio();
        await dio.download(
          url,
          filePath,
          onReceiveProgress: (received, total) {
            if (total != -1 && total > 0) {
              _updateCurrentFileProgress(received, total);
            }
          },
        );

        _mediaPath[playlistId]?.add(filePath);
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
    if (_state == MqttState.downloading) {
      print("Downloads are already in progress.");
      return;
    }

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
      print(
          'No downloadable files; showing campaign with web/inline media '
          '(${campaigns.length} campaign(s)).');
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
      if (media.mediaType?.toLowerCase() == 'sticker') {
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
        final localPath = await _ensureLocalMediaUrl(
          originalUrl,
          onProgress: _updateCurrentFileProgress,
        );
        // Update the appropriate URL field
        if (media.mediaType?.toLowerCase() == 'sticker') {
          // Stickers: always store local path in settings.remoteSrc so the UI uses it at render time
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
              mediaType == 'text' ||
              mediaType == 'shape') {
            continue;
          }
          if (mediaType == 'content' && mediaItemIsWebAppIframe(media)) {
            continue;
          }
          final rawUrl = media.mediaUrl ?? '';
          if (rawUrl.contains('<svg')) {
            continue;
          }
          if (_isNestedCampaignMediaItem(media)) {
            visitZones(media.zones ?? const <CampaignZone>[]);
            continue;
          }
          // For stickers, prefer remoteSrc; for ads, prefer creative URL
          String? url;
          if (media.isAd || idLooksLikeAdSlot(media.id)) {
            url = media.adCreativeUrl;
          } else if (media.mediaType?.toLowerCase() == 'sticker') {
            url = media.settings?.remoteSrc ?? media.mediaUrl;
          } else {
            url = media.mediaUrl;
          }
          if (url != null && url.isNotEmpty) {
            result.add(media);
          }
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

  Future<String> _ensureLocalMediaUrl(String url,
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
      fullUrl = 'https://signagexai.com$trimmed';
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

    final filename = _extractFilename(fullUrl);
    final directory = await _getDirectory();
    if (directory == null) {
      throw Exception('Unable to determine directory');
    }

    final filePath = '${directory.path}/$filename';
    final file = File(filePath);
    final exists = await file.exists();
    if (exists) {
      print('File already exists: $filePath');
      return filePath;
    }

    // Ensure URL is valid for parsing (fix illegal percent encoding).
    String downloadUrl = fullUrl;
    try {
      Uri.parse(fullUrl);
    } catch (_) {
      downloadUrl = fullUrl.replaceAllMapped(
          RegExp(r'%(?![0-9A-Fa-f]{2})'), (_) => '%25');
    }

    final dio = Dio();
    print('Downloading from URL: $downloadUrl to $filePath');
    try {
      await dio.download(
        downloadUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received, total);
        },
      );
      print('Download complete: $filePath');
      return filePath;
    } catch (e) {
      print('Error downloading $downloadUrl: $e');
      // If download fails, return the original URL so widget can try to handle it
      return fullUrl;
    }
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

  String _extractFilename(String url, {String? mediaType}) {
    String decodedUrl;
    try {
      decodedUrl = Uri.decodeFull(url);
    } catch (_) {
      // URL has invalid percent encoding (e.g. illegal % sequence); use raw path.
      decodedUrl = url;
    }
    String filename = decodedUrl.split('/').last.split('?').first;
    // Sanitize: remove characters that are invalid in URIs or filenames.
    if (filename.isEmpty) {
      filename = 'file_${url.hashCode.abs()}';
    }
    filename = filename.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_');
    if (mediaType != null) {
      switch (mediaType) {
        case 'audio/mpeg':
          filename += '.mp3';
          break;
        case 'audio/mp4':
          filename += '.m4a';
          break;
        case 'video/mp4':
          filename += '.mp4';
          break;
        case 'image/jpeg':
        case 'image/png':
        case 'image/gif':
          filename += '.jpg';
          break;
        default:
          break;
      }
    } else {
      if (url.contains('images')) {
        filename += '.jpg';
      }
    }

    return filename;
  }

  Future<void> reportAdProofOfPlay(AdProofOfPlayRequest request) async {
    final url = '$baseurl$adCampaignProofOfPlayPath';
    if (playerCode.isEmpty) {
      print('[AdPoP] Skipped: player_code is empty (POST $url)');
      return;
    }
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
    } catch (e, st) {
      print('[AdPoP] HTTP/network error: $e');
      print('[AdPoP] Stack: $st');
    }
  }

  Future<Directory?> _getDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      // Use the application documents directory for Android and iOS
      return await getApplicationDocumentsDirectory();
    } else if (Platform.isMacOS) {
      // On macOS release (sandbox), use Documents so the video player can read files.
      // Downloads in the container can trigger "permission to view" errors with AVPlayer.
      return await getApplicationDocumentsDirectory();
    } else if (Platform.isWindows || Platform.isLinux) {
      try {
        return await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
      } catch (e) {
        print(
            'Error getting downloads directory, falling back to applicationDocumentsDirectory: $e');
        return await getApplicationDocumentsDirectory();
      }
    }
    return null;
  }

  Future<void> _resetLocalPlayerSession() async {
    _stopRemoteView();
    _topic = '';
    globleTopic = '';
    storeState = null;
    _storedApiResponse = null;
    storedJsonObj = {};
    _campaignModel = null;
    _playListModel = null;
    _interactivityModel = null;
    _currentIndexOfCapmaign = 0;
  }

  Future<void> _checkPairingStatus({bool refresh = false}) async {
    if (_topic.isNotEmpty && !refresh) {
      debugPrint('Pairing skipped: player_code already set ($_topic)');
      return;
    }

    if (refresh && _topic.isNotEmpty) {
      debugPrint('Refreshing player registration for $_topic');
    }

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

      _storedApiResponse = Map<String, dynamic>.from(response as Map);
      if (response is Map<String, dynamic>) {
        _captureRestrictionContext(response);
      }
      _topic = response["player_code"] ?? "";

      if (_topic.isEmpty) {
        debugPrint("Warning: player_code is empty or null in API response");
        _state = MqttState.failure;
        notifyListeners();
        return;
      }

      globleTopic = _topic;

      // Process pairing status FIRST so state updates even if MQTT ops fail below
      if (response["paired"] == false &&
          response["action"] == "action_stop_player") {
        // PLAYER_STOP_REASON_CONTRACT: this player IS paired -- the backend
        // stopped it for a licence/subscription/account reason, which is
        // completely different from never having been paired at all. Any
        // paired:false response used to fall through to the branch below
        // regardless of cause, showing the pairing/QR screen: actively
        // misleading, since pairing is guaranteed to be refused while a
        // stop reason holds, so the code invited an action that could not
        // succeed and made it look as though the screen's data had been
        // wiped when nothing had.
        //
        // Deliberately does NOT write storeState, and does NOT clear the
        // cached campaign/playlist the branch below clears -- swapping the
        // screen to PlayerStoppedView is what stops content showing;
        // nothing underneath is torn down, so the resume is instant. An
        // unrecognised reason value still lands here and is handled
        // generically by PlayerStoppedView, never falling through to the
        // pairing-code screen.
        _stopReason = (response["reason"] ?? "").toString();
        _debugLog('pairing check: backend stopped this player '
            '(reason=$_stopReason)');
        _state = MqttState.playerStopped;
        // Same poll-until-resumed mechanism as the unpaired case -- per the
        // contract nothing is pushed on restore, the poll is the whole
        // mechanism.
        _startPairingPollingTimer();
      } else if (response["paired"] == false) {
        print("this is state screeen ${response["paired"]}");
        storeState = false;
        await prefs.setBool('storeState', false);
        _state = MqttState.pairedScreen;
        _startPairingPollingTimer();

        // The server no longer considers this player paired — e.g. it (or
        // its player group) was deleted from the CMS. Clear any cached
        // campaign/playlist so stale content can't get reloaded from
        // local storage on the next reconnect; without this the old
        // content would keep playing indefinitely since nothing else
        // clears it.
        if (_campaignModel != null ||
            _playListModel != null ||
            storedJsonObj.isNotEmpty) {
          debugPrint(
              'MQTT_LOGS:: Player no longer paired — clearing cached content');
          _campaignModel = null;
          _playListModel = null;
          _interactivityModel = null;
          storedJsonObj = {};
          await prefs.remove('jsonObj');
          await prefs.remove('last_publish_campaign_payload');
        }
      } else if (response["paired"] == true) {
        _stopReason = null;
        storeState = true;
        await prefs.setBool('storeState', true);
        _stopPairingPollingTimer();
        // Nothing more is needed to keep noticing a later stop: this
        // branch is reached from _pairingRevalidationTimer, which re-polls
        // player/connection every 30s for the life of the app. That is what
        // carries a licence removed mid-playback to the screen -- the 15s
        // poll cancelled just above only ever runs while already stopped or
        // unpaired.
        if (_state == MqttState.playerStopped) {
          // PLAYER_STOP_REASON_CONTRACT: "there is no separate resume
          // message... the poll is the entire mechanism" -- nothing
          // re-sends the campaign on restore, so falling through to the
          // noContent branch below would leave the screen stuck there
          // forever, with nothing left to move it back to campaignScreen.
          // _campaignModel/_playListModel were never touched while stopped,
          // so they are exactly what brings the screen back -- resume from
          // them directly.
          _debugLog('pairing check: player resumed -- restoring from cache');
          if (_campaignModel != null) {
            _state = MqttState.campaignScreen;
          } else if (_playListModel != null) {
            _state = MqttState.playlistScreen;
          } else {
            _state = MqttState.noContent;
          }
        } else if (_state != MqttState.downloading &&
            _state != MqttState.campaignScreen &&
            _state != MqttState.playlistScreen) {
          _state = MqttState.noContent;
        }
      } else {
        _state = MqttState.failure;
      }
      notifyListeners();

      // MQTT ops after state update — failures here don't block pairing state
      try {
        await _mqttClientService.connect(playerCode: _topic);
      } catch (e) {
        debugPrint('MQTT connect during pairing failed: $e');
      }

      try {
        subsibeMessage(_topic);
      } catch (e) {
        debugPrint('Subscribe during pairing failed: $e');
      }
      await prefs.setString('deviceInfoMap', jsonEncode(deviceInfoMap));
      try {
        publishMessage(globleTopic, jsonEncode(deviceInfoMap));
      } catch (e) {
        debugPrint('Publish during pairing failed: $e');
      }

      // Reset retry counter on successful API call
      _pairingRetryCount = 0;
    } catch (error) {
      debugPrint("Error during pairing check: $error");

      // A stopped player already has the pairing poll quietly retrying
      // every 15s, so a transient network error here must not escalate into
      // the app-restart path below.
      if (_state == MqttState.playerStopped) {
        _debugLog('pairing check failed while stopped -- leaving the poll to '
            'retry: $error');
        return;
      }

      _pairingRetryCount++;

      // Check if error is a 500 server error
      final errorString = error.toString();
      final isServerError = errorString.contains('500') ||
          errorString.contains('Error During Communication');

      if (isServerError && _pairingRetryCount >= _maxPairingRetries) {
        debugPrint(
            "Max retries ($_maxPairingRetries) reached for pairing check. Restarting app...");
        _pairingRetryCount = 0; // Reset counter
        // Restart the app to reset the flow
        await Future.delayed(const Duration(seconds: 2));
        await restartApp();
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

      // If not a server error or max retries not reached, just show connection screen
      _state = MqttState.connectionScreen;
      debugPrint("Error: $error");
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
    // Remote-view screenshots are published here and cursor/click commands
    // from the CMS arrive here too — without this the player would stream
    // screenshots out but never receive any input back.
    _mqttClientService.subscribe('$topic/remote');
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
    } on PlatformException catch (e) {
      print("Failed to restart app: ${e.message}");
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

  Timer? _pairingPollingTimer;

  void _startPairingPollingTimer() {
    _pairingPollingTimer?.cancel();
    _pairingPollingTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      // playerStopped polls on the same cadence: per
      // PLAYER_STOP_REASON_CONTRACT the poll is the only thing that ever
      // learns the player has been resumed, so stopping it here would make
      // the stop permanent until a restart.
      if (_state == MqttState.pairedScreen ||
          _state == MqttState.playerStopped) {
        debugPrint('MQTT_LOGS:: Polling pairing status...');
        await _checkPairingStatus(refresh: true);
      } else {
        _stopPairingPollingTimer();
      }
    });
  }

  void _stopPairingPollingTimer() {
    _pairingPollingTimer?.cancel();
    _pairingPollingTimer = null;
  }


  void setTapPosition(double x, double y) {
    tapX = x;
    tapY = y;
    // if(tapX==_interactivityModel!.data.interactivity[].regionX ||  tapY==_interactivityModel!.data.interactivity[].regionY){
    // print("i am in intractivity by region");

    // }
    notifyListeners();
  }

  void getKey(String keydata) {
    _key = keydata;
    notifyListeners();
    // Check if any key in the interactivity list matches _key (case-insensitive)
    bool keyFound = _interactivityModel?.data.interactivity.any(
            (interactivity) => interactivity.keyPress
                .any((key) => key.toUpperCase() == _key!.toUpperCase())) ??
        false;
    print("this is key data $keydata");
    if (keyFound) {
      print("I am in interactivity by key");
    } else {
      print("Key not found in interactivity");
    }
  }

  void _handleIncomingMessage(String message) async {
    print('Received message in ViewModel: $message');

    print('Received message in store state: $storeState');
    print('i am in recive msgss:');
// await restartApp();
    final jsonObj = jsonDecode(message);

    print('Saving JSON Object: $jsonObj');

    // Check if message has an action field
    if (jsonObj["action"] == null) {
      // Message doesn't have an action field - likely device info or other data
      // Just log it and return, don't process it as a command
      print('MQTT_LOGS:: Received message without action field - ignoring');
      return;
    }

    if (jsonObj["action"] == "publish_playlist" ||
        jsonObj["action"] == "publish_campaign") {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      bool isSaved = await prefs.setString('jsonObj', jsonEncode(jsonObj));

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
        "name": "Player ${deviceInfo!["hardware_details"]["model"]}",
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
      if (storeState != true) {
        await _checkPairingStatus(refresh: true);
      }
      // print("action mute${jsonObj["settings"]?["mute_audio"]}");
      if (jsonObj["settings"] != null &&
          jsonObj["settings"]["mute_audio"] == true) {
        Map<String, dynamic> sendLog = {
          "action": "player_logs",
          "log": "Mute Audio",
          "name": "Player ${deviceInfo!["hardware_details"]["model"]}",
          "type": "info",
          "date_time": DateTime.now().toIso8601String(),
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
        if (Platform.isMacOS) {
          deviceSettings.muteVolumeForMac();
        } else if (Platform.isAndroid) {
          print("i am here for andorind");
          deviceSettings.muteVolumeForAndroid();
        } else if (Platform.isWindows) {
          deviceSettings.muteVolumeForWindows();
        } else if (Platform.isLinux) {
          deviceSettings.muteVolumeForLinux();
        }
      }
      // Independent `if`s below (not `else if`) — CMS resends the whole
      // current settings object on any single change (e.g. rotating also
      // re-sends mute_audio/brightness/volume as they currently stand), so
      // an else-if chain here meant only the first truthy field in the
      // payload ever got applied and every other setting silently no-oped
      // whenever it arrived alongside an earlier one, which is why
      // rotation looked broken.
      if (jsonObj["settings"] != null &&
          jsonObj["settings"]["mute_audio"] == false) {
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
        } else if (Platform.isAndroid) {
          print("i am here for andorind");
          deviceSettings.unmuteVolumeForAndroid();
        } else if (Platform.isWindows) {
          deviceSettings.unmuteVolumeForWindows();
        } else if (Platform.isLinux) {
          deviceSettings.unmuteVolumeForLinux();
        }
      }
      if (jsonObj["settings"] != null &&
          jsonObj["settings"]["brightness"] != null &&
          jsonObj["settings"]["brightness"]['value'] != null) {
        Map<String, dynamic> sendLog = {
          "action": "player_logs",
          "log": "brightness",
          "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
          "type": "info",
          "date_time": DateTime.now().toIso8601String(),
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
        if (Platform.isMacOS) {
          print("No brightness For Mac");
          deviceSettings.unmuteVolumeForMac();
        } else if (Platform.isAndroid) {
          print("i am here for andorind");
          var value = jsonObj["settings"]["brightness"]['value'];
          deviceSettings.setAppBrightnessForAndroid(value);
        } else if (Platform.isWindows) {
          var res = jsonObj["settings"]["brightness"]['value'];
          deviceSettings.adjustBrightnessForWindows(res);
        } else if (Platform.isLinux) {
          var res = jsonObj["settings"]["brightness"]['value'];
          deviceSettings.changeBrightnessForLinux(res);
        }
      }
      if (jsonObj["settings"] != null &&
          jsonObj["settings"]["volume"] != null) {
        Map<String, dynamic> sendLog = {
          "action": "player_logs",
          "log": "Volume",
          "name": "Player ${deviceInfo!["hardware_details"]["model"]}",
          "type": "info",
          "date_time": DateTime.now().toIso8601String(),
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
        if (Platform.isMacOS) {
          print("No Volue For Mac");
          var res = jsonObj["settings"]["volume"];
          deviceSettings.setVolumeForMac(res);
        } else if (Platform.isAndroid) {
          print("i am here for andorind");
          var value = jsonObj["settings"]["volume"];
          deviceSettings.setVolumeForAndroid(value);
        } else if (Platform.isWindows) {
          var res = jsonObj["settings"]["volume"];
          deviceSettings.adjustBrightnessForWindows(res);
        } else if (Platform.isLinux) {
          var res = jsonObj["settings"]["brightness"];
          deviceSettings.changeBrightnessForLinux(res);
        }
      }
      if (jsonObj["settings"] != null &&
          jsonObj["settings"]["screen_rotation"] != null) {
        Map<String, dynamic> sendLog = {
          "action": "player_logs",
          "log": "Screen Rotation",
          "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
          "type": "info",
          "date_time": DateTime.now().toIso8601String(),
        };

        _mqttClientService.publish(topic, jsonEncode(sendLog));
        if (Platform.isLinux) {
          final rotation = jsonObj["settings"]["screen_rotation"].toString();
          deviceSettings.applyScreenRotationForLinux(rotation);
        }
      }
      var data = {"success": true};
      publishMessage(globleTopic, jsonEncode(data));
    } else if (jsonObj["action"] == "action click") {
      print(" i am in action  click");
    } else if (jsonObj["action"] == "start_remote_view") {
      print("MQTT_LOGS:: start_remote_view received");
      _startRemoteView();
    } else if (jsonObj["action"] == "stop_remote_view") {
      print("MQTT_LOGS:: stop_remote_view received");
      _stopRemoteView();
    } else if (jsonObj["action"] == "low_res") {
      // Observed from a real CMS session: the web remote-view page can
      // send this without ever sending start_remote_view first. Treat it
      // as an equivalent start trigger too — _startRemoteView() already
      // no-ops if a capture loop is already running, so handling both
      // costs nothing regardless of which one the CMS actually uses.
      print("MQTT_LOGS:: low_res received — starting remote view");
      _startRemoteView();
    } else if (jsonObj["action"] == "click") {
      // Same field names as the Android app's InputAction.getClick — x/y in
      // the pixel space of the most recent remote-view frame we published.
      // That frame is shrunk on Linux (see _resizeAndCompressForRemoteView),
      // so scale back up to real screen pixels before injecting.
      print("MQTT_LOGS:: click received: $jsonObj");
      if (Platform.isLinux) {
        final x = (jsonObj["x"] as num?)?.toDouble();
        final y = (jsonObj["y"] as num?)?.toDouble();
        if (x != null && y != null) {
          deviceSettings.moveCursorAndClickForLinux(
            x * _remoteViewScaleX,
            y * _remoteViewScaleY,
          );
        }
      }
    } else if (jsonObj["action"] == "scroll") {
      // Same shape as Android's InputAction.getScroll: hold/release objects
      // each carrying an x/y pair, treated as a press-drag-release gesture.
      print("MQTT_LOGS:: scroll received: $jsonObj");
      if (Platform.isLinux) {
        final hold = jsonObj["hold"];
        final release = jsonObj["release"];
        if (hold is Map && release is Map) {
          final startX = (hold["x"] as num?)?.toDouble();
          final startY = (hold["y"] as num?)?.toDouble();
          final endX = (release["x"] as num?)?.toDouble();
          final endY = (release["y"] as num?)?.toDouble();
          if (startX != null &&
              startY != null &&
              endX != null &&
              endY != null) {
            deviceSettings.dragForLinux(
              startX * _remoteViewScaleX,
              startY * _remoteViewScaleY,
              endX * _remoteViewScaleX,
              endY * _remoteViewScaleY,
            );
          }
        }
      }
    } else if (jsonObj["action"] == "send_text") {
      print("MQTT_LOGS:: send_text received: $jsonObj");
      if (Platform.isLinux) {
        final text = jsonObj["message"]?.toString();
        if (text != null && text.isNotEmpty) {
          deviceSettings.typeTextForLinux(text);
        }
      }
    } else if (jsonObj["action"] == "press_home") {
      // CMS "home screen" remote-view button. Matches Android's PRESS_HOME
      // (input keyevent 3 / GLOBAL_ACTION_HOME) — a raw OS key injection,
      // not app-level navigation.
      print("MQTT_LOGS:: press_home received: $jsonObj");
      if (Platform.isLinux) {
        deviceSettings.pressHomeForLinux();
      }
    } else if (jsonObj["action"] == "press_back") {
      // Undoes press_home -- there was previously no way to bring the
      // player back into view remotely after Home minimized it.
      print("MQTT_LOGS:: press_back received: $jsonObj");
      if (Platform.isLinux) {
        deviceSettings.pressBackForLinux();
      }
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

      for (var playlist in _playListModel!.data.playlist) {
        // Check if the playlist contains any media
        if (playlist.media != null && playlist.media!.isNotEmpty) {
          for (var media in playlist.media!) {
            print("Media URL: ${media.mediaUrl}");

            // Start downloading for each media item
            _startDownloadingForPlaylist();
          }
        }
      }
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
      _campaignModel = normalizeCampaignResponse(
        campaignModelFromJson(jsonEncode(jsonObj)),
        jsonObj,
      );
      // Device tags ride on the campaign payload, not the pairing
      // response -- adopt them before any player_tag restriction is
      // evaluated against them.
      _adoptPlayerTagsFromCampaigns(
          _campaignModel?.data?.playerCampaigns);
      final campaigns = _campaignModel?.data?.playerCampaigns;
      final count = campaigns?.length ?? 0;
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
      // Ensure any listening UI updates immediately
      notifyListeners();

      // Optional: soft-restart the Flutter widget tree so the whole UI reloads
      // (useful if some screens are not wired to rebuild correctly).
      //
      // Guarded to avoid restart loops if broker re-sends retained messages.
      try {
        final prefs = await SharedPreferences.getInstance();
        final payload = jsonEncode(jsonObj);
        final prev = prefs.getString('last_publish_campaign_payload');
        if (prev != payload) {
          await prefs.setString('last_publish_campaign_payload', payload);
          final ctx = boundaryKey.currentContext;
          if (ctx != null) {
            Phoenix.rebirth(ctx);
          } else {
            debugPrint('MQTT_LOGS:: Phoenix context not available for restart');
          }
        }
      } catch (e) {
        debugPrint('MQTT_LOGS:: Failed to restart app on publish_campaign: $e');
      }
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
      for (var campaign in _campaignModel?.data?.playerCampaigns ?? []) {
        for (var zone in campaign.zones ?? []) {
          for (var media in zone.mediaItems ?? []) {
            print("Media URL: ${media.mediaUrl}");
            _startDownloadingForCampaign();
          }
        }
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
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await _resetLocalPlayerSession();

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
      debugPrint("Player deleted from dashboard – resetting local session");
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await _resetLocalPlayerSession();
      await _checkPairingStatus();
      await getStoredState();
    } else if (jsonObj["action"] == "remove_campaign") {
      debugPrint("remove playlist and update screen");
      Map<String, dynamic> sendLog = {
        "action": "player_logs",
        "log": "Remove Campaign",
        "name": "Player ${deviceInfo?["hardware_details"]["model"] ?? ""}",
        "type": "info",
        "date_time": DateTime.now().toIso8601String(),
      };

      _mqttClientService.publish(topic, jsonEncode(sendLog));
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await _resetLocalPlayerSession();
      await _checkPairingStatus();
    }
    notifyListeners();
  }

  int _currentIndexOfCapmaign = 0;

  // isPaused was parsed off every campaign but never actually checked
  // anywhere the player decides what to show -- a Paused campaign rotated
  // into view and played exactly like any other. (Unpublish was already
  // handled separately, wherever this codebase drops to zero campaigns.)
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

  int get currentIndexOfCapmaign => _currentIndexOfCapmaign;

  int get currentDurationOfCampaign =>
      _durationForCampaignAt(_currentIndexOfCapmaign);

  /// How long campaign [index] should play for, or 0 if it may not play now.
  ///
  /// Split out of the currentDurationOfCampaign getter so the bounded scan
  /// in _updateIndexForCampain can score a CANDIDATE index without first
  /// mutating _currentIndexOfCapmaign to point at it.
  int _durationForCampaignAt(int index) {
    final currentCampaign = campaignModel?.data?.playerCampaigns?[index];
    if (currentCampaign == null) return 0;

    final campaignSchedule = currentCampaign.campaignSchedule;
    if (campaignSchedule == null) {
      print('Index: $index, Duration: 15 seconds, '
          'Always Play: true (default, no schedule)');
      return 15;
    }

    int durationcampagin = 0;

    // This rotation-side eligibility check and CampaignView's render-side
    // check were two different systems answering the same question, and
    // they disagreed for any restriction-scheduled campaign.
    //
    // The render side asks:
    //     alwaysPlay ? yes : (restrictions.isNotEmpty ? checkRestrictions(...) : no)
    // while this function only ever looked at alwaysPlay or the LEGACY
    // `period` block (date/days/time), never at `restrictions` at all.
    //
    // So a campaign with alwaysPlay=false, no period and a passing
    // restriction rendered correctly, and then CampaignView's own initState
    // post-frame callback called startPlaylistTimerForCampaign(), landed
    // here, scored the campaign 0 because `restrictions` was invisible to
    // this code, and the rotation concluded there was nothing to play --
    // tearing down the very screen the render path had just approved. That
    // is the "published with a restriction, player says No Content" report.
    //
    // Restrictions are checked here in the same order the render side uses,
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
      'mqtt_view_model.dart:_durationForCampaignAt',
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
      // The current campaign is outside its window. _updateIndexForCampain
      // scans for a replacement and is itself bounded, so this hands over
      // once and does not come back -- unlike the old arrangement, where
      // that function ended by calling this one again and the pair spun
      // synchronously whenever nothing was eligible.
      print("Campaign not in schedule, skipping timer setup.");
      _updateIndexForCampain();
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

    // Bounded scan (at most `count` candidates) for the next campaign that
    // is BOTH unpaused AND currently schedule-eligible (a positive
    // duration). This used to check only "not paused" here and then rely on
    // startPlaylistTimerForCampaign() calling straight back into this
    // function whenever the chosen candidate turned out to be
    // schedule-ineligible (duration <= 0).
    //
    // That recursion had no bound. With every campaign outside its window
    // -- or none ever eligible -- the two functions called each other
    // synchronously round the whole rotation, forever: enough to starve the
    // event loop or overflow the stack outright, with the screen frozen on
    // whatever it last painted. Folding both checks into one bounded loop
    // means this always returns after at most `count` iterations, never
    // recurses into itself, and parks on a recheck timer when nothing
    // qualifies instead of spinning.
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
      // Nothing is both unpaused and inside its window right now. A
      // restriction window can open on its own with no new content ever
      // being published, so recheck later rather than leaving this
      // permanently stuck -- but never by immediately recursing.
      debugPrint(
          'MQTT_LOGS:: _updateIndexForCampain: no playable+eligible campaign right now. Rechecking in 30s.');
      // This line silently tears down an actively-rendering campaign
      // screen, and only ever announced itself through debugPrint --
      // invisible in a release build, so "No Content" appeared with no
      // reason for it recorded anywhere.
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

    Map<String, dynamic> sendLog = {
      "action": "player_logs",
      "log": "Current Campaign",
      "name": (_currentIndexOfCapmaign < count)
          ? (playableCampaigns[_currentIndexOfCapmaign].campaignName ?? "")
          : "",
      "type": "info",
      "date_time": DateTime.now().toIso8601String(),
    };

    _mqttClientService.publish(topic, jsonEncode(sendLog));

    // Puts the screen back. The ineligible branch above parks the player on
    // MqttState.noContent when every campaign is outside its window, and
    // nothing here ever undid it -- so once a restriction window closed the
    // player stayed on "No Content Available for Playback" even after a
    // later recheck found a campaign eligible again and rotated to it.
    //
    // Only noContent is overridden: downloading and the pairing states are
    // set deliberately elsewhere and must not be clobbered by a rotation
    // tick.
    if (_state == MqttState.noContent) {
      _debugLog('_updateIndexForCampain: campaign eligible again '
          '-> leaving noContent for campaignScreen');
      _state = MqttState.campaignScreen;
    }

    notifyListeners();
    // Armed directly from the duration the bounded scan above already
    // confirmed is positive for this index, rather than calling
    // startPlaylistTimerForCampaign() -- which would re-derive it and, if
    // it came back <= 0, call straight back into this function. That is the
    // recursion the scan exists to eliminate.
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
    DateTime currentTime = DateTime.now();
    DateTime fromTime = DateTime.now().copyWith(
      hour: int.parse(timeFrom.split(':')[0]),
      minute: int.parse(timeFrom.split(':')[1]),
    );

    DateTime toTime = DateTime.now().copyWith(
      hour: int.parse(timeTo.split(':')[0]),
      minute: int.parse(timeTo.split(':')[1]),
    );

    return currentTime.isAfter(fromTime) && currentTime.isBefore(toTime);
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

  int get currentDuration {
    final currentPlaylist = playListModel!.data.playlist[_currentIndex];
    final playlistSchedule = currentPlaylist.playlistSchedule;

    int duration = 2;

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
      duration = int.parse(currentPlaylist.playlistDefault!.duration);
    }

    // Log the state
    print(
        "Current Index: $_currentIndex, Duration: $duration seconds, Always Play: ${playlistSchedule.alwaysPlay}");

    return duration;
  }

  void startPlaylistTimer() {
    _timer?.cancel();
    print("this is duration$currentDuration");
    // If the duration is 0, directly update the index and skip the timer setup
    if (currentDuration == 2) {
      _updateIndex();
      print("Playlist item not in schedule, skipping timer setup.");
    } else {
      // Only start the timer if the duration is greater than 0
      _timer = Timer(Duration(seconds: currentDuration), _updateIndex);
    }
  }

  void _updateIndex() {
    _currentIndex = (_currentIndex + 1) % playListModel!.data.playlist.length;
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
    startPlaylistTimer();
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
    _remoteViewTimer?.cancel();
    _pairingRevalidationTimer?.cancel();
    _networkRecoveryTimer?.cancel();
    _pairingPollingTimer?.cancel();
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
    DateTime currentTime = DateTime.now();
    DateTime fromTime = DateTime.now().copyWith(
      hour: int.parse(timeFrom.split(':')[0]),
      minute: int.parse(timeFrom.split(':')[1]),
      second: int.parse(timeFrom.split(':')[2]),
    );

    DateTime toTime = DateTime.now().copyWith(
        hour: int.parse(timeTo.split(':')[0]),
        minute: int.parse(timeTo.split(':')[1]),
        second: int.parse(timeFrom.split(':')[2]));

    return currentTime.isAfter(fromTime) && currentTime.isBefore(toTime);
  }

  /// Check if restrictions allow the campaign/media to play
  /// Whether this campaign/media may play right now.
  ///
  /// The CMS can produce six restriction types, each with its own operator
  /// set (see the backend's CampaignRestrictionTypeEnum):
  ///
  ///   date        is-between | is-before | is-after | on | not-on
  ///   time        is-between | is-before | is-after | on | not-on
  ///   location    is-inside | is-not-inside | is-inside-any | is-not-inside-any
  ///   player_tag  is | contains | empty | not-empty
  ///   player_name is | contains | empty | not-empty
  ///   player_os   is | is-not | contains | not-contains | empty | not-empty
  ///
  /// Only date and time were implemented. Everything else fell through to a
  /// branch that marked the restriction passed, so location, tag, name and
  /// OS rules were not merely broken -- they were silently ignored, and
  /// content played on every device regardless of what was configured.
  ///
  /// Restrictions also carry a logic_operator joining each to the previous
  /// one, which was never read: every set was evaluated as a flat AND, so an
  /// OR condition withheld content it should have played.
  bool checkRestrictions(List<Restriction>? restrictions) {
    if (restrictions == null || restrictions.isEmpty) {
      _debugLog('checkRestrictions: none provided -> allowed');
      return true;
    }

    final now = DateTime.now();

    // AND binds tighter than OR, the usual reading: A AND B OR C is
    // (A AND B) OR C. Consecutive AND-joined restrictions form a group, each
    // OR starts a new one, and playback is allowed if any group passes. The
    // first restriction's operator is ignored -- nothing precedes it.
    final groups = <List<Restriction>>[];
    var current = <Restriction>[];
    for (var i = 0; i < restrictions.length; i++) {
      final joinsWithOr = i > 0 &&
          (restrictions[i].logicOperator ?? 'AND').toUpperCase() == 'OR';
      if (joinsWithOr) {
        groups.add(current);
        current = <Restriction>[];
      }
      current.add(restrictions[i]);
    }
    groups.add(current);

    var allowed = false;
    final trace = <String>[];
    for (final group in groups) {
      var groupPasses = true;
      for (final restriction in group) {
        final pass = _evaluateRestriction(restriction, now);
        trace.add('${restriction.type}/${restriction.operator}/'
            '${restriction.values} -> ${pass ? "PASS" : "FAIL"}');
        if (!pass) {
          groupPasses = false;
          break;
        }
      }
      if (groupPasses) {
        allowed = true;
        break;
      }
    }

    _debugLog('checkRestrictions: ${trace.join(" | ")} '
        '-> $allowed (groups=${groups.length})');
    return allowed;
  }

  /// One restriction, independent of how it joins to its neighbours.
  ///
  /// Returns true for anything it cannot evaluate -- an unknown type, or a
  /// device attribute the backend never sent. Failing OPEN is deliberate: a
  /// rule the player does not understand must not be able to blank an entire
  /// fleet at once, which is far worse on signage than showing content that
  /// should have been withheld. Every such case is logged.
  bool _evaluateRestriction(Restriction restriction, DateTime now) {
    if (restriction.type == null || restriction.operator == null) {
      _debugLog('checkRestrictions: malformed restriction '
          '(type=${restriction.type} operator=${restriction.operator}) -> pass');
      return true;
    }

    switch (restriction.type) {
      case "date":
        return _checkDateRestriction(restriction, now);
      case "time":
        return _checkTimeRestriction(restriction, now);
      case "location":
        return _checkLocationRestriction(restriction);
      case "player_tag":
        return _checkTextRestriction(
            restriction, _devicePlayerTags, 'player_tag');
      case "player_name":
        return _checkTextRestriction(
            restriction, _devicePlayerName, 'player_name');
      case "player_os":
        // Platform.operatingSystem is "linux" here and "windows" on the
        // Windows build, which is exactly what the CMS's player_os values
        // are matched against -- no platform special-casing needed.
        return _checkTextRestriction(
            restriction, [Platform.operatingSystem], 'player_os');
      default:
        _debugLog("checkRestrictions: unknown type '${restriction.type}' "
            "-> pass (not evaluated)");
        return true;
    }
  }

  // -- Device attributes the non-date/time restrictions test against --
  List<String> _devicePlayerTags = const [];
  List<String> _devicePlayerName = const [];
  String? _deviceLocationName;

  /// Pulls the attributes restrictions are evaluated against out of the
  /// stored pairing response.
  void _captureRestrictionContext(Map<String, dynamic> response) {
    try {
      final data = response['data'];
      if (data is Map) {
        _devicePlayerTags = [
          ..._asStringList(data['tags']),
          ..._asStringList(data['playerGroups']),
        ];
        final name = data['name'];
        _devicePlayerName =
            (name is String && name.trim().isNotEmpty) ? [name] : const [];
        final location = data['locationName'];
        _deviceLocationName = (location is String && location.trim().isNotEmpty)
            ? location
            : null;
      }
      final settings = response['settings'];
      if (settings is Map) {
        final lat = settings['latitude'];
        final lon = settings['longitude'];
        if (lat is num && lon is num && !(lat == 0 && lon == 0)) {
          devicesinfo['latitude'] = lat.toDouble();
          devicesinfo['longitude'] = lon.toDouble();
        }
      }
      _debugLog('restriction context: tags=$_devicePlayerTags '
          'name=$_devicePlayerName location=$_deviceLocationName '
          'os=${Platform.operatingSystem}');
    } catch (error) {
      _debugLog('restriction context capture failed: $error');
    }
  }

  /// Adopts the device tags that arrive alongside a published campaign.
  ///
  /// The backend resolves this device's tags and attaches them to the
  /// campaign as player_tags. That -- not the pairing response -- is where
  /// they actually arrive.
  void _adoptPlayerTagsFromCampaigns(List<Campaign>? campaigns) {
    if (campaigns == null || campaigns.isEmpty) return;
    final fromCampaigns = <String>{};
    for (final campaign in campaigns) {
      for (final tag in campaign.playerTags ?? const <String>[]) {
        if (tag.trim().isNotEmpty) fromCampaigns.add(tag.trim());
      }
    }
    if (fromCampaigns.isEmpty) return;
    final merged = <String>{..._devicePlayerTags, ...fromCampaigns}.toList();
    if (merged.length != _devicePlayerTags.length) {
      _devicePlayerTags = merged;
      _debugLog('player tags from campaign payload: $fromCampaigns '
          '-> device tags now $_devicePlayerTags');
    }
  }

  /// Tolerates a bare string as well as a list.
  List<String> _asStringList(dynamic value) {
    if (value == null) return const [];
    if (value is List) {
      return value
          .map((e) => e is Map
              ? (e['name'] ?? e['title'] ?? '').toString()
              : e.toString())
          .where((e) => e.trim().isNotEmpty)
          .toList();
    }
    if (value is String) {
      return value
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }

  /// player_tag, player_name and player_os:
  /// is | is-not | contains | not-contains | empty | not-empty.
  ///
  /// A positive operator passes when ANY of the device's values match, so
  /// "tag is lobby" behaves as expected on a device tagged lobby AND retail.
  bool _checkTextRestriction(
      Restriction restriction, List<String> deviceValues, String label) {
    final operator = _normalizeRestrictionOperator(restriction.operator);
    final wanted = (restriction.values ?? const [])
        .map((v) => v.trim().toLowerCase())
        .where((v) => v.isNotEmpty)
        .toList();
    final have = deviceValues
        .map((v) => v.trim().toLowerCase())
        .where((v) => v.isNotEmpty)
        .toList();

    switch (operator) {
      case 'empty':
        return have.isEmpty;
      case 'not-empty':
        return have.isNotEmpty;
      case 'is':
        if (wanted.isEmpty) return true;
        return have.any(wanted.contains);
      case 'is-not':
        if (wanted.isEmpty) return true;
        return !have.any(wanted.contains);
      case 'contains':
        if (wanted.isEmpty) return true;
        return have.any((h) => wanted.any((w) => h.contains(w)));
      case 'not-contains':
        if (wanted.isEmpty) return true;
        return !have.any((h) => wanted.any((w) => h.contains(w)));
      default:
        _debugLog("checkRestrictions: $label has no handler for operator "
            "'$operator' -> pass (not evaluated)");
        return true;
    }
  }

  /// location: is-inside | is-not-inside | is-inside-any | is-not-inside-any.
  ///
  /// Matches the location NAME assigned to the player, or coordinates with a
  /// radius (third value, default 500 m) when the values parse as lat/long.
  bool _checkLocationRestriction(Restriction restriction) {
    final operator = _normalizeRestrictionOperator(restriction.operator);
    final values = restriction.values ?? const <String>[];
    final negated =
        operator == 'is-not-inside' || operator == 'is-not-inside-any';

    final coords = _tryParseCoordinates(values);
    if (coords != null) {
      final lat = devicesinfo['latitude'];
      final lon = devicesinfo['longitude'];
      if (lat is! num || lon is! num || (lat == 0 && lon == 0)) {
        _debugLog('checkRestrictions: location rule needs coordinates this '
            'device has not reported -> pass (not evaluated)');
        return true;
      }
      final metres =
          _metresBetween(lat.toDouble(), lon.toDouble(), coords[0], coords[1]);
      final inside = metres <= coords[2];
      _debugLog('checkRestrictions: location ${metres.round()}m from target, '
          'radius ${coords[2].round()}m -> inside=$inside');
      return negated ? !inside : inside;
    }

    if (_deviceLocationName == null) {
      _debugLog('checkRestrictions: no location assigned to this player '
          '-> pass (not evaluated)');
      return true;
    }
    final have = _deviceLocationName!.trim().toLowerCase();
    final wanted = values
        .map((v) => v.trim().toLowerCase())
        .where((v) => v.isNotEmpty)
        .toList();
    if (wanted.isEmpty) return true;
    final inside = wanted.contains(have);
    return negated ? !inside : inside;
  }

  /// [lat, lon, radiusMetres] when the values look like coordinates.
  List<double>? _tryParseCoordinates(List<String> values) {
    if (values.length < 2) return null;
    final lat = double.tryParse(values[0].trim());
    final lon = double.tryParse(values[1].trim());
    if (lat == null || lon == null) return null;
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    final radius =
        values.length > 2 ? (double.tryParse(values[2].trim()) ?? 500.0) : 500.0;
    return <double>[lat, lon, radius];
  }

  /// Great-circle distance in metres (haversine).
  double _metresBetween(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000.0;
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * earthRadius * math.asin(math.min(1.0, math.sqrt(a)));
  }

  double _toRadians(double degrees) => degrees * math.pi / 180.0;

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
            final result = (currentTime.isAfter(startTime) ||
                    currentTime.isAtSameMomentAs(startTime)) &&
                (currentTime.isBefore(endTime) ||
                    currentTime.isAtSameMomentAs(endTime));
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
      // location
      case 'isinside':
        return 'is-inside';
      case 'isnotinside':
        return 'is-not-inside';
      case 'isinsideany':
        return 'is-inside-any';
      case 'isnotinsideany':
        return 'is-not-inside-any';
      // player_tag / player_name / player_os
      case 'is':
        return 'is';
      case 'isnot':
        return 'is-not';
      case 'contains':
        return 'contains';
      case 'notcontains':
      case 'doesnotcontain':
        return 'not-contains';
      case 'empty':
      case 'isempty':
        return 'empty';
      case 'notempty':
      case 'isnotempty':
        return 'not-empty';
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
