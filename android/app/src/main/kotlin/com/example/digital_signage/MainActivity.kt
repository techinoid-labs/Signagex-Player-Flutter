package com.example.digital_signage

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.FileReader
import java.io.IOException
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example/network"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getWifiMacAddress" -> {
                    log("getWifiMacAddress called")
                    val macAddress = getWifiMacAddress()
                    if (macAddress != null) {
                        result.success(macAddress)
                    } else {
                        result.error("UNAVAILABLE", "Wi-Fi MAC address not available.", null)
                    }
                }
                "getEthernetMacAddress" -> {
                    log("getEthernetMacAddress called")
                    val macAddress = getEthernetMacAddress()
                    if (macAddress != null) {
                        result.success(macAddress)
                    } else {
                        result.error("UNAVAILABLE", "Ethernet MAC address not available.", null)
                    }
                }
                "getDeviceIdentifier" -> {
                    log("getDeviceIdentifier called")
                    val identifier = getDeviceIdentifier()
                    result.success(identifier)
                }
                "getListOfMacAddresses" -> {
                    log("getListOfMacAddresses called")
                    val macAddresses = getListOfMacAddresses()
                    result.success(macAddresses.toString())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getWifiMacAddress(): String? {
        return try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                log("Wi-Fi MAC Address retrieval not allowed on Android 6.0+")
                null
            } else {
                val macAddress = wifiManager.connectionInfo.macAddress
                log("Wi-Fi MAC Address: $macAddress")
                macAddress
            }
        } catch (e: Exception) {
            log("Error retrieving Wi-Fi MAC address: ${e.message}")
            null
        }
    }

    private fun getEthernetMacAddress(): String? {
        return try {
            val networkInterfaces = java.util.Collections.list(java.net.NetworkInterface.getNetworkInterfaces())
            for (networkInterface in networkInterfaces) {
                if (networkInterface.name.equals("eth0", ignoreCase = true)) {
                    val macBytes = networkInterface.hardwareAddress
                    if (macBytes != null) {
                        val macAddress = macBytes.joinToString(":") { String.format("%02x", it) }
                        log("Ethernet MAC Address: $macAddress")
                        return macAddress
                    }
                }
            }
            log("Ethernet MAC Address not available")
            "Not available"
        } catch (e: Exception) {
            log("Error retrieving Ethernet MAC address: ${e.message}")
            null
        }
    }

    private fun getDeviceIdentifier(): String {
        return try {
            val identifier = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
            } else {
                (getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager).deviceId
            }
            log("Retrieved Device Identifier: $identifier")
            identifier
        } catch (e: Exception) {
            log("Error retrieving device identifier: ${e.message}")
            "Unknown Identifier"
        }
    }

    private fun getListOfMacAddresses(): JSONObject {
        val macAddresses = JSONArray()

        try {
            val netDir = File("/sys/class/net")
            val interfaceFiles = netDir.listFiles()

            if (interfaceFiles != null) {
                for (interfaceFile in interfaceFiles) {
                    val interfaceName = interfaceFile.name
                    if (interfaceName.startsWith("wlan") || interfaceName.startsWith("eth0")) {
                        var macAddress = "00:00:00:00:00:00"
                        var br: BufferedReader? = null
                        try {
                            val macFile = File("/sys/class/net/$interfaceName/address")
                            if (macFile.exists()) {
                                br = BufferedReader(FileReader(macFile))
                                macAddress = br.readLine().uppercase(Locale.getDefault())
                            }
                        } catch (e: IOException) {
                            log("Error reading MAC address from file $interfaceName: ${e.message}")
                        } finally {
                            br?.close()
                        }
                        val macObject = JSONObject()
                        macObject.put("interface", interfaceName)
                        macObject.put("mac", macAddress)
                        macAddresses.put(macObject)
                        log("Found MAC address for $interfaceName: $macAddress")
                    }
                }
            }
        } catch (e: Exception) {
            log("Error retrieving list of MAC addresses: ${e.message}")
        }

        val result = JSONObject()
        result.put("macAddress", macAddresses)
        result.put("platform", "android")
        return result
    }

    private fun log(message: String) {
        android.util.Log.d("MainActivity", message)
    }
}
