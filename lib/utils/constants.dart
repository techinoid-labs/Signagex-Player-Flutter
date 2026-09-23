import 'dart:io';

// NOTE: these two are dead. The MQTT client declares its own
// mqttBroker/mqttPort at the top of lib/services/mqtt_client_service.dart
// (signagexai.com:443) and never reads these. Left alone rather than
// deleted in this change, but nothing should start using them.
const String mqttBroker = 'broker';
const int mqttPort = 1883;

/// Which backend this build talks to.
///
/// Set by the build: `--dart-define=APP_ENV=staging` produces a staging
/// player, and anything else (including no define at all) produces a
/// production one.
const String appEnv =
    String.fromEnvironment('APP_ENV', defaultValue: 'production');

const bool isStagingBuild = appEnv == 'staging';

/// Was hardcoded to the staging host, unconditionally.
///
/// That made every Linux build a staging build, including the artifact the
/// pipeline labels "production" -- the CI already passes
/// --dart-define=APP_ENV=staging to one of the two builds, and nothing read
/// it. A player built as production still registered itself against
/// stage.signagexai.com, so its pairing code existed only on the staging
/// CMS and the production CMS answered, correctly, that the code was not
/// found.
const String baseurl = isStagingBuild
    ? "https://stage.signagexai.com/v1/"
    : "https://signagexai.com/v1/";
const String adCampaignProofOfPlayPath = "player/ad-campaign-proof-of-play";
const String port = "3002/";


bool isIos = Platform.isIOS;
bool isMac = Platform.isMacOS;
Map<String, dynamic> deviceInfoMap = {
  if (!isIos || !isMac) ...{
    "mac_address": {
      "macAddress": [
        {"interface": "", "mac": ""},
        {"interface": "", "mac": ""}
      ],
      "platform": ""
    },
  },
  if (isIos || isMac) ...{"platform": "", "uuid": ""},
  "sender": "",
  "android_version": "",
  "webview_version": "",
  "last_seen": "",
  "device_model": "",
  "network_name": "",
  "time_zone": "",
  "last_ip_address": "",
  "latitude": 0.0,
  "longitude": 0.0,
  "cpu_information": {
    "cpu_architecture": "",
    "processor": "",
    "count_cores": 0
  },
  "memory_information": {
    "total_memory": 0,
    "available_memory": 0,
    "used_memory": 0
  },
  "battery_information": {
    "battery_percentage": 0,
    "formatted_voltage": 0,
    "formated_tempature": 0.0
  },
  "cpu_usage": 0.0,
  "cpu_detailed_information": {
    "cpu_detailed_information": [
      {
        "processor": "",
        "BogoMIPS": "",
        "Features": "",
        "CPU_implementer": "",
        "CPU_architecture": "",
        "CPU_variant": "",
        "CPU_part": "",
        "CPU_revision": ""
      }
    ]
  },
  "hardware_details": {
    "brand": "",
    "device_id": "",
    "model": "",
    "id": "",
    "sdk": 0,
    "manufacturer": "",
    "user": "",
    "type": "",
    "base": 0,
    "incremental": "",
    "board": "",
    "host": "",
    "fingerprint": "",
    "version_code": "",
    "hard_drive": "",
    "ram": ""
  },
  "storage_info": {"total_storage": "", "available_storage": ""},
  "ram_info": "",
  "device_resolution": {"resolution": "", "density": 0},
  "camera_details": ""
};
