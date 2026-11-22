package com.faqihdownloader.mobile.bridge

import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ShareIntentBridge : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "com.faqihdownloader.mobile/share_intent"
        const val EVENT_CHANNEL = "com.faqihdownloader.mobile/share_events"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    @Volatile
    private var eventSink: EventChannel.EventSink? = null
    private var initialSharedText: String? = null
    private var pendingWarmText: String? = null

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@ShareIntentBridge)
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).apply {
            setStreamHandler(this@ShareIntentBridge)
        }
    }

    fun dispose() {
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
            else -> result.notImplemented()
        }
    }

    private fun extractSharedText(intent: Intent?): String? {
        if (intent == null) return null
        if (intent.action != Intent.ACTION_SEND) return null
        val type = intent.type ?: return null
        if (!type.startsWith("text/")) return null
        val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
        if (!sharedText.isNullOrEmpty()) return sharedText
        val sharedSubject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.trim()
        return if (sharedSubject.isNullOrEmpty()) null else sharedSubject
    }
}
