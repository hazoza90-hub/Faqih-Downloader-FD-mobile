package com.faqihdownloader.mobile.bridge

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

class MediaStoreBridge(private val appContext: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val METHOD_CHANNEL = "com.faqihdownloader.mobile/media_store"
        private const val BUFFER_BYTES = 64 * 1024
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var methodChannel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@MediaStoreBridge)
        }
    }

    fun dispose() {
        scope.cancel()
        methodChannel?.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getAppWorkDir" -> {
                val workDir = File(appContext.filesDir, "downloads_work")
                if (!workDir.exists()) workDir.mkdirs()
                result.success(workDir.absolutePath)
            }
            "exportToDownloads" -> handleExportToDownloads(call, result)
            "openFile" -> handleOpenFile(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleExportToDownloads(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")?.trim().orEmpty()
        val displayName = call.argument<String>("displayName")?.trim().orEmpty()
        val mimeType = call.argument<String>("mimeType")?.trim().orEmpty()
            .ifEmpty { "application/octet-stream" }
        val subFolder = call.argument<String>("subFolder")?.trim().orEmpty()
        val deleteSource = call.argument<Boolean>("deleteSource") ?: false

        if (sourcePath.isEmpty() || displayName.isEmpty()) {
            result.error("INVALID_ARGS", "sourcePath and displayName are required", null)
            return
        }

        scope.launch {
            try {
                val sourceFile = File(sourcePath)
                if (!sourceFile.isFile) {
                    throw IllegalArgumentException("Source file does not exist: $sourcePath")
                }

                val exported = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    exportWithMediaStore(sourceFile, displayName, mimeType, subFolder)
                } else {
                    exportLegacyDownloads(sourceFile, displayName, mimeType, subFolder)
                }

                if (deleteSource) {
                    runCatching { sourceFile.delete() }
                }
                mainHandler.post { result.success(exported) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error("MEDIA_STORE_ERROR", t.message ?: t.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun sanitizeSubFolder(raw: String): String {
        var clean = raw.replace(Regex("[\\\\/:*?\"<>|]+"), "")
        while (clean.contains("..")) {
            clean = clean.replace("..", "")
        }
        clean = clean.trim().trim('.').trim()
        return if (clean.isEmpty() || clean == "." || clean == "..") "" else clean
    }

    private fun sanitizeDisplayName(raw: String): String {
        var clean = raw.replace(Regex("[\\\\/:*?\"<>|]+"), "")
        while (clean.contains("..")) {
            clean = clean.replace("..", "")
        }
        clean = clean.trim().trim('.').trim()
        return if (clean.isEmpty() || clean == "." || clean == "..") "download.bin" else clean
    }

    private fun exportWithMediaStore(
        sourceFile: File,
        displayName: String,
        mimeType: String,
        subFolder: String,
    ): Map<String, Any> {
        val cleanSub = sanitizeSubFolder(subFolder)
        val safeName = sanitizeDisplayName(displayName)
        val relativeDir = if (cleanSub.isEmpty()) {
            "${Environment.DIRECTORY_DOWNLOADS}/FaqihDownloader"
        } else {
            "${Environment.DIRECTORY_DOWNLOADS}/FaqihDownloader/$cleanSub"
        }

        val resolver = appContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativeDir)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Failed to insert MediaStore Downloads row")

        var copiedBytes = 0L
        try {
            resolver.openOutputStream(uri)?.use { outStream ->
                FileInputStream(sourceFile).use { inStream ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    while (true) {
                        val count = inStream.read(buffer)
                        if (count <= 0) break
                        outStream.write(buffer, 0, count)
                        copiedBytes += count
                    }
                    outStream.flush()
                }
            } ?: throw IllegalStateException("Failed to open output stream for $uri")

            val publish = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            resolver.update(uri, publish, null, null)
        } catch (t: Throwable) {
            runCatching { resolver.delete(uri, null, null) }
            throw t
        }

        return mapOf(
            "uri" to uri.toString(),
            "displayPath" to "$relativeDir/$safeName",
            "sizeBytes" to copiedBytes,
        )
    }

    @Suppress("DEPRECATION")
    private fun exportLegacyDownloads(
        sourceFile: File,
        displayName: String,
        mimeType: String,
        subFolder: String,
    ): Map<String, Any> {
        val cleanSub = sanitizeSubFolder(subFolder)
        val safeName = sanitizeDisplayName(displayName)
        val baseDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val targetDir = if (cleanSub.isEmpty()) {
            File(baseDir, "FaqihDownloader")
        } else {
            File(File(baseDir, "FaqihDownloader"), cleanSub)
        }
        if (!targetDir.exists()) targetDir.mkdirs()

        val targetFile = resolveUniqueLegacyFile(targetDir, safeName)
        val tmpFile = File(targetDir, "${targetFile.name}.tmp")
        var copiedBytes = 0L
        try {
            FileInputStream(sourceFile).use { inStream ->
                FileOutputStream(tmpFile).use { outStream ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    while (true) {
                        val count = inStream.read(buffer)
                        if (count <= 0) break
                        outStream.write(buffer, 0, count)
                        copiedBytes += count
                    }
                    outStream.fd.sync()
                }
            }
            if (!tmpFile.renameTo(targetFile)) {
                tmpFile.copyTo(targetFile, overwrite = true)
                tmpFile.delete()
            }
        } catch (t: Throwable) {
            runCatching { tmpFile.delete() }
            throw t
        }

        MediaScannerConnection.scanFile(
            appContext,
            arrayOf(targetFile.absolutePath),
            arrayOf(mimeType),
            null,
        )
        return mapOf(
            "uri" to Uri.fromFile(targetFile).toString(),
            "displayPath" to targetFile.absolutePath,
            "sizeBytes" to copiedBytes,
        )
    }

    private fun resolveUniqueLegacyFile(dir: File, displayName: String): File {
        var candidate = File(dir, displayName)
        if (!candidate.exists()) return candidate
        val dotIdx = displayName.lastIndexOf('.')
        val stem = if (dotIdx > 0) displayName.substring(0, dotIdx) else displayName
        val ext = if (dotIdx > 0) displayName.substring(dotIdx) else ""
        var counter = 1
        while (candidate.exists()) {
            candidate = File(dir, "$stem ($counter)$ext")
            counter++
        }
        return candidate
    }

    private fun handleOpenFile(call: MethodCall, result: MethodChannel.Result) {
        val pathOrUri = call.argument<String>("pathOrUri")?.trim().orEmpty()
        val mimeType = call.argument<String>("mimeType")?.trim().orEmpty()
            .ifEmpty { "*/*" }
        if (pathOrUri.isEmpty()) {
            result.error("INVALID_ARGS", "pathOrUri is required", null)
            return
        }
        try {
            val uri = when {
                pathOrUri.startsWith("content://") -> Uri.parse(pathOrUri)
                pathOrUri.startsWith("file://") -> {
                    val filePath = Uri.parse(pathOrUri).path
                        ?: throw IllegalArgumentException("Invalid file URI: $pathOrUri")
                    FileProvider.getUriForFile(
                        appContext,
                        "${appContext.packageName}.fileprovider",
                        File(filePath),
                    )
                }
                else -> FileProvider.getUriForFile(
                    appContext,
                    "${appContext.packageName}.fileprovider",
                    File(pathOrUri),
                )
            }
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            appContext.startActivity(viewIntent)
            result.success(true)
        } catch (t: Throwable) {
            result.error("OPEN_FILE_ERROR", t.message ?: t.javaClass.simpleName, null)
        }
    }
}
