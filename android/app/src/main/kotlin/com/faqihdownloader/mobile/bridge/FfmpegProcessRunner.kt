package com.faqihdownloader.mobile.bridge

import android.content.Context
import java.io.File
import java.util.concurrent.ConcurrentHashMap

data class FfmpegRunResult(
    val exitCode: Int,
    val output: String,
)

/**
 * Executes the embedded FFmpeg binary (`libffmpeg.so`) directly via ProcessBuilder
 * and tracks running processes for immediate cancellation by processId.
 */
class FfmpegProcessRunner(private val appContext: Context) {
    private val activeProcesses = ConcurrentHashMap<String, Process>()

    fun run(
        args: List<String>,
        processId: String,
        onLine: (String) -> Unit,
    ): FfmpegRunResult {
        val binary = resolveFfmpegBinary()
        val libPaths = buildLibraryPath()
        val command = listOf(binary.absolutePath) + args

        val builder = ProcessBuilder(command)
        builder.redirectErrorStream(true)
        val env = builder.environment()
        if (libPaths.isNotEmpty()) {
            env["LD_LIBRARY_PATH"] = libPaths
        }

        val process = builder.start()
        activeProcesses[processId] = process
        val outputBuffer = StringBuilder()

        try {
            process.inputStream.bufferedReader().use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    if (outputBuffer.length < 64_000) {
                        outputBuffer.append(line).append('\n')
                    }
                    onLine(line)
                }
            }
            val exitCode = process.waitFor()
            return FfmpegRunResult(
                exitCode = exitCode,
                output = outputBuffer.toString().trim(),
            )
        } finally {
            activeProcesses.remove(processId, process)
        }
    }

    fun cancel(processId: String): Boolean {
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
        val directSo = File(nativeDir, "libffmpeg.so")
        if (directSo.exists()) {
            return directSo
        }

        val extractedBin = File(
            appContext.noBackupFilesDir,
            "youtubedl-android/packages/ffmpeg/usr/bin/ffmpeg",
        )
        if (extractedBin.exists()) {
            return extractedBin
        }

        throw IllegalStateException(
            "Embedded FFmpeg binary not found in ${nativeDir.absolutePath} " +
                "or ${extractedBin.absolutePath}",
        )
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
