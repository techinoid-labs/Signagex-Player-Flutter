import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MqttClientService {
  late MqttServerClient _client;

  MqttClientService(String broker, int port) {
    _client = MqttServerClient(broker, 'uniqueClientID_${DateTime.now().millisecondsSinceEpoch}');
    _client.port = port;
    _client.keepAlivePeriod = 20;

    _client.onConnected = () {
      print('MQTT client connected');
    };

    _client.onDisconnected = () {
      print('MQTT client disconnected');
    };

    _client.onSubscribed = (String topic) {
      print('Successfully subscribed to topic: $topic');
    };
  }

  Future<void> connect() async {
    try {
      await _client.connect();
      print('MQTT client connected');
    } catch (e) {
      print('Exception during connect: $e');
      _client.disconnect();
    }
  }

  void disconnect() {
    _client.disconnect();
    print('MQTT client disconnected');
  }

  void subscribe(String topic, MqttQos qos) {
    try {
      _client.subscribe(topic, qos);
      print('Subscribed to topic: $topic with QoS: $qos');
    } catch (e) {
      print('Exception during subscribe: $e');
    }
  }

  void publish(String topic, String message, MqttQos qos) {
    try {
      final builder = MqttClientPayloadBuilder();
      builder.addString(message);
      _client.publishMessage(topic, qos, builder.payload!);
      print('Published message to topic: $topic with QoS: $qos');
    } catch (e) {
      print('Exception during publish: $e');
    }
  }

  MqttServerClient get client => _client;
}
