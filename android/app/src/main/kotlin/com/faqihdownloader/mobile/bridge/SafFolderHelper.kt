package com.faqihdownloader.mobile.bridge

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/** SAF DocumentFile export, system share, deletion, and picked-subtitle copy helpers. */
internal object SafFolderHelper {
    private const val BUFFER_BYTES = 64 * 1024

    fun sanitizeSubFolder(raw: String): String {
        var clean = raw.replace(Regex("[\\\\/:*?\"<>|]+"), "")
        while (clean.contains("..")) clean = clean.replace("..", "")
        clean = clean.trim().trim('.').trim()
        return if (clean.isEmpty() || clean == "." || clean == "..") "" else clean
    }

    fun sanitizeDisplayName(raw: String, fallback: String = "download.bin"): String {
        var clean = raw.replace(Regex("[\\\\/:*?\"<>|]+"), "")
        while (clean.contains("..")) clean = clean.replace("..", "")
        clean = clean.trim().trim('.').trim()
        return if (clean.isEmpty() || clean == "." || clean == "..") fallback else clean
    }

    fun resolveTreeDisplayName(appContext: Context, treeUri: Uri): String {
        val docName = runCatching { DocumentFile.fromTreeUri(appContext, treeUri)?.name }.getOrNull()
        if (!docName.isNullOrBlank()) return docName
        val segment = treeUri.lastPathSegment?.substringAfterLast(':')?.trim().orEmpty()
        return segment.ifEmpty { "Custom Folder" }
    }

    fun exportToTreeUri(
        appContext: Context,
        sourceFile: File,
        treeUriStr: String,
        displayName: String,
        mimeType: String,
        subFolder: String,
    ): Map<String, Any> {
        val treeUri = Uri.parse(treeUriStr)
        var targetDir = DocumentFile.fromTreeUri(appContext, treeUri)
            ?: throw IllegalStateException("Invalid SAF tree URI: $treeUriStr")
        if (!targetDir.exists()) {
            throw IllegalStateException("Selected save folder is unavailable or permission revoked")
        }
        val rootLabel = resolveTreeDisplayName(appContext, treeUri)
        val cleanSub = sanitizeSubFolder(subFolder)
        if (cleanSub.isNotEmpty()) {
            val subDir = targetDir.findFile(cleanSub)?.takeIf { it.isDirectory }
                ?: targetDir.createDirectory(cleanSub)
            if (subDir != null) targetDir = subDir
        }
        val safeName = sanitizeDisplayName(displayName)
        val uniqueName = resolveUniqueDocumentName(targetDir, safeName)
        val created = targetDir.createFile(mimeType, uniqueName)
            ?: throw IllegalStateException("Failed to create SAF file: $uniqueName")

        var copiedBytes = 0L
        try {
            appContext.contentResolver.openOutputStream(created.uri)?.use { outStream ->
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
            } ?: throw IllegalStateException("Failed to open output stream for ${created.uri}")
        } catch (t: Throwable) {
            runCatching { created.delete() }
            throw t
        }
        val displayPath = if (cleanSub.isEmpty()) "$rootLabel/$uniqueName" else "$rootLabel/$cleanSub/$uniqueName"
        return mapOf(
            "uri" to created.uri.toString(),
            "displayPath" to displayPath,
            "sizeBytes" to copiedBytes,
        )
    }

    private fun resolveUniqueDocumentName(dir: DocumentFile, rawName: String): String {
        if (dir.findFile(rawName) == null) return rawName
        val dotIdx = rawName.lastIndexOf('.')
        val stem = if (dotIdx > 0) rawName.substring(0, dotIdx) else rawName
        val ext = if (dotIdx > 0) rawName.substring(dotIdx) else ""
        var counter = 1
        while (true) {
            val candidate = "$stem ($counter)$ext"
            if (dir.findFile(candidate) == null) return candidate
            counter++
        }
    }

    fun resolveContentOrFileUri(appContext: Context, pathOrUri: String): Uri {
        return when {
            pathOrUri.startsWith("content://") -> Uri.parse(pathOrUri)
            pathOrUri.startsWith("file://") -> {
                val filePath = Uri.parse(pathOrUri).path
                    ?: throw IllegalArgumentException("Invalid file URI: $pathOrUri")
                FileProvider.getUriForFile(appContext, "${appContext.packageName}.fileprovider", File(filePath))
            }
            else -> FileProvider.getUriForFile(appContext, "${appContext.packageName}.fileprovider", File(pathOrUri))
        }
    }

    fun shareFile(appContext: Context, pathOrUri: String, mimeType: String) {
        val uri = resolveContentOrFileUri(appContext, pathOrUri)
        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(sendIntent, null).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        appContext.startActivity(chooser)
    }

    fun deleteExportedFile(appContext: Context, pathOrUri: String): Boolean {
        return when {
            pathOrUri.startsWith("content://") -> {
                val uri = Uri.parse(pathOrUri)
                val deletedDoc = runCatching { DocumentFile.fromSingleUri(appContext, uri)?.delete() == true }
                    .getOrDefault(false)
                deletedDoc || runCatching { appContext.contentResolver.delete(uri, null, null) > 0 }.getOrDefault(false)
            }
            pathOrUri.startsWith("file://") -> {
                val file = Uri.parse(pathOrUri).path?.let(::File) ?: return false
                !file.exists() || file.delete()
            }
            else -> {
                val file = File(pathOrUri)
                !file.exists() || file.delete()
            }
        }
    }

    fun copyPickedSubtitleToWorkDir(appContext: Context, uri: Uri): Map<String, String> {
        var displayName = ""
        appContext.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) displayName = c.getString(0) ?: ""
        }
        if (displayName.isBlank()) {
            displayName = DocumentFile.fromSingleUri(appContext, uri)?.name ?: "external.srt"
        }
        val safeName = sanitizeDisplayName(displayName, fallback = "external.srt")
        val subDir = File(appContext.filesDir, "downloads_work/picked_subs").apply { mkdirs() }
        val outFile = File(subDir, "${System.currentTimeMillis()}_$safeName")
        appContext.contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(outFile).use { output -> input.copyTo(output, BUFFER_BYTES) }
        } ?: throw IllegalStateException("Cannot read picked subtitle file")
        return mapOf("path" to outFile.absolutePath, "name" to safeName)
    }
}
