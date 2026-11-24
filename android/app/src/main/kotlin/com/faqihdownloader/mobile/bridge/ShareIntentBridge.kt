package com.faqihdownloader.mobile.bridge

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ShareIntentBridge(
    private val appContext: Context,
    private val activityProvider: () -> Activity? = { null },
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "com.faqihdownloader.mobile/share_intent"
        const val EVENT_CHANNEL = "com.faqihdownloader.mobile/share_events"
        private val URL_REGEX = Regex("https?://\\S+", RegexOption.IGNORE_CASE)

        @Volatile
        var activeInstance: ShareIntentBridge? = null
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    @Volatile
    private var eventSink: EventChannel.EventSink? = null
    private var initialSharedText: String? = null
    private var pendingWarmText: String? = null

    fun attach(messenger: BinaryMessenger) {
        activeInstance = this
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@ShareIntentBridge)
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).apply {
            setStreamHandler(this@ShareIntentBridge)
        }
    }

    fun dispose() {
        if (activeInstance === this) activeInstance = null
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        eventSink = null
        pendingWarmText = null
    }

    fun captureInitialIntent(intent: Intent?) {
        val text = extractSharedText(intent) ?: return
        initialSharedText = text
    }

    fun handleIntent(intent: Intent?) {
        val text = extractSharedText(intent) ?: return
        deliverText(text)
    }

    fun deliverText(rawText: String) {
        val text = rawText.trim()
        if (text.isEmpty() || !URL_REGEX.containsMatchIn(text)) return
        val sink = eventSink
        if (sink != null) {
            mainHandler.post { sink.success(text) }
        } else {
            pendingWarmText = text
            if (initialSharedText == null) {
                initialSharedText = text
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val pending = pendingWarmText
        if (pending != null && events != null) {
            pendingWarmText = null
            mainHandler.post { events.success(pending) }
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "consumeInitialSharedText" -> {
                val text = initialSharedText
                initialSharedText = null
                result.success(text)
            }
            "moveTaskToBack" -> {
                val moved = runCatching {
                    activityProvider()?.moveTaskToBack(true) ?: false
                }.getOrDefault(false)
                result.success(moved)
            }
            else -> result.notImplemented()
        }
    }

    private fun extractSharedText(intent: Intent?): String? {
        if (intent == null) return null
        if (intent.action == Intent.ACTION_PROCESS_TEXT) {
            val selected = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
                ?.toString()?.trim()
            return if (!selected.isNullOrEmpty() && URL_REGEX.containsMatchIn(selected)) selected else null
        }
        if (intent.action != Intent.ACTION_SEND) return null
        val type = intent.type?.lowercase() ?: return null
        if (!type.startsWith("text/")) return null

        val extraText = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim()
        if (!extraText.isNullOrEmpty() && URL_REGEX.containsMatchIn(extraText)) return extraText

        val extraSubject = intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString()?.trim()
        if (!extraSubject.isNullOrEmpty() && URL_REGEX.containsMatchIn(extraSubject)) return extraSubject

        val clipText = runCatching {
            val clip = intent.clipData
            if (clip != null && clip.itemCount > 0) {
                clip.getItemAt(0).coerceToText(appContext)?.toString()?.trim()
            } else null
        }.getOrNull()
        return if (!clipText.isNullOrEmpty() && URL_REGEX.containsMatchIn(clipText)) clipText else null
    }
}
