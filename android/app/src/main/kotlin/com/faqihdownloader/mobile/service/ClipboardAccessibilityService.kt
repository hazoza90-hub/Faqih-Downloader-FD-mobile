package com.faqihdownloader.mobile.service

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent

/**
 * Lightweight privacy-respecting AccessibilityService (canRetrieveWindowContent=false)
 * that notices explicit Copy-Link button clicks or copy Toast notifications in external
 * apps and triggers a quiet notification without stealing focus.
 */
class ClipboardAccessibilityService : AccessibilityService() {
    companion object {
        private const val COOLDOWN_MS = 1800L
        private const val TRIGGER_DELAY_MS = 180L
        private val CLICK_KEYWORDS = listOf("copy", "نسخ", "رابط", "link")
        private val TOAST_KEYWORDS = listOf("copied", "clipboard", "تم النسخ", "تم نسخ", "الحافظة")
    }

    private val handler = Handler(Looper.getMainLooper())
    private var lastTriggerElapsedMs = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName?.toString().orEmpty()
        if (pkg.isEmpty() || pkg == applicationContext.packageName) return

        val enabled = getSharedPreferences(
            ClipboardCaptureActivity.PREFS_NAME,
            Context.MODE_PRIVATE,
        ).getBoolean(ClipboardCaptureActivity.KEY_AUTO_ENABLED, false)
        if (!enabled) return

        val now = SystemClock.elapsedRealtime()
        if (now - lastTriggerElapsedMs < COOLDOWN_MS) return

        val textParts = ArrayList<String>(event.text.size + 1)
        event.contentDescription?.toString()?.let { if (it.isNotBlank()) textParts.add(it) }
        for (cs in event.text) {
            val str = cs?.toString().orEmpty()
            if (str.isNotBlank()) textParts.add(str)
        }
        val combined = textParts.joinToString(" ").lowercase()
        if (combined.isBlank()) return

        val matched = when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> CLICK_KEYWORDS.any { combined.contains(it) }
            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED ->
                TOAST_KEYWORDS.any { combined.contains(it) }
            else -> false
        }
        if (!matched) return

        lastTriggerElapsedMs = now
        handler.postDelayed({
            val captureIntent = Intent(this, ClipboardCaptureActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION
                putExtra(ClipboardCaptureActivity.EXTRA_SILENT_NOTIFY, true)
            }
            runCatching { startActivity(captureIntent) }
        }, TRIGGER_DELAY_MS)
    }

    override fun onInterrupt() {
        handler.removeCallbacksAndMessages(null)
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
