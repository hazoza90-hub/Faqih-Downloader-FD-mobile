package com.faqihdownloader.mobile.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.faqihdownloader.mobile.MainActivity

class DownloadForegroundService : Service() {

    companion object {
        const val CHANNEL_DOWNLOADS = "fd_downloads_channel"
        const val CHANNEL_COMPLETED = "fd_completed_channel"
        const val NOTIFICATION_ID = 4101
        const val COMPLETED_NOTIFICATION_BASE_ID = 4200

        const val ACTION_START = "com.faqihdownloader.mobile.action.START"
        const val ACTION_UPDATE = "com.faqihdownloader.mobile.action.UPDATE"
        const val ACTION_STOP = "com.faqihdownloader.mobile.action.STOP"
        const val ACTION_PAUSE_ALL = "com.faqihdownloader.mobile.action.PAUSE_ALL"
        const val ACTION_CANCEL_ALL = "com.faqihdownloader.mobile.action.CANCEL_ALL"

        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_BODY = "extra_body"
        const val EXTRA_PROGRESS = "extra_progress"
        const val EXTRA_INDETERMINATE = "extra_indeterminate"
        const val EXTRA_PAUSE_LABEL = "extra_pause_label"
        const val EXTRA_CANCEL_LABEL = "extra_cancel_label"

        const val DEFAULT_PAUSE_LABEL = "Pause All"
        const val DEFAULT_CANCEL_LABEL = "Cancel All"

        @Volatile
        var isRunning: Boolean = false

        @Volatile
        var actionListener: ((String) -> Unit)? = null

        private var completedCounter = 0

        fun updateProgressIfRunning(
            context: Context,
            title: String,
            body: String,
            progress: Int,
            indeterminate: Boolean,
            pauseLabel: String = DEFAULT_PAUSE_LABEL,
            cancelLabel: String = DEFAULT_CANCEL_LABEL,
        ): Boolean {
            if (!isRunning) return false
            ensureChannels(context)
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(
                NOTIFICATION_ID,
                buildProgressNotification(
                    context = context,
                    title = title,
                    body = body,
                    progress = progress,
                    indeterminate = indeterminate,
                    pauseLabel = pauseLabel,
                    cancelLabel = cancelLabel,
                ),
            )
            return true
        }

        fun buildProgressNotification(
            context: Context,
            title: String,
            body: String,
            progress: Int,
            indeterminate: Boolean,
            pauseLabel: String = DEFAULT_PAUSE_LABEL,
            cancelLabel: String = DEFAULT_CANCEL_LABEL,
        ): Notification {
            val openPending = PendingIntent.getActivity(
                context,
                10,
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val pausePending = PendingIntent.getService(
                context,
                11,
                Intent(context, DownloadForegroundService::class.java).setAction(ACTION_PAUSE_ALL),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val cancelPending = PendingIntent.getService(
                context,
                12,
                Intent(context, DownloadForegroundService::class.java).setAction(ACTION_CANCEL_ALL),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

            return NotificationCompat.Builder(context, CHANNEL_DOWNLOADS)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(body)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(openPending)
                .setProgress(100, progress.coerceIn(0, 100), indeterminate)
                .addAction(0, pauseLabel.ifBlank { DEFAULT_PAUSE_LABEL }, pausePending)
                .addAction(0, cancelLabel.ifBlank { DEFAULT_CANCEL_LABEL }, cancelPending)
                .build()
        }

        fun showCompleted(context: Context, title: String, body: String) {
            ensureChannels(context)
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val openIntent = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = NotificationCompat.Builder(context, CHANNEL_COMPLETED)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .setContentIntent(openIntent)
                .build()
            val id = COMPLETED_NOTIFICATION_BASE_ID + ((completedCounter++) % 100)
            manager.notify(id, notification)
        }

        fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_DOWNLOADS) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_DOWNLOADS,
                        "Active Downloads",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply { setShowBadge(false) },
                )
            }
            if (manager.getNotificationChannel(CHANNEL_COMPLETED) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_COMPLETED,
                        "Completed Downloads",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ),
                )
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                acquireLocks()
                val notification = buildProgressNotification(
                    context = this,
                    title = intent.getStringExtra(EXTRA_TITLE) ?: "Faqih Downloader",
                    body = intent.getStringExtra(EXTRA_BODY) ?: "Downloading...",
                    progress = intent.getIntExtra(EXTRA_PROGRESS, 0),
                    indeterminate = intent.getBooleanExtra(EXTRA_INDETERMINATE, true),
                    pauseLabel = intent.getStringExtra(EXTRA_PAUSE_LABEL) ?: DEFAULT_PAUSE_LABEL,
                    cancelLabel = intent.getStringExtra(EXTRA_CANCEL_LABEL) ?: DEFAULT_CANCEL_LABEL,
                )
                ServiceCompat.startForeground(
                    this,
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
                isRunning = true
            }
            ACTION_UPDATE -> {
                val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.notify(
                    NOTIFICATION_ID,
                    buildProgressNotification(
                        context = this,
                        title = intent.getStringExtra(EXTRA_TITLE) ?: "Faqih Downloader",
                        body = intent.getStringExtra(EXTRA_BODY) ?: "Downloading...",
                        progress = intent.getIntExtra(EXTRA_PROGRESS, 0),
                        indeterminate = intent.getBooleanExtra(EXTRA_INDETERMINATE, false),
                        pauseLabel = intent.getStringExtra(EXTRA_PAUSE_LABEL) ?: DEFAULT_PAUSE_LABEL,
                        cancelLabel = intent.getStringExtra(EXTRA_CANCEL_LABEL) ?: DEFAULT_CANCEL_LABEL,
                    ),
                )
            }
            ACTION_PAUSE_ALL -> actionListener?.invoke("pause_all")
            ACTION_CANCEL_ALL -> actionListener?.invoke("cancel_all")
            ACTION_STOP -> {
                isRunning = false
                releaseLocks()
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        releaseLocks()
        super.onDestroy()
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "FaqihDownloader::DownloadWakeLock",
            ).apply { setReferenceCounted(false) }
        }
        if (wakeLock?.isHeld == false) {
            wakeLock?.acquire(60 * 60 * 1000L)
        }

        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = wm.createWifiLock(mode, "FaqihDownloader::DownloadWifiLock").apply {
                setReferenceCounted(false)
            }
        }
        if (wifiLock?.isHeld == false) {
            wifiLock?.acquire()
        }
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Throwable) {}
        wakeLock = null
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Throwable) {}
        wifiLock = null
    }
}
