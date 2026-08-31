import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';
import 'package:win32/win32.dart' as win32;

import '../services/mqtt_client_service.dart';
import '../view_models/mqtt_view_model.dart';
import '../view_models/system_apply_settings_vm.dart';
import '../views/campaign_view.dart';
import '../views/connecting_view.dart';
import '../views/digivision_view.dart';
import '../views/downloading_screen.dart';
import '../views/no_content_view.dart';
import '../views/no_internet_view.dart';
import '../views/play_list_view.dart';

class MqttProvider extends StatefulWidget {
  final Widget child;

  const MqttProvider({required this.child, super.key});

  @override
  State<MqttProvider> createState() => _MqttProviderState();
}

class _MqttProviderState extends State<MqttProvider> {
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _onTap(TapUpDetails details) {
    final position = details.localPosition;
    print("Touched at position: $position");
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<MqttViewModel>(
          create: (context) => MqttViewModel(MqttClientService()),
        ),
        ChangeNotifierProvider<DeviceSettingsViewModel>(
          create: (context) => DeviceSettingsViewModel(),
        ),
      ],
      child: Consumer<MqttViewModel>(
        builder: (context, viewModel, child) {
          return RawKeyboardListener(
            focusNode: _focusNode,
            onKey: _onKey,
            child: GestureDetector(
              onTapUp: _onTap,
              child: _getScreenForState(viewModel.state),
            ),
          );
        },
      ),
    );
  }

  // win32_window.cpp's Create() always launches borderless, covering the
  // full monitor -- this tracks that starting state so Escape knows which
  // way to toggle.
  bool _isFullscreen = true;

  void _onKey(RawKeyEvent event) {
    if (event is RawKeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _toggleFullscreen();
      }
      print("Key pressed: ${event.logicalKey.debugName}");
    }
  }

  // Escape toggles between the kiosk borderless-fullscreen window
  // win32_window.cpp launches with and a normal bordered, movable window
  // that stays visible on screen -- not minimized to the taskbar. Pressing
  // Escape again returns to fullscreen. Done Dart-side via win32 FFI
  // (already a dependency here -- see windows_screen_capture.dart) rather
  // than in the native WndProc, since keyboard focus lives on the hosted
  // Flutter child HWND and it's Flutter's own input pipeline, not the
  // native top-level window, that actually delivers key events to this
  // listener regardless of which HWND technically has focus.
  void _toggleFullscreen() {
    if (!Platform.isWindows) return;
    try {
      final hwnd = win32.GetForegroundWindow();
      if (hwnd == 0) return;
      if (_isFullscreen) {
        _exitFullscreen(hwnd);
      } else {
        _enterFullscreen(hwnd);
      }
      _isFullscreen = !_isFullscreen;
    } catch (_) {}
  }

  void _exitFullscreen(int hwnd) {
    win32.SetWindowLongPtr(
        hwnd, win32.GWL_STYLE, win32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE);
    // Centered, reasonably sized windowed frame -- matches the size
    // main.cpp originally requested before this app became kiosk-fullscreen.
    final screenWidth = win32.GetSystemMetrics(win32.SM_CXSCREEN);
    final screenHeight = win32.GetSystemMetrics(win32.SM_CYSCREEN);
    const width = 1280;
    const height = 720;
    final x = ((screenWidth - width) / 2).round();
    final y = ((screenHeight - height) / 2).round();
    win32.SetWindowPos(hwnd, 0, x, y, width, height,
        win32.SWP_FRAMECHANGED | win32.SWP_NOZORDER);
  }

  void _enterFullscreen(int hwnd) {
    win32.SetWindowLongPtr(
        hwnd, win32.GWL_STYLE, win32.WS_POPUP | win32.WS_VISIBLE);
    final monitor =
        win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST);
    final info = calloc<win32.MONITORINFO>();
    try {
      info.ref.cbSize = sizeOf<win32.MONITORINFO>();
      if (win32.GetMonitorInfo(monitor, info) != 0) {
        final rc = info.ref.rcMonitor;
        win32.SetWindowPos(hwnd, 0, rc.left, rc.top, rc.right - rc.left,
            rc.bottom - rc.top, win32.SWP_FRAMECHANGED | win32.SWP_NOZORDER);
      }
    } finally {
      calloc.free(info);
    }
  }

  Widget _getScreenForState(MqttState state) {
    print("State: $state");
    switch (state) {
      case MqttState.initial:
        return const ConnectingView();
      case MqttState.noContent:
        return const NoContentView();
      case MqttState.connectionScreen:
        return const ConnectingView();
      case MqttState.downloading:
        return const DownloadingView();
      case MqttState.noInternet:
        return const NoInternetView();
      case MqttState.campaignScreen:
        return const CampaignView();
      case MqttState.pairedScreen:
        return const DigivisionView();
      case MqttState.playlistScreen:
        return const PlaylistScreen();
      case MqttState.failure:
        return const ConnectingView();
      default:
        return const Scaffold(
          body: Center(child: Text('Unknown State')),
        );
    }
  }
}
