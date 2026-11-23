package com.faqihdownloader.mobile.bridge

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.faqihdownloader.mobile.service.FloatingCaptureService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class FloatingCaptureBridge(private val appContext: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val METHOD_CHANNEL = "com.faqihdownloader.mobile/floating_capture"
    }

    private var methodChannel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@FloatingCaptureBridge)
        }
    }

    fun dispose() {
        methodChannel?.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canDrawOverlays" -> {
                val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                    Settings.canDrawOverlays(appContext)
                result.success(allowed)
            }
            "requestOverlayPermission" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${appContext.packageName}"),
                    ).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
                    appContext.startActivity(intent)
                }
                result.success(true)
            }
            "startFloatingCapture" -> {
                val intent = Intent(appContext, FloatingCaptureService::class.java).apply {
                    action = FloatingCaptureService.ACTION_START
                    putExtra(FloatingCaptureService.EXTRA_TITLE, call.argument<String>("title"))
                    putExtra(FloatingCaptureService.EXTRA_BODY, call.argument<String>("body"))
                    putExtra(FloatingCaptureService.EXTRA_CAPTURE_LABEL, call.argument<String>("captureLabel"))
                    putExtra(FloatingCaptureService.EXTRA_STOP_LABEL, call.argument<String>("stopLabel"))
                    putExtra(FloatingCaptureService.EXTRA_EMPTY_CLIPBOARD_MSG, call.argument<String>("emptyClipboardMsg"))
                }
                ContextCompat.startForegroundService(appContext, intent)
                result.success(true)
            }
            "stopFloatingCapture" -> {
                appContext.stopService(Intent(appContext, FloatingCaptureService::class.java))
                result.success(true)
            }
            "isRunning" -> result.success(FloatingCaptureService.isRunning)
            else -> result.notImplemented()
        }
    }
}
