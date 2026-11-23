package com.faqihdownloader.mobile.service

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.ImageView
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.faqihdownloader.mobile.R
import kotlin.math.abs

class FloatingCaptureService : Service() {
    companion object {
        const val CHANNEL_ID = "fd_floating_capture_channel"
        const val NOTIFICATION_ID = 4301
        const val ACTION_START = "com.faqihdownloader.mobile.capture.START"
        const val ACTION_STOP = "com.faqihdownloader.mobile.capture.STOP"
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_BODY = "extra_body"
        const val EXTRA_CAPTURE_LABEL = "extra_capture_label"
        const val EXTRA_STOP_LABEL = "extra_stop_label"
        const val EXTRA_EMPTY_CLIPBOARD_MSG = "extra_empty_clipboard_msg"

        @Volatile
        var isRunning: Boolean = false
    }

    private var windowManager: WindowManager? = null
    private var bubbleView: ImageView? = null
    private var emptyClipboardMsg: String = "No valid URL found in clipboard"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null || intent.action == ACTION_STOP) {
            stopServiceAndBubble()
            return START_NOT_STICKY
        }

        val title = intent.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }
            ?: "Faqih Downloader"
        val body = intent.getStringExtra(EXTRA_BODY)?.takeIf { it.isNotBlank() }
            ?: "Tap to capture copied link"
        val captureLabel = intent.getStringExtra(EXTRA_CAPTURE_LABEL)?.takeIf { it.isNotBlank() }
            ?: "Capture from Clipboard"
        val stopLabel = intent.getStringExtra(EXTRA_STOP_LABEL)?.takeIf { it.isNotBlank() }
            ?: "Stop"
        emptyClipboardMsg = intent.getStringExtra(EXTRA_EMPTY_CLIPBOARD_MSG)?.takeIf { it.isNotBlank() }
            ?: emptyClipboardMsg

        ensureChannel()
        val notification = buildNotification(title, body, captureLabel, stopLabel)
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        attachBubbleIfPermitted(captureLabel)
        isRunning = true
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        removeBubble()
        isRunning = false
        super.onDestroy()
    }

    private fun stopServiceAndBubble() {
        isRunning = false
        removeBubble()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Quick Link Capture",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { setShowBadge(false) },
            )
        }
    }

    private fun buildNotification(
        title: String,
        body: String,
        captureLabel: String,
        stopLabel: String,
    ): Notification {
        val captureIntent = Intent(this, ClipboardCaptureActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(ClipboardCaptureActivity.EXTRA_EMPTY_CLIPBOARD_MSG, emptyClipboardMsg)
        }
        val capturePending = PendingIntent.getActivity(
            this,
            31,
            captureIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopPending = PendingIntent.getService(
            this,
            32,
            Intent(this, FloatingCaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(capturePending)
            .addAction(0, captureLabel, capturePending)
            .addAction(0, stopLabel, stopPending)
            .build()
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun attachBubbleIfPermitted(captureLabel: String) {
        if (bubbleView != null) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            return
        }
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        windowManager = wm
        val density = resources.displayMetrics.density
        val sizePx = (52 * density).toInt()
        val padPx = (4 * density).toInt()

        val icon = ImageView(this).apply {
            setImageResource(R.mipmap.ic_launcher_round)
            contentDescription = captureLabel
            setPadding(padPx, padPx, padPx, padPx)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#EE121826"))
                setStroke((2 * density).toInt(), Color.parseColor("#FF3B82F6"))
            }
            outlineProvider = ViewOutlineProvider.BACKGROUND
            clipToOutline = true
            elevation = 10f
        }

        val overlayType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            sizePx,
            sizePx,
            overlayType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = (16 * density).toInt()
            y = (220 * density).toInt()
        }

        val touchSlop = ViewConfiguration.get(this)
            .scaledTouchSlop
            .coerceAtLeast((12 * density).toInt())
        var startX = 0
        var startY = 0
        var touchX = 0f
        var touchY = 0f
        icon.setOnTouchListener { _, ev ->
            when (ev.action) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x
                    startY = params.y
                    touchX = ev.rawX
                    touchY = ev.rawY
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    params.x = startX + (ev.rawX - touchX).toInt()
                    params.y = startY + (ev.rawY - touchY).toInt()
                    runCatching { wm.updateViewLayout(icon, params) }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (abs(ev.rawX - touchX) < touchSlop && abs(ev.rawY - touchY) < touchSlop) {
                        val cap = Intent(this, ClipboardCaptureActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                            putExtra(
                                ClipboardCaptureActivity.EXTRA_EMPTY_CLIPBOARD_MSG,
                                emptyClipboardMsg,
                            )
                        }
                        startActivity(cap)
                    }
                    true
                }
                else -> false
            }
        }

        runCatching {
            wm.addView(icon, params)
            bubbleView = icon
        }
    }

    private fun removeBubble() {
        val view = bubbleView ?: return
        bubbleView = null
        runCatching { windowManager?.removeView(view) }
    }
}
