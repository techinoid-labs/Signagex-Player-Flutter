package com.example.digital_signage

import android.content.Context
import android.net.wifi.WifiManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example/network"

    override fun configureFlutterEngine(@NonNull flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getWifiMacAddress" -> {
                    val wifiMac = getWifiMacAddress()
                    if (wifiMac != null) {
                        result.success(wifiMac)
                    } else {
                        result.error("UNAVAILABLE", "Wi-Fi MAC address not available", null)
                    }
                }
                "getEthernetMacAddress" -> {
                    val ethernetMac = getEthernetMacAddress()
                    if (ethernetMac != null) {
                        result.success(ethernetMac)
                    } else {
                        result.error("UNAVAILABLE", "Ethernet MAC address not available", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getWifiMacAddress(): String? {
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        return wifiManager.connectionInfo.macAddress
    }

    private fun getEthernetMacAddress(): String? {
        try {
            val networkInterfaces = NetworkInterface.getNetworkInterfaces().toList()
            for (networkInterface in networkInterfaces) {
                if (networkInterface.name.equals("eth0", ignoreCase = true)) {
                    val macBytes = networkInterface.hardwareAddress ?: return null
                    return macBytes.joinToString(":") { String.format("%02X", it) }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return null
    }
}