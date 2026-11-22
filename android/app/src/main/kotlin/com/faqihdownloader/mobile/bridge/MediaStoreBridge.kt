package com.faqihdownloader.mobile.bridge

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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

/** Handles MediaStore/SAF downloads export, file open/share/delete, subtitle picking, and permissions. */
class MediaStoreBridge(
    private val appContext: Context,
    private val activityProvider: () -> Activity? = { null },
) : MethodChannel.MethodCallHandler {

    companion object {
        const val METHOD_CHANNEL = "com.faqihdownloader.mobile/media_store"
        private const val BUFFER_BYTES = 64 * 1024
        private const val REQ_PICK_TREE = 4101
        private const val REQ_PICK_SUBTITLE = 4102
        private const val REQ_NOTIF_PERMISSION = 4103
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var methodChannel: MethodChannel? = null
    private var pendingTreeResult: MethodChannel.Result? = null
    private var pendingSubResult: MethodChannel.Result? = null
    private var pendingPermResult: MethodChannel.Result? = null

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@MediaStoreBridge)
        }
    }

    fun dispose() {
        scope.cancel()
        methodChannel?.setMethodCallHandler(null)
        pendingTreeResult = null
        pendingSubResult = null
        pendingPermResult = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getAppWorkDir" -> {
                val workDir = File(appContext.filesDir, "downloads_work").apply { mkdirs() }
                result.success(workDir.absolutePath)
            }
            "exportToDownloads" -> handleExportToDownloads(call, result)
            "openFile" -> handleOpenFile(call, result)
            "shareFile" -> handleShareFile(call, result)
            "deleteExportedFile" -> handleDeleteExportedFile(call, result)
            "pickSaveDirectory" -> handlePickSaveDirectory(result)
            "pickSubtitleFile" -> handlePickSubtitleFile(result)
            "requestNotificationPermission" -> handleRequestNotifPermission(result)
            else -> result.notImplemented()
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQ_PICK_TREE) {
            val cb = pendingTreeResult ?: return false
            pendingTreeResult = null
            val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
            if (uri == null) { cb.success(null); return true }
            val info = SafFolderHelper.persistAndResolveWritableTree(appContext, uri, data?.flags ?: 0)
            if (info == null) cb.error("SAF_NOT_WRITABLE", "Selected folder is not writable", null)
            else cb.success(info)
            return true
        }
        if (requestCode == REQ_PICK_SUBTITLE) {
            val cb = pendingSubResult ?: return false
            pendingSubResult = null
            val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
            if (uri == null) { cb.success(null); return true }
            scope.launch {
                try {
                    val res = SafFolderHelper.copyPickedSubtitleToWorkDir(appContext, uri)
                    mainHandler.post { cb.success(res) }
                } catch (t: Throwable) {
                    mainHandler.post { cb.error("SUB_PICK_ERROR", t.message ?: t.javaClass.simpleName, null) }
                }
            }
            return true
        }
        return false
    }

    fun handleRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQ_NOTIF_PERMISSION) return false
        val cb = pendingPermResult ?: return false
        pendingPermResult = null
        cb.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        return true
    }

    private fun handlePickSaveDirectory(result: MethodChannel.Result) {
        val activity = activityProvider() ?: return result.error("NO_ACTIVITY", "Activity unavailable", null)
        if (pendingTreeResult != null) return result.error("BUSY", "Directory picker already active", null)
        pendingTreeResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try { activity.startActivityForResult(intent, REQ_PICK_TREE) } catch (t: Throwable) {
            pendingTreeResult = null
            result.error("PICKER_LAUNCH_ERROR", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private fun handlePickSubtitleFile(result: MethodChannel.Result) {
        val activity = activityProvider() ?: return result.error("NO_ACTIVITY", "Activity unavailable", null)
        if (pendingSubResult != null) return result.error("BUSY", "Subtitle picker already active", null)
        pendingSubResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try { activity.startActivityForResult(intent, REQ_PICK_SUBTITLE) } catch (t: Throwable) {
            pendingSubResult = null
            result.error("PICKER_LAUNCH_ERROR", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private fun handleRequestNotifPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val granted = ContextCompat.checkSelfPermission(appContext, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        val activity = activityProvider()
        if (activity == null || pendingPermResult != null) {
            result.success(false)
            return
        }
        pendingPermResult = result
        ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIF_PERMISSION)
    }

    private fun handleExportToDownloads(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")?.trim().orEmpty()
        val displayName = call.argument<String>("displayName")?.trim().orEmpty()
        val mimeType = call.argument<String>("mimeType")?.trim().orEmpty().ifEmpty { "application/octet-stream" }
        val subFolder = call.argument<String>("subFolder")?.trim().orEmpty()
        val treeUri = call.argument<String>("treeUri")?.trim().orEmpty()
        val deleteSource = call.argument<Boolean>("deleteSource") ?: false
        if (sourcePath.isEmpty() || displayName.isEmpty()) {
            return result.error("INVALID_ARGS", "sourcePath and displayName are required", null)
        }
        scope.launch {
            try {
                val sourceFile = File(sourcePath)
                if (!sourceFile.isFile) throw IllegalArgumentException("Source file does not exist: $sourcePath")
                val exported = when {
                    treeUri.isNotEmpty() -> SafFolderHelper.exportToTreeUri(appContext, sourceFile, treeUri, displayName, mimeType, subFolder)
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> exportWithMediaStore(sourceFile, displayName, mimeType, subFolder)
                    else -> exportLegacyDownloads(sourceFile, displayName, mimeType, subFolder)
                }
                if (deleteSource) runCatching { sourceFile.delete() }
                mainHandler.post { result.success(exported) }
            } catch (t: Throwable) {
                mainHandler.post { result.error("MEDIA_STORE_ERROR", t.message ?: t.javaClass.simpleName, null) }
            }
        }
    }

    private fun exportWithMediaStore(sourceFile: File, displayName: String, mimeType: String, subFolder: String): Map<String, Any> {
        val cleanSub = SafFolderHelper.sanitizeSubFolder(subFolder)
        val safeName = SafFolderHelper.sanitizeDisplayName(displayName)
        val relativeDir = if (cleanSub.isEmpty()) "${Environment.DIRECTORY_DOWNLOADS}/FaqihDownloader"
        else "${Environment.DIRECTORY_DOWNLOADS}/FaqihDownloader/$cleanSub"
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
                        val n = inStream.read(buffer)
                        if (n <= 0) break
                        outStream.write(buffer, 0, n)
                        copiedBytes += n
                    }
                    outStream.flush()
                }
            } ?: throw IllegalStateException("Failed to open output stream for $uri")
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (t: Throwable) {
            runCatching { resolver.delete(uri, null, null) }
            throw t
        }
        return mapOf("uri" to uri.toString(), "displayPath" to "$relativeDir/$safeName", "sizeBytes" to copiedBytes)
    }

    @Suppress("DEPRECATION")
    private fun exportLegacyDownloads(sourceFile: File, displayName: String, mimeType: String, subFolder: String): Map<String, Any> {
        val cleanSub = SafFolderHelper.sanitizeSubFolder(subFolder)
        val safeName = SafFolderHelper.sanitizeDisplayName(displayName)
        val baseDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val targetDir = if (cleanSub.isEmpty()) File(baseDir, "FaqihDownloader") else File(File(baseDir, "FaqihDownloader"), cleanSub)
        if (!targetDir.exists()) targetDir.mkdirs()
        var targetFile = File(targetDir, safeName)
        var counter = 1
        while (targetFile.exists()) {
            val dot = safeName.lastIndexOf('.')
            val stem = if (dot > 0) safeName.substring(0, dot) else safeName
            val ext = if (dot > 0) safeName.substring(dot) else ""
            targetFile = File(targetDir, "$stem (${counter++})$ext")
        }
        val tmpFile = File(targetDir, "${targetFile.name}.tmp")
        var copiedBytes = 0L
        try {
            FileInputStream(sourceFile).use { ins ->
                FileOutputStream(tmpFile).use { outs ->
                    val buf = ByteArray(BUFFER_BYTES)
                    while (true) { val n = ins.read(buf); if (n <= 0) break; outs.write(buf, 0, n); copiedBytes += n }
                    outs.fd.sync()
                }
            }
            if (!tmpFile.renameTo(targetFile)) { tmpFile.copyTo(targetFile, overwrite = true); tmpFile.delete() }
        } catch (t: Throwable) { runCatching { tmpFile.delete() }; throw t }
        MediaScannerConnection.scanFile(appContext, arrayOf(targetFile.absolutePath), arrayOf(mimeType), null)
        return mapOf("uri" to Uri.fromFile(targetFile).toString(), "displayPath" to targetFile.absolutePath, "sizeBytes" to copiedBytes)
    }

    private fun handleOpenFile(call: MethodCall, result: MethodChannel.Result) {
        val pathOrUri = call.argument<String>("pathOrUri")?.trim().orEmpty()
        val mimeType = call.argument<String>("mimeType")?.trim().orEmpty().ifEmpty { "*/*" }
        if (pathOrUri.isEmpty()) return result.error("INVALID_ARGS", "pathOrUri is required", null)
        try {
            val uri = SafFolderHelper.resolveContentOrFileUri(appContext, pathOrUri)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            appContext.startActivity(intent)
            result.success(true)
        } catch (t: Throwable) { result.error("OPEN_FILE_ERROR", t.message ?: t.javaClass.simpleName, null) }
    }

    private fun handleShareFile(call: MethodCall, result: MethodChannel.Result) {
        val pathOrUri = call.argument<String>("pathOrUri")?.trim().orEmpty()
        val mimeType = call.argument<String>("mimeType")?.trim().orEmpty().ifEmpty { "*/*" }
        if (pathOrUri.isEmpty()) return result.error("INVALID_ARGS", "pathOrUri is required", null)
        try { SafFolderHelper.shareFile(appContext, pathOrUri, mimeType); result.success(true) }
        catch (t: Throwable) { result.error("SHARE_FILE_ERROR", t.message ?: t.javaClass.simpleName, null) }
    }

    private fun handleDeleteExportedFile(call: MethodCall, result: MethodChannel.Result) {
        val pathOrUri = call.argument<String>("pathOrUri")?.trim().orEmpty()
        if (pathOrUri.isEmpty()) return result.error("INVALID_ARGS", "pathOrUri is required", null)
        scope.launch {
            val ok = runCatching { SafFolderHelper.deleteExportedFile(appContext, pathOrUri) }.getOrDefault(false)
            mainHandler.post { result.success(ok) }
        }
    }
}
