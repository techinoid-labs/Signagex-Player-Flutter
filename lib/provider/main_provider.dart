import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

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
  Offset? _lastOffset;

  @override
  void initState() {
    super.initState();

  }

  @override
  void dispose() {
    // Remove listener when widget is disposed
    final mqttViewModel = Provider.of<MqttViewModel>(context, listen: false);
    mqttViewModel.removeListener(_onCoordinateUpdate);
    super.dispose();
  }

  void _onCoordinateUpdate() {
    final mqttViewModel = Provider.of<MqttViewModel>(context, listen: false);
    if (mqttViewModel.x != null && mqttViewModel.y != null) {
      final screenSize = MediaQuery.of(context).size;
      final dx = mqttViewModel.x!.toDouble() * screenSize.width / 100;
      final dy = mqttViewModel.y!.toDouble() * screenSize.height / 100;

      final newOffset = Offset(dx, dy);

      if (_lastOffset != newOffset) {
        _simulateGlobalInteraction(newOffset);
        _lastOffset = newOffset;
      }
    }
  }

  void _simulateGlobalInteraction(Offset offset) {
    final gesture = GestureBinding.instance;

    print("Simulating interaction at position: $offset");

    // Simulate a drag if there's a previous offset
    gesture.handlePointerEvent(PointerDownEvent(position: offset));
    gesture.handlePointerEvent(PointerUpEvent(position: offset));
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
          return _buildScreen(viewModel.state);
        },
      ),
    );
  }

  /// Build screens based on the MQTT state
  Widget _buildScreen(MqttState state) {
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

      default:
        return const Scaffold(
          body: Center(child: Text('Unknown State')),
        );
    }
  }
}
