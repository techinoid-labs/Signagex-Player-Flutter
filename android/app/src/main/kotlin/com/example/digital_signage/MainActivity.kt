package com.example.digital_signage

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.StatFs
import android.provider.Settings
import android.telephony.TelephonyManager
import android.util.Log
import android.view.Display
import android.view.WindowManager
import android.hardware.display.DisplayManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.util.DisplayMetrics
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.FileReader
import java.io.IOException
import java.net.NetworkInterface
import java.util.Locale
import kotlin.math.roundToInt

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
                "getSystemData" -> {
                    log("getSystemData called")
                    val systemData = getSystemData()
                    result.success(systemData.toString())
                }
                "getBatteryPercentage" -> {
                    log("getBatteryPercentage called")
                    val batteryPercentage = getBatteryPercentage()
                    result.success(batteryPercentage)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getBatteryPercentage(): String {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                val batteryManager = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                val batteryPercentage = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).toString() + "%"
                batteryPercentage
            } else {
                // For Android versions below Lollipop, use the deprecated way
                val intent = IntentFilter(Intent.ACTION_BATTERY_CHANGED).let { filter ->
                    applicationContext.registerReceiver(null, filter)
                }
                val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                val batteryPercentage = (level / scale.toFloat() * 100).roundToInt().toString() + "%"
                batteryPercentage
            }
        } catch (e: Exception) {
            log("Error retrieving battery percentage: ${e.message}")
            "Unknown"
        }
    }

    private fun getWifiMacAddress(): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                log("Wi-Fi MAC Address retrieval not allowed on Android 6.0+")
                null
            } else {
                val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
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
            val telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            val identifier = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                telephonyManager.imei ?: telephonyManager.meid
            } else {
                telephonyManager.deviceId
            }
            log("Retrieved Device Identifier: $identifier")
            identifier ?: "Unknown Identifier"
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
                        val macObject = JSONObject().apply {
                            put("interface", interfaceName)
                            put("mac", macAddress)
                        }
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

    private fun getSystemData(): JSONObject {
        val systemData = JSONObject()

        // Collecting System Information
        val androidVersion = Build.VERSION.RELEASE
        val webViewVersion = getWebViewVersion()
        val lastSeen = System.currentTimeMillis()
        val deviceModel = Build.MODEL
        val networkName = getNetworkName()
        val timeZone = java.util.TimeZone.getDefault().id
        val lastIpAddress = getLastIpAddress()
        val cpuInfo = getCpuInformation()
        val memoryInfo = getMemoryInformation()
        val batteryInfo = getBatteryInformation()
        val cpuUsage = getCpuUsage()
        val cpuDetailedInfo = getCpuDetailedInformation()
        val hardwareDetails = getHardwareDetails()
        val storageInfo = getStorageInformation()
        val ramInfo = getRamInformation()
        val deviceResolution = getDeviceResolution()
        val cameraDetails = getCameraDetails()

        // Populating the JSON Object
        systemData.apply {
            put("sender", "android")
            put("android_version", androidVersion)
            put("webview_version", webViewVersion)
            put("last_seen", lastSeen)
            put("device_model", deviceModel)
            put("network_name", networkName)
            put("time_zone", timeZone)
            put("last_ip_address", lastIpAddress)
            put("cpu_information", JSONObject().apply {
                put("cpu_architecture", cpuInfo.first)
                put("processor", cpuInfo.second)
                put("count_cores", cpuInfo.third)
            })
            put("memory_information", JSONObject().apply {
                put("total_memory", memoryInfo.first)
                put("available_memory", memoryInfo.second)
                put("used_memory", memoryInfo.third)
            })
            put("battery_information", JSONObject().apply {
                put("battery_percentage", batteryInfo.first)
                put("formatted_voltage", batteryInfo.second)
                put("formatted_temperature", batteryInfo.third)
            })
            put("cpu_usage", cpuUsage)
            put("cpu_detailed_information", cpuDetailedInfo)
            put("hardware_details", hardwareDetails)
            put("storage_info", JSONObject().apply {
                put("total_storage", storageInfo.first)
                put("available_storage", storageInfo.second)
            })
            put("ram_info", ramInfo)
            put("device_resolution", JSONObject().apply {
                put("width", deviceResolution.first)
                put("height", deviceResolution.second)
            })
            put("camera_details", cameraDetails)
        }

        return systemData
    }

    private fun getWebViewVersion(): String {
        return try {
            val webViewPackageInfo = packageManager.getPackageInfo("com.google.android.webview", 0)
            webViewPackageInfo.versionName
        } catch (e: PackageManager.NameNotFoundException) {
            "WebView version not found"
        }
    }


    private fun getNetworkName(): String {
        return try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val connectionInfo = wifiManager.connectionInfo
            connectionInfo.ssid
        } catch (e: Exception) {
            log("Error retrieving network name: ${e.message}")
            "Unknown"
        }
    }

    private fun getLastIpAddress(): String {
        return try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val connectionInfo = wifiManager.connectionInfo
            connectionInfo.ipAddress.toString()
        } catch (e: Exception) {
            log("Error retrieving IP address: ${e.message}")
            "Unknown"
        }
    }

    private fun getCpuInformation(): Triple<String, String, Int> {
        return try {
            val cpuInfo = File("/proc/cpuinfo").readText()

            // Extracting CPU architecture
            val cpuArchitecture = cpuInfo.lines()
                .firstOrNull { it.startsWith("Hardware") || it.startsWith("CPU architecture") }
                ?.substringAfter(":")
                ?.trim() ?: "Unknown"

            // Extracting Processor name
            val processorName = cpuInfo.lines()
                .firstOrNull { it.startsWith("Processor") || it.startsWith("model name") }
                ?.substringAfter(":")
                ?.trim() ?: "Unknown"

            // Counting the number of cores
            val coreCount = cpuInfo.lines()
                .count { it.startsWith("processor") } // Counts lines that start with "processor"

            Triple(processorName, cpuArchitecture, coreCount)
        } catch (e: Exception) {
            log("Error retrieving CPU information: ${e.message}")
            Triple("Unknown", "Unknown", 0)
        }
    }


    private fun getMemoryInformation(): Triple<String, String, String> {
        return try {
            val memoryInfo = android.app.ActivityManager.MemoryInfo()
            val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            activityManager.getMemoryInfo(memoryInfo)

            val totalMemory = memoryInfo.totalMem.toString()
            val availableMemory = memoryInfo.availMem.toString()
            val usedMemory = (totalMemory.toLong() - availableMemory.toLong()).toString()

            Triple(totalMemory, availableMemory, usedMemory)
        } catch (e: Exception) {
            log("Error retrieving memory information: ${e.message}")
            Triple("Unknown", "Unknown", "Unknown")
        }
    }

    private fun getBatteryInformation(): Triple<String, String, String> {
        return try {
            val batteryIntent = IntentFilter(Intent.ACTION_BATTERY_CHANGED).let { filter ->
                applicationContext.registerReceiver(null, filter)
            }
            val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            val batteryPercentage = (level / scale.toFloat() * 100).roundToInt().toString()

            val voltage = batteryIntent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1)?.toString() ?: "Unknown"
            val temperature = batteryIntent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1)?.toString()?.let { it.toFloat() / 10 } ?: "Unknown"

            Triple(batteryPercentage, voltage, temperature.toString())
        } catch (e: Exception) {
            log("Error retrieving battery information: ${e.message}")
            Triple("Unknown", "Unknown", "Unknown")
        }
    }

    private fun getCpuUsage(): String {
        return try {
            // Retrieve CPU usage from proc/stat
            val cpuUsageFile = File("/proc/stat")
            val cpuStats = cpuUsageFile.readText()
            cpuStats.lines().firstOrNull { it.startsWith("cpu ") }?.substringAfter("cpu ") ?: "Unknown"
        } catch (e: Exception) {
            log("Error retrieving CPU usage: ${e.message}")
            "Unknown"
        }
    }

    private fun getCpuDetailedInformation(): String {
        return try {
            // Retrieve CPU detailed information from /proc/cpuinfo
            val cpuInfo = File("/proc/cpuinfo").readText()
            cpuInfo
        } catch (e: Exception) {
            log("Error retrieving detailed CPU information: ${e.message}")
            "Unknown"
        }
    }

    private fun getHardwareDetails(): String {
        return try {
            // Retrieve hardware details
            val hardwareDetails = Build.HARDWARE
            hardwareDetails
        } catch (e: Exception) {
            log("Error retrieving hardware details: ${e.message}")
            "Unknown"
        }
    }

    private fun getStorageInformation(): Pair<String, String> {
        return try {
            val stat = StatFs(getExternalFilesDir(null)?.absolutePath)
            val totalStorage = (stat.blockCountLong * stat.blockSizeLong / (1024 * 1024)).toString() + " MB"
            val availableStorage = (stat.availableBlocksLong * stat.blockSizeLong / (1024 * 1024)).toString() + " MB"
            Pair(totalStorage, availableStorage)
        } catch (e: Exception) {
            log("Error retrieving storage information: ${e.message}")
            Pair("Unknown", "Unknown")
        }
    }

    private fun getRamInformation(): String {
        return try {
            val memoryInfo = android.app.ActivityManager.MemoryInfo()
            val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            activityManager.getMemoryInfo(memoryInfo)
            (memoryInfo.totalMem / (1024 * 1024)).toString() + " MB"
        } catch (e: Exception) {
            log("Error retrieving RAM information: ${e.message}")
            "Unknown"
        }
    }

    private fun getDeviceResolution(): Pair<Int, Int> {
        return try {
            val displayMetrics = DisplayMetrics()
            val windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            windowManager.defaultDisplay.getRealMetrics(displayMetrics)
            Pair(displayMetrics.widthPixels, displayMetrics.heightPixels)
        } catch (e: Exception) {
            log("Error retrieving device resolution: ${e.message}")
            Pair(0, 0)
        }
    }

    private fun getCameraDetails(): JSONObject {
        val cameraDetails = JSONObject()
        try {
            val cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val cameraIds = cameraManager.cameraIdList
            for (cameraId in cameraIds) {
                val characteristics = cameraManager.getCameraCharacteristics(cameraId)
                val lensFacing = characteristics.get(CameraCharacteristics.LENS_FACING)
                val isFront = lensFacing == CameraCharacteristics.LENS_FACING_FRONT
                cameraDetails.put("camera_id", cameraId)
                cameraDetails.put("lens_facing", if (isFront) "Front" else "Back")
            }
        } catch (e: Exception) {
            log("Error retrieving camera details: ${e.message}")
        }
        return cameraDetails
    }

    @SuppressLint("LogNotTimber")
    private fun log(message: String) {
        Log.d("MainActivity", message)
    }
}
