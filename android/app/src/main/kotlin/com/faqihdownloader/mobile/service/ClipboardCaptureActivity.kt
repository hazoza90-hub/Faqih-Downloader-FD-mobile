package com.faqihdownloader.mobile.service

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import com.faqihdownloader.mobile.MainActivity

/**
 * Transparent short-lived activity that gains focus for 100ms so Android 10-15
 * permits reading clipboard text outside the app, forwards it to MainActivity,
 * and closes cleanly.
 */
class ClipboardCaptureActivity : Activity() {
    companion object {
        const val EXTRA_EMPTY_CLIPBOARD_MSG = "extra_empty_clipboard_msg"
        private val URL_REGEX = Regex("https?://\\S+", RegexOption.IGNORE_CASE)
    }

    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || handled) return
        handled = true
        processClipboardAndFinish()
    }

    private fun processClipboardAndFinish() {
        val raw = runCatching {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString()?.trim().orEmpty()
        }.getOrDefault("")

        val matches = URL_REGEX.findAll(raw).map { it.value }.toList()
        val payload = if (matches.isNotEmpty()) matches.joinToString("\n") else ""

        if (payload.isNotEmpty()) {
            val launch = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_SEND
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, payload)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            startActivity(launch)
        } else {
            val emptyMsg = intent.getStringExtra(EXTRA_EMPTY_CLIPBOARD_MSG)
                ?.takeIf { it.isNotBlank() }
                ?: "No valid URL found in clipboard"
            Toast.makeText(applicationContext, emptyMsg, Toast.LENGTH_SHORT).show()
        }

        finish()
        if (Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }
}
