package com.faqihdownloader.mobile.service

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import androidx.core.app.NotificationCompat
import com.faqihdownloader.mobile.MainActivity

/**
 * Transparent short-lived activity that gains brief focus so Android 10-15 allows
 * reading the clipboard outside the app: either routes immediately (Quick Tile / Bubble)
 * or posts a quiet notification in background silent mode.
 */
class ClipboardCaptureActivity : Activity() {
    companion object {
        const val EXTRA_EMPTY_CLIPBOARD_MSG = "extra_empty_clipboard_msg"
        const val EXTRA_SILENT_NOTIFY = "extra_silent_notify"
        const val PREFS_NAME = "fd_bg_capture_prefs"
        const val KEY_AUTO_ENABLED = "auto_sniffer_enabled"
        const val KEY_NOTIF_TITLE = "notif_title"
        const val KEY_NOTIF_ACTION = "notif_action_label"
        const val KEY_LAST_SILENT_URL = "last_silent_url"
        const val SILENT_CHANNEL_ID = "fd_silent_capture_channel"
        const val SILENT_NOTIFICATION_ID = 4350
        private val URL_REGEX = Regex("https?://\\S+", RegexOption.IGNORE_CASE)
    }

    private val safetyHandler = Handler(Looper.getMainLooper())
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val silentMode = intent.getBooleanExtra(EXTRA_SILENT_NOTIFY, false)
        safetyHandler.postDelayed({
            if (!handled) {
                handled = true
                processClipboardAndFinish()
            }
        }, if (silentMode) 350L else 700L)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || handled) return
        handled = true
        safetyHandler.removeCallbacksAndMessages(null)
        processClipboardAndFinish()
    }

    override fun onDestroy() {
        safetyHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun processClipboardAndFinish() {
        val silentMode = intent.getBooleanExtra(EXTRA_SILENT_NOTIFY, false)
        val raw = runCatching {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString()?.trim().orEmpty()
        }.getOrDefault("")

        val matches = URL_REGEX.findAll(raw)
            .map { it.value.trimEnd('.', ',', ';', ':', '!', '?', ')', ']', '}', '"', '\'') }
            .filter { it.isNotEmpty() }
            .toList()

        if (silentMode) {
            val firstUrl = matches.firstOrNull()
            if (firstUrl != null) {
                handleSilentCapture(firstUrl)
            }
        } else {
            val payload = if (matches.isNotEmpty()) matches.joinToString("\n") else ""
            if (payload.isNotEmpty()) {
                startActivity(buildLaunchIntent(payload))
            } else {
                val emptyMsg = intent.getStringExtra(EXTRA_EMPTY_CLIPBOARD_MSG)
                    ?.takeIf { it.isNotBlank() }
                    ?: "No valid URL found in clipboard"
                Toast.makeText(applicationContext, emptyMsg, Toast.LENGTH_SHORT).show()
            }
        }

        finish()
        if (Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    private fun handleSilentCapture(url: String) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (prefs.getString(KEY_LAST_SILENT_URL, "") == url) return
        if (!isPlatformAllowed(url, prefs)) return
        prefs.edit().putString(KEY_LAST_SILENT_URL, url).apply()
        postSilentNotification(url, prefs)
    }

    private fun isPlatformAllowed(url: String, prefs: SharedPreferences): Boolean {
        val lower = url.lowercase()
        val key = when {
            lower.contains("youtube.com/") || lower.contains("youtu.be/") -> "allow_youtube"
            lower.contains("tiktok.com/") -> "allow_tiktok"
            lower.contains("instagram.com/") || lower.contains("instagr.am/") -> "allow_instagram"
            lower.contains("facebook.com/") || lower.contains("fb.watch/") -> "allow_facebook"
            lower.contains("twitter.com/") || lower.contains("x.com/") -> "allow_twitter"
            else -> "allow_direct"
        }
        return prefs.getBoolean(key, true)
    }

    private fun postSilentNotification(url: String, prefs: SharedPreferences) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(SILENT_CHANNEL_ID) == null
        ) {
            manager.createNotificationChannel(
                NotificationChannel(
                    SILENT_CHANNEL_ID,
                    "Silent Auto Link Capture",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    setSound(null, null)
                    enableVibration(false)
                },
            )
        }

        val title = prefs.getString(KEY_NOTIF_TITLE, null)?.takeIf { it.isNotBlank() }
            ?: "Link Ready to Download"
        val actionLabel = prefs.getString(KEY_NOTIF_ACTION, null)?.takeIf { it.isNotBlank() }
            ?: "Download Now"
        val openPending = PendingIntent.getActivity(
            this,
            51,
            buildLaunchIntent(url),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, SILENT_CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(url)
            .setStyle(NotificationCompat.BigTextStyle().bigText(url))
            .setSilent(true)
            .setAutoCancel(true)
            .setContentIntent(openPending)
            .addAction(0, actionLabel, openPending)
            .build()
        runCatching { manager.notify(SILENT_NOTIFICATION_ID, notification) }
    }

    private fun buildLaunchIntent(payload: String): Intent =
        Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_SEND
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, payload)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
}
