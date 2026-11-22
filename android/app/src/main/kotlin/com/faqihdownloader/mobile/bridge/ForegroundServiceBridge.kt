package com.faqihdownloader.mobile.bridge

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.faqihdownloader.mobile.service.DownloadForegroundService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ForegroundServiceBridge(private val appContext: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "com.faqihdownloader.mobile/foreground_service"
        const val EVENT_CHANNEL = "com.faqihdownloader.mobile/service_events"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@ForegroundServiceBridge)
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).apply {
            setStreamHandler(this@ForegroundServiceBridge)
        }
        DownloadForegroundService.actionListener = { action ->
            mainHandler.post {
                eventSink?.success(mapOf("action" to action))
            }
        }
    }

    fun dispose() {
        DownloadForegroundService.actionListener = null
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        eventSink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startService" -> {
                val intent = Intent(appContext, DownloadForegroundService::class.java).apply {
                    action = DownloadForegroundService.ACTION_START
                    putExtra(DownloadForegroundService.EXTRA_TITLE, call.argument<String>("title") ?: "Faqih Downloader")
                    putExtra(DownloadForegroundService.EXTRA_BODY, call.argument<String>("body") ?: "Downloading...")
                    putExtra(DownloadForegroundService.EXTRA_PROGRESS, call.argument<Number>("progress")?.toInt() ?: 0)
                    putExtra(DownloadForegroundService.EXTRA_INDETERMINATE, call.argument<Boolean>("indeterminate") ?: true)
                    call.argument<String>("pauseLabel")?.let {
                        putExtra(DownloadForegroundService.EXTRA_PAUSE_LABEL, it)
                    }
                    call.argument<String>("cancelLabel")?.let {
                        putExtra(DownloadForegroundService.EXTRA_CANCEL_LABEL, it)
                    }
                }
                try {
                    ContextCompat.startForegroundService(appContext, intent)
                    result.success(true)
                } catch (t: Throwable) {
                    result.error("FGS_START_ERROR", t.message ?: t.javaClass.simpleName, null)
                }
            }
            "updateProgress" -> {
                val updated = DownloadForegroundService.updateProgressIfRunning(
                    context = appContext,
                    title = call.argument<String>("title") ?: "Faqih Downloader",
                    body = call.argument<String>("body") ?: "Downloading...",
                    progress = call.argument<Number>("progress")?.toInt() ?: 0,
                    indeterminate = call.argument<Boolean>("indeterminate") ?: false,
                    pauseLabel = call.argument<String>("pauseLabel")
                        ?: DownloadForegroundService.DEFAULT_PAUSE_LABEL,
                    cancelLabel = call.argument<String>("cancelLabel")
                        ?: DownloadForegroundService.DEFAULT_CANCEL_LABEL,
                )
                result.success(updated)
            }
            "showCompletedNotification" -> {
                val title = call.argument<String>("title") ?: "Download Complete"
                val body = call.argument<String>("body") ?: ""
                DownloadForegroundService.showCompleted(appContext, title, body)
                result.success(true)
            }
            "stopService" -> {
                appContext.stopService(Intent(appContext, DownloadForegroundService::class.java))
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }
}
