import 'dart:io';

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

  void _onKey(RawKeyEvent event) {
    if (event is RawKeyDownEvent) {
      // Kiosk/signage player: runs borderless and covering the whole
      // monitor at all times (see win32_window.cpp's Create -- there's no
      // title bar or maximize button to click, ever), so Escape is the only
      // way to get it out of the way without touching the mouse. Minimizing
      // rather than restoring to a windowed frame matches "get this off my
      // screen for a second", not "let me resize it".
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _minimizeWindow();
      }
      print("Key pressed: ${event.logicalKey.debugName}");
    }
  }

  void _minimizeWindow() {
    if (!Platform.isWindows) return;
    try {
      // GetForegroundWindow always resolves to the top-level window even
      // though actual keyboard focus sits on the hosted Flutter child HWND
      // (child windows can't be "foreground" in Win32), so this reliably
      // targets our own window without needing to look it up by class name.
      final hwnd = win32.GetForegroundWindow();
      if (hwnd != 0) {
        win32.ShowWindow(hwnd, win32.SW_MINIMIZE);
      }
    } catch (_) {}
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
