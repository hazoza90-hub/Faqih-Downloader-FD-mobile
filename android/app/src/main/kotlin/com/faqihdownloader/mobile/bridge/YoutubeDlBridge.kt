package com.faqihdownloader.mobile.bridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

class YoutubeDlBridge(private val appContext: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "com.faqihdownloader.mobile/youtubedl"
        const val EVENT_CHANNEL = "com.faqihdownloader.mobile/youtubedl_events"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val initLock = Any()
    private val initialized = AtomicBoolean(false)
    private val ffmpegRunner = FfmpegProcessRunner(appContext)

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@YoutubeDlBridge)
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).apply {
            setStreamHandler(this@YoutubeDlBridge)
        }
    }

    fun dispose() {
        ffmpegRunner.cancelAll()
        scope.cancel()
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
            "initialize" -> runAsync(result) {
                ensureInitialized()
                mapOf(
                    "initialized" to true,
                    "ytdlpVersion" to (YoutubeDL.getInstance().version(appContext) ?: "unknown"),
                    "ffmpegReady" to true,
                )
            }
            "updateYoutubeDL" -> runAsync(result) {
                ensureInitialized()
                val status = YoutubeDL.getInstance().updateYoutubeDL(
                    appContext,
                    YoutubeDL.UpdateChannel.STABLE,
                )
                mapOf(
                    "status" to (status?.name ?: "ALREADY_UP_TO_DATE"),
                    "ytdlpVersion" to (YoutubeDL.getInstance().version(appContext) ?: "unknown"),
                )
            }
            "extractInfo" -> handleExtractInfo(call, result)
            "downloadMedia" -> handleDownloadMedia(call, result)
            "runFfmpeg" -> handleRunFfmpeg(call, result)
            "cancelProcess" -> handleCancelProcess(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleExtractInfo(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")?.trim().orEmpty()
        val processId = call.argument<String>("processId")?.trim().orEmpty()
        if (url.isEmpty() || processId.isEmpty()) {
            result.error("INVALID_ARGS", "url and processId are required", null)
            return
        }
        val cookiesFile = call.argument<String>("cookiesFile")
        val userAgent = call.argument<String>("userAgent")
        val headers = call.argument<Map<String, String>>("headers").orEmpty()
        val playlistItems = call.argument<String>("playlistItems")
        val timeoutSeconds = call.argument<Number>("timeoutSeconds")?.toInt()
        val extractorArgs = call.argument<String>("extractorArgs")

        runAsync(result) {
            ensureInitialized()
            val request = YoutubeDLRequest(url)
            request.addOption("--dump-single-json")
            request.addOption("--no-warnings")
            request.addOption("--no-check-certificates")
            val effectiveTimeout = timeoutSeconds?.takeIf { it > 0 } ?: 30
            request.addOption("--socket-timeout", effectiveTimeout.toString())
            applyExtractorArgs(request, url, extractorArgs)
            if (!playlistItems.isNullOrBlank()) {
                request.addOption("--playlist-items", playlistItems.trim())
            } else if (!isYouTubePlaylistUrl(url)) {
                request.addOption("--no-playlist")
            }
            if (!cookiesFile.isNullOrBlank()) {
                request.addOption("--cookies", cookiesFile)
            }
            if (!userAgent.isNullOrBlank()) {
                request.addOption("--user-agent", userAgent)
            }
            for ((k, v) in headers) {
                request.addOption("--add-header", "$k:$v")
            }
            val response = YoutubeDL.getInstance().execute(request, processId, null)
            response.out
        }
    }

    private fun handleDownloadMedia(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")?.trim().orEmpty()
        val processId = call.argument<String>("processId")?.trim().orEmpty()
        if (url.isEmpty() || processId.isEmpty()) {
            result.error("INVALID_ARGS", "url and processId are required", null)
            return
        }
        val args = call.argument<List<String>>("args").orEmpty()
        val options = call.argument<Map<String, Any?>>("options").orEmpty()
        val extractorArgs = call.argument<String>("extractorArgs")

        runAsync(result) {
            ensureInitialized()
            val request = YoutubeDLRequest(url)
            if (!hasFlag(args, options, "--no-check-certificates")) {
                request.addOption("--no-check-certificates")
            }
            if (!hasFlag(args, options, "--socket-timeout")) {
                request.addOption("--socket-timeout", "30")
            }
            if (!hasFlag(args, options, "--extractor-args")) {
                applyExtractorArgs(request, url, extractorArgs)
            }
            var i = 0
            while (i < args.size) {
                val current = args[i]
                if (current.isBlank()) {
                    i++
                    continue
                }
                if (current.startsWith("-") && i + 1 < args.size && !args[i + 1].trimStart().startsWith("-")) {
                    request.addOption(current, args[i + 1])
                    i += 2
                } else {
                    request.addOption(current)
                    i++
                }
            }
            for ((key, value) in options) {
                if (key.isBlank()) continue
                when (value) {
                    is List<*> -> value.forEach { item ->
                        item?.toString()?.takeIf { it.isNotBlank() }?.let { request.addOption(key, it) }
                    }
                    null -> request.addOption(key)
                    is Boolean -> if (value) request.addOption(key)
                    else -> request.addOption(key, value.toString())
                }
            }
            val response = YoutubeDL.getInstance().execute(request, processId) { progress, eta, line ->
                emitEvent(mapOf(
                    "type" to "progress", "processId" to processId,
                    "progress" to progress.toDouble(), "etaSeconds" to eta, "line" to line,
                ))
            }
            mapOf("exitCode" to response.exitCode, "stdout" to response.out, "stderr" to response.err)
        }
    }

    private fun handleRunFfmpeg(call: MethodCall, result: MethodChannel.Result) {
        val processId = call.argument<String>("processId")?.trim().orEmpty()
        val args = call.argument<List<String>>("args")
        if (processId.isEmpty() || args == null) {
            result.error("INVALID_ARGS", "processId and args are required", null)
            return
        }
        runAsync(result) {
            ensureInitialized()
            val res = ffmpegRunner.run(args, processId) { line ->
                emitEvent(mapOf("type" to "ffmpeg_log", "processId" to processId, "line" to line))
            }
            mapOf("exitCode" to res.exitCode, "output" to res.output)
        }
    }

    private fun handleCancelProcess(call: MethodCall, result: MethodChannel.Result) {
        val processId = call.argument<String>("processId")?.trim().orEmpty()
        if (processId.isEmpty()) {
            result.error("INVALID_ARGS", "processId is required", null)
            return
        }
        runAsync(result) {
            val ytdlCancelled = runCatching { YoutubeDL.getInstance().destroyProcessById(processId) }.getOrDefault(false)
            ytdlCancelled || ffmpegRunner.cancel(processId)
        }
    }

    private fun isYouTubeUrl(url: String): Boolean =
        url.lowercase().let { it.contains("youtube.com/") || it.contains("youtu.be/") }

    private fun isYouTubePlaylistUrl(url: String): Boolean {
        if (!isYouTubeUrl(url)) return false
        val lower = url.lowercase()
        return lower.contains("/playlist?") ||
            (lower.contains("list=") && !lower.contains("v=") && !lower.contains("youtu.be/"))
    }

    private fun applyExtractorArgs(request: YoutubeDLRequest, url: String, extractorArgs: String?) {
        if (extractorArgs != null) {
            if (extractorArgs.isNotBlank()) request.addOption("--extractor-args", extractorArgs)
        } else if (isYouTubeUrl(url)) {
            request.addOption("--extractor-args", "youtube:player_client=android_vr,default,tv")
        }
    }

    private fun hasFlag(args: List<String>, options: Map<String, Any?>, flag: String): Boolean =
        options.containsKey(flag) || args.any { it == flag || it.startsWith("$flag=") }

    private fun ensureInitialized() {
        if (initialized.get()) return
        synchronized(initLock) {
            if (initialized.get()) return
            YoutubeDL.getInstance().init(appContext)
            FFmpeg.getInstance().init(appContext)
            initialized.set(true)
        }
    }

    private fun emitEvent(payload: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(payload) }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        scope.launch {
            try {
                val data = block()
                mainHandler.post { result.success(data) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error("YOUTUBEDL_ERROR", t.message ?: t.javaClass.simpleName, null)
                }
            }
        }
    }
}
