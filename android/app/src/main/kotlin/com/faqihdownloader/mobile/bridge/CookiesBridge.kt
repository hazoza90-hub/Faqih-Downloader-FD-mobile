package com.faqihdownloader.mobile.bridge

import android.net.Uri
import android.webkit.CookieManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Exports WebView cookies (including HttpOnly) as a Netscape cookie file for yt-dlp. */
class CookiesBridge : MethodChannel.MethodCallHandler {

    companion object {
        const val METHOD_CHANNEL = "com.faqihdownloader.mobile/cookies"
    }

    private var methodChannel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@CookiesBridge)
        }
    }

    fun dispose() {
        methodChannel?.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "exportCookiesForUrls" -> handleExport(call, result)
            "clearAllCookies" -> handleClear(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleExport(call: MethodCall, result: MethodChannel.Result) {
        val urls = call.argument<List<String>>("urls").orEmpty()
        val outputPath = call.argument<String>("outputPath")?.trim().orEmpty()
        if (urls.isEmpty() || outputPath.isEmpty()) {
            result.error("INVALID_ARGS", "urls and outputPath are required", null)
            return
        }
        try {
            val cm = CookieManager.getInstance()
            cm.flush()
            val deduped = LinkedHashMap<String, String>()
            for (rawUrl in urls) {
                val url = rawUrl.trim()
                val host = Uri.parse(url).host?.lowercase()?.trim().orEmpty()
                if (host.isEmpty()) continue
                val domain = if (host.startsWith(".")) host else ".$host"
                val sec = if (url.startsWith("https://", ignoreCase = true)) "TRUE" else "FALSE"
                val raw = cm.getCookie(url) ?: continue
                for (part in raw.split(';')) {
                    val idx = part.indexOf('=')
                    if (idx <= 0) continue
                    val name = part.substring(0, idx).trim()
                    if (name.isEmpty()) continue
                    deduped["$domain|$name"] =
                        "$domain\tTRUE\t/\t$sec\t2147483647\t$name\t${part.substring(idx + 1).trim()}"
                }
            }
            val outFile = File(outputPath).apply { parentFile?.mkdirs() }
            val tmpFile = File("${outFile.absolutePath}.tmp")
            tmpFile.writeText("# Netscape HTTP Cookie File\n" + deduped.values.joinToString("\n") + "\n", Charsets.UTF_8)
            if (outFile.exists()) outFile.delete()
            if (!tmpFile.renameTo(outFile)) {
                tmpFile.copyTo(outFile, overwrite = true)
                tmpFile.delete()
            }
            result.success(deduped.size)
        } catch (t: Throwable) {
            result.error("COOKIES_EXPORT_ERROR", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private fun handleClear(call: MethodCall, result: MethodChannel.Result) {
        try {
            CookieManager.getInstance().apply { removeAllCookies(null); flush() }
            val path = call.argument<String>("cookiesFilePath")?.trim().orEmpty()
            if (path.isNotEmpty()) runCatching { File(path).delete() }
            result.success(true)
        } catch (t: Throwable) {
            result.error("COOKIES_CLEAR_ERROR", t.message ?: t.javaClass.simpleName, null)
        }
    }
}
