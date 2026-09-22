import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../services/mqtt_client_service.dart';
import '../utils/debug_log.dart' as debug;
import '../view_models/mqtt_view_model.dart';
import '../view_models/system_apply_settings_vm.dart';
import '../views/campaign_view.dart';
import '../views/connecting_view.dart';
import '../views/digivision_view.dart';
import '../views/downloading_screen.dart';
import '../views/no_content_view.dart';
import '../views/no_internet_view.dart';
import '../views/play_list_view.dart';
import '../views/player_stopped_view.dart';

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
      print("Key pressed: ${event.logicalKey.debugName}");
    }
  }

  // Which screen is showing is the single most useful thing to know when a
  // player is reported stuck, and print() reaches nobody in a release
  // build. Logged on change only, not on every call -- this runs on every
  // notifyListeners(), and logging each one would bury the log in
  // duplicates for a screen that never changed.
  MqttState? _lastLoggedState;
  Widget _getScreenForState(MqttState state) {
    if (state != _lastLoggedState) {
      debug.debugLog('MqttProvider', 'state -> $state (was $_lastLoggedState)');
      _lastLoggedState = state;
    }
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
      case MqttState.playerStopped:
        return const PlayerStoppedView();
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
