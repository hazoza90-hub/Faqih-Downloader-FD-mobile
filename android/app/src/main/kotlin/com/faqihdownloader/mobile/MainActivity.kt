package com.faqihdownloader.mobile

import android.content.Intent
import com.faqihdownloader.mobile.bridge.ForegroundServiceBridge
import com.faqihdownloader.mobile.bridge.MediaStoreBridge
import com.faqihdownloader.mobile.bridge.ShareIntentBridge
import com.faqihdownloader.mobile.bridge.YoutubeDlBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var youtubeDlBridge: YoutubeDlBridge? = null
    private var foregroundServiceBridge: ForegroundServiceBridge? = null
    private var shareIntentBridge: ShareIntentBridge? = null
    private var mediaStoreBridge: MediaStoreBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        youtubeDlBridge = YoutubeDlBridge(applicationContext).apply { attach(messenger) }
        foregroundServiceBridge = ForegroundServiceBridge(applicationContext).apply { attach(messenger) }
        shareIntentBridge = ShareIntentBridge().apply {
            attach(messenger)
            captureInitialIntent(intent)
        }
        mediaStoreBridge = MediaStoreBridge(applicationContext).apply { attach(messenger) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        shareIntentBridge?.handleIntent(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        youtubeDlBridge?.dispose()
        foregroundServiceBridge?.dispose()
        shareIntentBridge?.dispose()
        mediaStoreBridge?.dispose()
        youtubeDlBridge = null
        foregroundServiceBridge = null
        shareIntentBridge = null
        mediaStoreBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
