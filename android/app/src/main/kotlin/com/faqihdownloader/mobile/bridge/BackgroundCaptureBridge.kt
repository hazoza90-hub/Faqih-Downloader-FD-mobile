package com.faqihdownloader.mobile.bridge

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.faqihdownloader.mobile.R
import com.faqihdownloader.mobile.service.ClipboardAccessibilityService
import com.faqihdownloader.mobile.service.ClipboardCaptureActivity
import com.faqihdownloader.mobile.service.QuickCaptureTileService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

class BackgroundCaptureBridge(private val appContext: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val METHOD_CHANNEL = "com.faqihdownloader.mobile/background_capture"
        private val PLATFORM_KEYS = listOf(
            "youtube",
            "tiktok",
            "instagram",
            "facebook",
            "twitter",
            "direct",
        )
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@BackgroundCaptureBridge)
        }
    }

    fun dispose() {
        methodChannel?.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAccessibilityServiceEnabled" -> result.success(isAccessibilityEnabled())
            "openAccessibilitySettings" -> {
                val ok = runCatching {
                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
                    appContext.startActivity(intent)
                    true
                }.getOrDefault(false)
                result.success(ok)
            }
            "openAppDetailsSettings" -> {
                val ok = runCatching {
                    val intent = Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:${appContext.packageName}"),
                    ).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
                    appContext.startActivity(intent)
                    true
                }.getOrDefault(false)
                result.success(ok)
            }
            "setAutoSnifferConfig" -> {
                saveAutoSnifferConfig(call)
                result.success(true)
            }
            "setQuickTileEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val ok = runCatching {
                    val newState = if (enabled) {
                        PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                    } else {
                        PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                    }
                    appContext.packageManager.setComponentEnabledSetting(
                        ComponentName(appContext, QuickCaptureTileService::class.java),
                        newState,
                        PackageManager.DONT_KILL_APP,
                    )
                    true
                }.getOrDefault(false)
                result.success(ok)
            }
            "requestAddQuickTile" -> {
                val label = call.argument<String>("label")?.takeIf { it.isNotBlank() }
                    ?: "Faqih Capture"
                requestAddQuickTileCompat(label, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun saveAutoSnifferConfig(call: MethodCall) {
        val enabled = call.argument<Boolean>("enabled") ?: false
        val platforms = call.argument<Map<String, Boolean>>("platforms").orEmpty()
        val notifTitle = call.argument<String>("notifTitle").orEmpty()
        val notifActionLabel = call.argument<String>("notifActionLabel").orEmpty()
        val emptyClipboardMsg = call.argument<String>("emptyClipboardMsg").orEmpty()
        val editor = appContext.getSharedPreferences(
            ClipboardCaptureActivity.PREFS_NAME,
            Context.MODE_PRIVATE,
        ).edit()
            .putBoolean(ClipboardCaptureActivity.KEY_AUTO_ENABLED, enabled)
            .putString(ClipboardCaptureActivity.KEY_NOTIF_TITLE, notifTitle)
            .putString(ClipboardCaptureActivity.KEY_NOTIF_ACTION, notifActionLabel)
            .putString(ClipboardCaptureActivity.KEY_EMPTY_CLIPBOARD_MSG, emptyClipboardMsg)
        for (plat in PLATFORM_KEYS) {
            editor.putBoolean("allow_$plat", platforms[plat] ?: true)
        }
        editor.apply()
    }

    private fun isAccessibilityEnabled(): Boolean {
        val accEnabled = Settings.Secure.getInt(
            appContext.contentResolver,
            Settings.Secure.ACCESSIBILITY_ENABLED,
            0,
        )
        if (accEnabled != 1) return false
        val rawServices = Settings.Secure.getString(
            appContext.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        val target = ComponentName(appContext, ClipboardAccessibilityService::class.java)
        val fullName = target.flattenToString().lowercase()
        val shortName = target.flattenToShortString().lowercase()
        return rawServices.split(':').any { item ->
            val clean = item.trim().lowercase()
            clean == fullName || clean == shortName
        }
    }

    private fun requestAddQuickTileCompat(label: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(false)
            return
        }
        val statusBarManager = appContext.getSystemService(StatusBarManager::class.java)
        if (statusBarManager == null) {
            result.success(false)
            return
        }
        val component = ComponentName(appContext, QuickCaptureTileService::class.java)
        val icon = Icon.createWithResource(appContext, R.drawable.ic_qs_capture)
        val replied = AtomicBoolean(false)
        val timeoutRunnable = Runnable {
            if (replied.compareAndSet(false, true)) {
                result.success(false)
            }
        }
        mainHandler.postDelayed(timeoutRunnable, 15_000L)
        val started = runCatching {
            statusBarManager.requestAddTileService(
                component,
                label,
                icon,
                appContext.mainExecutor,
            ) { code ->
                mainHandler.removeCallbacks(timeoutRunnable)
                val ok = code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                    code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED ||
                    code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED
                if (replied.compareAndSet(false, true)) {
                    mainHandler.post { result.success(ok) }
                }
            }
            true
        }.getOrDefault(false)
        if (!started) {
            mainHandler.removeCallbacks(timeoutRunnable)
            if (replied.compareAndSet(false, true)) {
                result.success(false)
            }
        }
    }
}
