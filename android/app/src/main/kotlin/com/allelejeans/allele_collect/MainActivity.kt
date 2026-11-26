package com.allelejeans.allele_collect

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val profiler = HardwareProfiler(applicationContext)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            HardwareProfiler.CHANNEL,
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getHardwareCapabilities" -> result.success(profiler.capabilities())
                    "getRuntimeStatus" -> result.success(profiler.runtimeStatus())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("HARDWARE_PROFILE_FAILED", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }
}
