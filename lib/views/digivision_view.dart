import 'package:flutter/material.dart';

import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:digital_signage/view_models/mqtt_view_model.dart';

class DigivisionView extends StatefulWidget {
  const DigivisionView({super.key});

  @override
  State<DigivisionView> createState() => _DigivisionViewState();
}

class _DigivisionViewState extends State<DigivisionView> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = Provider.of<MqttViewModel>(context, listen: false);
    final topic = viewModel.topic;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SingleChildScrollView(
        child: Container(
          color: Colors.black,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: Colors.black,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset(
                          "assets/images/Logo.png",
                          height: 200,
                          width: 200,
                          color: Colors.white,
                          fit: BoxFit.contain,
                        ),
                      ],
                    ),
                    const SizedBox(height: 48),
                    if (topic.isNotEmpty)
                      Container(
                        color: Colors.black,
                        padding: const EdgeInsets.all(16),
                        child: QrImageView(
                          data: topic,
                          version: QrVersions.auto,
                          backgroundColor: Colors.black,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Colors.white,
                          ),
                          dataModuleStyle: const QrDataModuleStyle(
                            color: Colors.white,
                            dataModuleShape: QrDataModuleShape.square,
                          ),
                          size: 200,
                        ),
                      )
                    else
                      Image.asset(
                        'assets/images/barcode.png',
                        height: 200,
                        width: 200,
                        color: Colors.white,
                        fit: BoxFit.contain,
                      ),
                    const SizedBox(height: 40),
                    Text(
                      topic.isNotEmpty ? topic.toUpperCase() : "------",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 56,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 8,
                      ),
                    ),
                    const SizedBox(height: 48),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        "To get started enter the code above at signagex.com or scan the QR code with your device.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF9E9E9E),
                          fontSize: 15,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
