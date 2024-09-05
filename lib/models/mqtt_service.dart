
// import 'package:mqtt_client/mqtt_client.dart';
// import 'package:mqtt_client/mqtt_server_client.dart';

// class MqttClientService {
//   late MqttServerClient _client;
//   final String broker;
//   final int port;
//   String _receivedMessage = '';

//   MqttClientService(this.broker, this.port) {
//     _initializeClient();
//   }

//   void _initializeClient() {
//     _client = MqttServerClient.withPort(
//       broker,
//       'uniqueClientID_${DateTime.now().millisecondsSinceEpoch}',
//       port,
//     );
//     _client.keepAlivePeriod = 60;
//     _client.setProtocolV311();

//     _client.logging(on: true);

//     _client.onConnected = () {
//       print('MQTT client connected');
//     };

//     _client.onDisconnected = () {
//       print('MQTT client disconnected');
//     };

//     _client.onSubscribed = (String topic) {
//       print('Successfully subscribed to topic: $topic');
//     };

//     _client.onSubscribeFail = (String topic) {
//       print('Failed to subscribe to topic: $topic');
//     };

//     _client.pongCallback = () {
//       print('Ping response received');
//     };

//     _client.updates?.listen(_onMessage);
//   }

//   Future<void> connect() async {
//     final connMessage = MqttConnectMessage()
//         .withWillTopic('willtopic')
//         .withWillMessage('Will message')
//         .startClean()
//         .withWillQos(MqttQos.atLeastOnce);

//     print('Attempting to connect to MQTT broker...');
//     _client.connectionMessage = connMessage;

//     try {
//       await _client.connect();
//       if (_client.connectionStatus!.state == MqttConnectionState.connected) {
//         print('MQTT client connected');
//         subscribe('85a1d2', MqttQos.atMostOnce);
//       } else {
//         print(
//             'MQTT client connection failed - disconnecting, status is ${_client.connectionStatus}');
//         _client.disconnect();
//       }
//     } catch (e) {
//       print('Exception: $e');
//       _client.disconnect();
//     }
//   }

//   void subscribe(String topic, MqttQos qos) {
//     try {
//       print('Subscribing to topic: $topic with QoS: $qos');
//       _client.subscribe(topic, qos);
//     } catch (e) {
//       print('Exception during subscribe: $e');
//     }
//   }

//   void publish(String topic, String message, MqttQos qos) {
//     try {
//       final builder = MqttClientPayloadBuilder();
//       builder.addString(message);
//       _client.publishMessage(topic, qos, builder.payload!);
//       print('Published message to topic: $topic with QoS: $qos...$message');
//     } catch (e) {
//       print('Exception during publish: $e');
//     }
//   }

//   void _onMessage(List<MqttReceivedMessage<MqttMessage?>>? c) {
//     final recMess = c![0].payload as MqttPublishMessage;
//     final pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
//     _receivedMessage = pt;
//     print('New data arrived: topic is <${c[0].topic}>, payload is $pt');
//   }

//   String get receivedMessage => _receivedMessage;

//   void disconnect() {
//     _client.disconnect();
//   }
// }
