package com.senin.child

import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.senin.child/apps"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppLabels" -> {
                        @Suppress("UNCHECKED_CAST")
                        val packages = call.arguments as? List<String> ?: emptyList()
                        result.success(resolveLabels(packages))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun resolveLabels(packages: List<String>): Map<String, String> {
        val pm = applicationContext.packageManager
        val out = HashMap<String, String>(packages.size)
        for (pkg in packages) {
            if (pkg.isBlank()) continue
            try {
                val info: ApplicationInfo = if (android.os.Build.VERSION.SDK_INT >= 33) {
                    pm.getApplicationInfo(
                        pkg,
                        PackageManager.ApplicationInfoFlags.of(0),
                    )
                } else {
                    @Suppress("DEPRECATION")
                    pm.getApplicationInfo(pkg, 0)
                }
                val label = pm.getApplicationLabel(info)?.toString()?.trim()
                if (!label.isNullOrEmpty()) {
                    out[pkg] = label
                    continue
                }
            } catch (_: Exception) {
            }
            out[pkg] = humanizePackage(pkg)
        }
        return out
    }

    private fun humanizePackage(pkg: String): String {
        val last = pkg.substringAfterLast('.').ifBlank { pkg }
        if (last.length <= 1) return last
        return last.replaceFirstChar { it.uppercaseChar() }
    }
}
