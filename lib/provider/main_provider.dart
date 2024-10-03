import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:digital_signage/view_models/system_apply_settings_vm.dart';
import 'package:digital_signage/views/connecting_view.dart';
import 'package:digital_signage/views/digivision_view.dart';
import 'package:digital_signage/views/downloading_screen.dart';
import 'package:digital_signage/views/no_content_view.dart';
import 'package:digital_signage/views/no_internet_view.dart';
import 'package:digital_signage/views/play_list_view.dart';

import '../services/mqtt_client_service.dart';
import '../view_models/mqtt_view_model.dart';

class MqttProvider extends StatelessWidget {
  final Widget child;

  const MqttProvider({required this.child, super.key});

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
          print(viewModel.state);
          switch (viewModel.state) {
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

            case MqttState.pairedScreen:
              return const DigivisionView();
            case MqttState.playlistScreen:
              return PlaylistScreen();

            default:
              return const Scaffold(
                body: Center(child: Text('Unknown State')),
              );
          }
        },
      ),
    );
  }
}
