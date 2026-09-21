import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:digital_signage/view_models/mqtt_view_model.dart';
import 'package:digital_signage/widgets/text_widget.dart';

// PLAYER_STOP_REASON_CONTRACT: shown instead of the pairing/QR code screen
// when the backend responds paired:false + action:"action_stop_player" --
// this player IS paired, it's just been stopped for a licence/subscription/
// account reason. Copy matches the contract doc's suggested text exactly.
// An unrecognised reason (older backend field, or a future value this build
// doesn't know about yet) falls through to _generic instead of crashing.
class PlayerStoppedView extends StatelessWidget {
  const PlayerStoppedView({super.key});

  static const _reasons = <String, ({String title, String message})>{
    'licence_removed': (
      title: "This screen's licence was removed",
      message:
          "Your administrator can restore it from the SignageX dashboard. This screen will resume automatically.",
    ),
    'org_expired': (
      title: "Subscription expired",
      message:
          "This account's subscription has lapsed. Contact your administrator to reactivate. This screen will resume automatically.",
    ),
    'demo_expired': (
      title: "Free trial ended",
      message:
          "This account's trial has finished. Upgrade from the SignageX dashboard to resume. This screen will resume automatically.",
    ),
    'org_inactive': (
      title: "Account suspended",
      message: "Contact your administrator. This screen will resume automatically.",
    ),
    'org_suspended': (
      title: "Playback paused",
      message:
          "This screen's provider account needs attention. Contact your administrator. This screen will resume automatically.",
    ),
  };

  static const _generic = (
    title: "Playback paused",
    message: "This screen has been temporarily stopped. It will resume automatically.",
  );

  @override
  Widget build(BuildContext context) {
    final viewModel = Provider.of<MqttViewModel>(context, listen: false);
    final copy = _reasons[viewModel.stopReason] ?? _generic;
    final playerCode = viewModel.playerCode;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                "assets/images/Logo.png",
                height: 120,
                width: 120,
                color: Colors.white,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 40),
              SimpleText(
                text: copy.title,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
              const SizedBox(height: 16),
              SimpleText(
                text: copy.message,
                fontSize: 15,
              ),
              if (playerCode.isNotEmpty) ...[
                const SizedBox(height: 48),
                Text(
                  playerCode.toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFF6E6E6E),
                    fontSize: 13,
                    letterSpacing: 4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
