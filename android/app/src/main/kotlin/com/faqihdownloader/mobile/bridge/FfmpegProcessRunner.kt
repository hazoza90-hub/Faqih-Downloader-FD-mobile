package com.faqihdownloader.mobile.bridge

import android.content.Context
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.ConcurrentHashMap

data class FfmpegRunResult(
    val exitCode: Int,
    val output: String,
)

/**
 * Executes the extracted embedded ELF FFmpeg binary via ProcessBuilder
 * and tracks running processes for immediate cancellation by processId.
 */
class FfmpegProcessRunner(private val appContext: Context) {
    private val activeProcesses = ConcurrentHashMap<String, Process>()
    private val cancelledIds = ConcurrentHashMap.newKeySet<String>()

    fun run(
        args: List<String>,
        processId: String,
        onLine: (String) -> Unit,
    ): FfmpegRunResult {
        var process: Process? = null
        try {
            if (cancelledIds.remove(processId)) {
                return FfmpegRunResult(exitCode = -1, output = "Cancelled before start")
            }

            val binary = resolveFfmpegBinary()
            val libPaths = buildLibraryPath()
            val command = listOf(binary.absolutePath) + args

            val builder = ProcessBuilder(command)
            builder.redirectErrorStream(true)
            val env = builder.environment()
            if (libPaths.isNotEmpty()) {
                env["LD_LIBRARY_PATH"] = libPaths
            }

            if (cancelledIds.remove(processId)) {
                return FfmpegRunResult(exitCode = -1, output = "Cancelled before start")
            }

            val started = builder.start()
            process = started
            activeProcesses[processId] = started

            if (cancelledIds.remove(processId)) {
                started.destroyForcibly()
                activeProcesses.remove(processId, started)
                return FfmpegRunResult(exitCode = -1, output = "Cancelled")
            }

            val outputBuffer = StringBuilder()
            started.inputStream.bufferedReader().use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    if (outputBuffer.length < 64_000) {
                        outputBuffer.append(line).append('\n')
                    }
                    onLine(line)
                }
            }
            val exitCode = started.waitFor()
            return FfmpegRunResult(
                exitCode = exitCode,
                output = outputBuffer.toString().trim(),
            )
        } finally {
            cancelledIds.remove(processId)
            process?.let { activeProcesses.remove(processId, it) }
        }
    }

    fun cancel(processId: String): Boolean {
        cancelledIds.add(processId)
        val process = activeProcesses.remove(processId) ?: return false
        process.destroyForcibly()
        return true
    }

    fun cancelAll() {
        val keys = activeProcesses.keys.toList()
        for (id in keys) {
            cancel(id)
        }
    }

    private fun resolveFfmpegBinary(): File {
        val nativeDir = File(appContext.applicationInfo.nativeLibraryDir)
        val candidates = listOf(
            File(nativeDir, "libffmpeg.so"),
            File(appContext.noBackupFilesDir, "youtubedl-android/packages/ffmpeg/usr/bin/ffmpeg"),
            File(appContext.noBackupFilesDir, "youtubedl-android/packages/ffmpeg/bin/ffmpeg"),
        )
        for (candidate in candidates) {
            if (isElfExecutable(candidate)) {
                if (!candidate.canExecute()) {
                    candidate.setExecutable(true, false)
                }
                return candidate
            }
        }

        val searched = candidates.joinToString(", ") { it.absolutePath }
        throw IllegalStateException("Embedded ELF FFmpeg binary not found in: $searched")
    }

    private fun isElfExecutable(file: File): Boolean {
        if (!file.isFile || file.length() < 4L) return false
        return try {
            val header = ByteArray(4)
            FileInputStream(file).use { input ->
                val read = input.read(header)
                read == 4 &&
                    header[0] == 0x7F.toByte() &&
                    header[1] == 0x45.toByte() &&
                    header[2] == 0x4C.toByte() &&
                    header[3] == 0x46.toByte()
            }
        } catch (_: Throwable) {
            false
        }
    }

    private fun buildLibraryPath(): String {
        val paths = mutableListOf<String>()
        val nativeDir = appContext.applicationInfo.nativeLibraryDir
        if (!nativeDir.isNullOrBlank()) {
            paths.add(nativeDir)
        }
        val pkgLibDir = File(
            appContext.noBackupFilesDir,
            "youtubedl-android/packages/ffmpeg/usr/lib",
        )
        if (pkgLibDir.exists()) {
            paths.add(pkgLibDir.absolutePath)
        }
        val basePythonLibDir = File(
            appContext.noBackupFilesDir,
            "youtubedl-android/packages/python/usr/lib",
        )
        if (basePythonLibDir.exists()) {
            paths.add(basePythonLibDir.absolutePath)
        }
        val existing = System.getenv("LD_LIBRARY_PATH")
        if (!existing.isNullOrBlank()) {
            paths.add(existing)
        }
        return paths.distinct().joinToString(File.pathSeparator)
    }
}
