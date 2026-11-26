package com.allelejeans.allele_collect

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import java.io.File

/**
 * Step 0 device profiler. Every probe is independent and wrapped so that one
 * failing probe reports itself in `probeErrors` instead of failing the profile.
 * All lengths are millimetres, all memory values bytes.
 */
class HardwareProfiler(private val context: Context) {

    companion object {
        const val CHANNEL = "com.allele.photogrammetry/hardware_intrinsics"
        private const val ARCORE_PACKAGE = "com.google.ar.core"
    }

    private val probeErrors = mutableListOf<String>()

    fun capabilities(): Map<String, Any?> {
        probeErrors.clear()
        val lenses = probe("cameras") { cameras() } ?: emptyList()
        val hasDepthCamera = lenses.any { it["supportsDepthOutput"] == true }
        return mapOf(
            "platform" to "android",
            "device" to probe("device") { device() },
            "lenses" to lenses,
            "hasLidarToF" to hasDepthCamera,
            "arCore" to probe("arcore") { arCore() },
            "memory" to probe("memory") { memory() },
            "cpu" to probe("cpu") { cpu() },
            "gpu" to probe("gpu") { gpu() },
            "sensors" to probe("sensors") { sensors() },
            "thermal" to probe("thermal") { thermal() },
            "battery" to probe("battery") { battery() },
            "probeErrors" to probeErrors.toList(),
        )
    }

    /** Cheap snapshot polled by the resource governor during compute. */
    fun runtimeStatus(): Map<String, Any?> {
        probeErrors.clear()
        return mapOf(
            "memory" to probe("memory") { memory() },
            "thermal" to probe("thermal") { thermal() },
            "battery" to probe("battery") { battery() },
            "probeErrors" to probeErrors.toList(),
        )
    }

    private fun <T> probe(name: String, block: () -> T): T? = try {
        block()
    } catch (e: Throwable) {
        probeErrors.add("$name: ${e.javaClass.simpleName}: ${e.message}")
        null
    }

    private fun device(): Map<String, Any?> {
        val info = mutableMapOf<String, Any?>(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "hardware" to Build.HARDWARE,
            "osVersion" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            info["socManufacturer"] = Build.SOC_MANUFACTURER
            info["socModel"] = Build.SOC_MODEL
        }
        return info
    }

    private fun cameras(): List<Map<String, Any?>> {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        return manager.cameraIdList.map { id ->
            val c = manager.getCameraCharacteristics(id)
            val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toList() ?: emptyList()
            val sensorSize = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
            val pixelArray = c.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
            val focals = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.toList() ?: emptyList()
            val facing = when (c.get(CameraCharacteristics.LENS_FACING)) {
                CameraMetadata.LENS_FACING_BACK -> "back"
                CameraMetadata.LENS_FACING_FRONT -> "front"
                CameraMetadata.LENS_FACING_EXTERNAL -> "external"
                else -> "unknown"
            }
            val level = when (c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
                CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "legacy"
                CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
                CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "full"
                CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "level3"
                CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "external"
                else -> "unknown"
            }
            val lens = mutableMapOf<String, Any?>(
                "cameraId" to id,
                "facing" to facing,
                "hardwareLevel" to level,
                "focalLengthsMm" to focals.map { it.toDouble() },
                "focalLength" to focals.firstOrNull()?.toDouble(),
                "sensorWidth" to sensorSize?.width?.toDouble(),
                "sensorHeight" to sensorSize?.height?.toDouble(),
                "pixelArrayWidth" to pixelArray?.width,
                "pixelArrayHeight" to pixelArray?.height,
                "sensorOrientationDeg" to c.get(CameraCharacteristics.SENSOR_ORIENTATION),
                "supportsDepthOutput" to caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT),
                "supportsRaw" to caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_RAW),
                "supportsManualSensor" to caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR),
                "supportsBurstCapture" to caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_BURST_CAPTURE),
                "isLogicalMultiCamera" to caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA),
            )
            // supportsDepth kept for older Dart readers.
            lens["supportsDepth"] = lens["supportsDepthOutput"]
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                // [fx, fy, cx, cy, s] in pixels of the pre-correction active array.
                lens["intrinsicCalibration"] =
                    c.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)?.map { it.toDouble() }
                // [k1, k2, k3, p1, p2] radial/tangential distortion.
                lens["distortion"] = c.get(CameraCharacteristics.LENS_DISTORTION)?.map { it.toDouble() }
                lens["physicalCameraIds"] = c.physicalCameraIds.toList()
            }
            lens
        }
    }

    private fun arCore(): Map<String, Any?> {
        // Install check only; avoids pulling the ARCore SDK in for profiling.
        val installed = try {
            context.packageManager.getPackageInfo(ARCORE_PACKAGE, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
        return mapOf("installed" to installed)
    }

    private fun memory(): Map<String, Any?> {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        return mapOf(
            "totalBytes" to info.totalMem,
            "availableBytes" to info.availMem,
            "lowMemoryThresholdBytes" to info.threshold,
            "isLowMemory" to info.lowMemory,
            "appHeapLimitMb" to am.memoryClass,
            "appLargeHeapLimitMb" to am.largeMemoryClass,
            "isLowRamDevice" to am.isLowRamDevice,
        )
    }

    private fun cpu(): Map<String, Any?> {
        val cores = Runtime.getRuntime().availableProcessors()
        val maxFreqsKhz = (0 until cores).map { i ->
            try {
                File("/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq").readText().trim().toLong()
            } catch (_: Exception) {
                null
            }
        }
        return mapOf("cores" to cores, "maxFrequenciesKhz" to maxFreqsKhz)
    }

    private fun gpu(): Map<String, Any?> {
        val pm = context.packageManager
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return mapOf(
            "glEsVersion" to am.deviceConfigurationInfo.glEsVersion,
            "vulkanCompute" to pm.hasSystemFeature(PackageManager.FEATURE_VULKAN_HARDWARE_COMPUTE),
            "vulkanLevel" to pm.hasSystemFeature(PackageManager.FEATURE_VULKAN_HARDWARE_LEVEL),
        )
    }

    private fun sensors(): Map<String, Any?> {
        val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        fun has(type: Int) = sm.getDefaultSensor(type) != null
        return mapOf(
            "accelerometer" to has(Sensor.TYPE_ACCELEROMETER),
            "gyroscope" to has(Sensor.TYPE_GYROSCOPE),
            "gravity" to has(Sensor.TYPE_GRAVITY),
            "magnetometer" to has(Sensor.TYPE_MAGNETIC_FIELD),
            "rotationVector" to has(Sensor.TYPE_ROTATION_VECTOR),
        )
    }

    private fun thermal(): Map<String, Any?> {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val out = mutableMapOf<String, Any?>("supported" to false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            out["supported"] = true
            // 0 none, 1 light, 2 moderate, 3 severe, 4 critical, 5 emergency, 6 shutdown.
            out["status"] = pm.currentThermalStatus
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // 1.0 == throttling point; NaN when unsupported.
            val headroom = pm.getThermalHeadroom(10)
            out["headroom10s"] = if (headroom.isNaN()) null else headroom.toDouble()
        }
        out["powerSaveMode"] = pm.isPowerSaveMode
        return out
    }

    private fun battery(): Map<String, Any?> {
        val intent: Intent? = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        return mapOf(
            "percent" to if (level >= 0 && scale > 0) level * 100.0 / scale else null,
            "isCharging" to (status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL),
        )
    }
}
