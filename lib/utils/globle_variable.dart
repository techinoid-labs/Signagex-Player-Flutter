import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String globleTopic="";
const platformMacOS = MethodChannel('com.example/deviceControl');
const platform = MethodChannel('com.example/network');
final GlobalKey boundaryKey = GlobalKey();

// Player Configuration settings pushed via the "action_setup_player" MQTT
// message (settings.screen_rotation / touch_feedback /
// hide_no_campaign_messages) -- confirmed field names against the working
// Android player's Setting model. Held as globals (matching the existing
// boundaryKey/globleTopic pattern in this file) since they need to be read
// from widgets far apart in the tree (main.dart's root wrapper, the no-
// content screen, every screen that shows touch feedback).
final ValueNotifier<int> screenRotationDegrees = ValueNotifier<int>(0);
final ValueNotifier<bool> touchFeedbackEnabled = ValueNotifier<bool>(false);
final ValueNotifier<bool> hideNoCampaignMessages = ValueNotifier<bool>(false);