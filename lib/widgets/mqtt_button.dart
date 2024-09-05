// import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

// import 'package:digital_signage/provider/main_provider.dart';

// import '../view_models/mqtt_view_model.dart';

// class MqttButtons extends StatelessWidget {
//   final MqttProvider mqttProvider;

//   MqttButtons({required this.mqttProvider});
//   Map<String, dynamic> body = {
//     "success": "true",
//     "action": 'jvjhjgvfj',
//     "paired": "false",
//     "player_code": "playerCode",
//     "mac_address": "macAddressArray",
//     "sender": 'norwinsol_web'
//   };
//   @override
//   Widget build(BuildContext context) {
//     return Column(
//       children: [
//         ElevatedButton(
//           onPressed: () {
//             mqttProvider.subscribe('qasim');
//           },
//           child: Text('Subscribe'),
//         ),
//         ElevatedButton(
//           onPressed: () {
//             mqttProvider.publish('qasim', jsonEncode(body));
//           },
//           child: Text('Publish'),
//         ),
//         ElevatedButton(
//           onPressed: () {
//             mqttProvider.disconnect();
//           },
//           child: Text('Disconnect'),
//         ),
//         ElevatedButton(
//           onPressed: () {
//             mqttProvider.connect(); // Connect or reconnect
//           },
//           child: Text('Connect'),
//         ),
//       ],
//     );
//   }
// }
