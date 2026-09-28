import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String globleTopic="";
const platformMacOS = MethodChannel('com.example/deviceControl');
const platform = MethodChannel('com.example/network');
final GlobalKey boundaryKey = GlobalKey();

/// Bumped every time the CMS publishes a campaign, so a web app already on
/// screen knows to fetch itself again.
///
/// Editing a web app's configuration changes what the URL SERVES without
/// changing the URL itself. Nothing downstream could tell the difference:
/// the media id is the same, the URL is the same, so the player kept the
/// webview it already had and went on showing the old configuration until
/// somebody restarted it.
///
/// Deliberately a notifier rather than part of the widget key. Putting it
/// in the key would rebuild the widget, which destroys and recreates the
/// webview -- a blank zone and a fresh page load every time anything is
/// published. The Android player learned the same thing the hard way
/// (SGX-050: deleting the cached file and showing the download screen
/// "destroyed the currently-playing WebView -> blank white screen") and
/// settled on refreshing in place. This does the same: the widget stays,
/// the page reloads under it.
final ValueNotifier<int> webAppRefreshTick = ValueNotifier<int>(0);