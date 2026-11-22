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
            initialSharedText = text
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
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
        val shared = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
        return if (shared.isNullOrEmpty()) null else shared
    }
}
