package com.buildwithanshul.reeltunes

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.system.Os
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.zip.ZipInputStream

/**
 * On-device extraction engine.
 *
 * Runs the bundled CPython 3.12 (PSF-2.0) against the bundled yt-dlp zipapp
 * (Unlicense). Nothing is fetched at runtime: the interpreter, the standard
 * library and the extractor all ship inside the APK, so a Google Play app
 * update is the only way the engine ever changes.
 *
 * Python and QuickJS are packaged as `libpython.so` / `libqjs.so` because
 * `nativeLibraryDir` is one of the few locations Android still allows a
 * process to be executed from. The interpreter finds its standard library
 * through PYTHONHOME/LD_LIBRARY_PATH, both pointed at the unpacked tree below.
 *
 * Threading: every call that touches the engine runs on a background pool;
 * results and progress are posted back to the main thread.
 */
class EngineBridge(context: Context, messenger: BinaryMessenger) {

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()
    private val running = ConcurrentHashMap<String, Process>()

    @Volatile
    private var progressSink: EventChannel.EventSink? = null

    @Volatile
    private var prefix: File? = null

    private val engineChannel = MethodChannel(messenger, ENGINE_CHANNEL)
    private val progressChannel = EventChannel(messenger, PROGRESS_CHANNEL)

    init {
        engineChannel.setMethodCallHandler(::onMethodCall)
        progressChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> runAsync(result) {
                ensureReady()
                null
            }

            "getVideoInfo" -> {
                val url = call.argument<String>("url")
                    ?: return result.error("bad_args", "url is required", null)
                runAsync(result) {
                    ensureReady()
                    val out = execute(listOf("--dump-single-json", "--no-playlist") + url)
                    parseInfo(out)
                }
            }

            "downloadAudio" -> {
                val url = call.argument<String>("url")
                    ?: return result.error("bad_args", "url is required", null)
                val outputDir = call.argument<String>("outputDir")
                    ?: return result.error("bad_args", "outputDir is required", null)
                val baseName = call.argument<String>("baseName") ?: "audio"
                val taskId = call.argument<String>("taskId") ?: "task"
                runAsync(result) {
                    ensureReady()
                    download(url, outputDir, baseName, taskId)
                }
            }

            "cancel" -> {
                val taskId = call.argument<String>("taskId") ?: ""
                running.remove(taskId)?.let { it.destroy() }
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------- engine

    /** Unpacks the interpreter once per app version and locates the binaries. */
    @Synchronized
    private fun ensureReady() {
        prefix?.let { if (it.exists()) return }

        val native = File(appContext.applicationInfo.nativeLibraryDir)
        val python = File(native, PYTHON_LIB)
        val stdlib = File(native, STDLIB_ZIP)
        val ytdlp = File(native, YTDLP_LIB)
        require(python.exists()) { "bundled interpreter missing from the APK" }
        require(stdlib.exists()) { "bundled standard library missing from the APK" }
        require(ytdlp.exists()) { "bundled extractor missing from the APK" }

        val target = File(appContext.filesDir, STDLIB_DIR)
        if (!File(target, MARKER).exists()) {
            target.deleteRecursively()
            target.mkdirs()
            unpack(stdlib, target)
            materializeSymlinks(target)
            File(target, MARKER).createNewFile()
        }
        // The zip stores a proper prefix tree (`usr/lib`, `usr/lib/python3.12`,
        // `usr/etc/tls`), so PYTHONHOME is the `usr` folder, not its parent.
        prefix = File(target, "usr")
    }

    private fun unpack(zip: File, into: File) {
        ZipInputStream(zip.inputStream().buffered()).use { stream ->
            var entry = stream.nextEntry
            while (entry != null) {
                val name = entry.name
                if (name.contains("..")) {
                    entry = stream.nextEntry
                    continue
                }
                val out = File(into, name)
                if (entry.isDirectory) {
                    out.mkdirs()
                } else {
                    out.parentFile?.mkdirs()
                    out.outputStream().buffered().use { stream.copyTo(it) }
                    // Shared objects are dlopen'ed, scripts are not executed,
                    // so only readability matters here.
                    out.setReadable(true, true)
                }
                entry = stream.nextEntry
            }
        }
    }

    /**
     * Zip stores every symlink as a tiny text file holding the target name, so
     * `libz.so.1` arrives as 13 bytes of text instead of a pointer to
     * `libz.so.1.3.1`. The loader cannot follow that, and `zlib` / `binascii`
     * need `libz.so.1`, so the stubs are replaced with real links.
     */
    private fun materializeSymlinks(root: File) {
        root.walkTopDown()
            .filter { it.isFile && it.length() in 1..64 && it.name.contains(".so") }
            .forEach { link ->
                val targetName = try {
                    link.readText().trim()
                } catch (_: Exception) {
                    return@forEach
                }
                if (targetName.isEmpty() ||
                    targetName.contains('/') ||
                    targetName.contains('\\')
                ) {
                    return@forEach
                }
                val target = File(link.parentFile, targetName)
                if (!target.isFile || target.length() <= 64) return@forEach
                link.delete()
                try {
                    Os.symlink(targetName, link.absolutePath)
                } catch (_: Exception) {
                    // Filesystems without symlink support: copy is still valid.
                    target.copyTo(link, overwrite = true)
                }
            }
    }

    private fun command(tail: List<String>): List<String> {
        val native = File(appContext.applicationInfo.nativeLibraryDir)
        val cmd = ArrayList<String>(tail.size + 6)
        cmd.add(File(native, PYTHON_LIB).absolutePath)
        cmd.add(File(native, YTDLP_LIB).absolutePath)
        val qjs = File(native, QJS_LIB)
        if (qjs.exists()) {
            // yt-dlp needs a JavaScript runtime for YouTube signature handling.
            cmd.add("--js-runtimes")
            cmd.add("quickjs:${qjs.absolutePath}")
        }
        cmd.addAll(tail)
        return cmd
    }

    /** Runs the extractor and returns stdout; throws with the stderr tail. */
    private fun execute(tail: List<String>): String {
        val root = prefix ?: error("engine not initialised")
        val process = ProcessBuilder(command(tail))
            .directory(appContext.cacheDir)
            .apply { environment().putAll(environmentFor(root)) }
            .start()

        val err = StringBuilder()
        val errThread = Thread {
            process.errorStream.bufferedReader().use { reader ->
                reader.forEachLine { if (err.length < 4000) err.appendLine(it) }
            }
        }
        errThread.start()

        val out = process.inputStream.bufferedReader().use { it.readText() }
        process.waitFor()
        errThread.join()

        if (process.exitValue() != 0) {
            val detail = err.trim().lines().lastOrNull { it.isNotBlank() }
                ?: "extractor exited with ${process.exitValue()}"
            throw EngineException(detail)
        }
        return out
    }

    private fun parseInfo(raw: String): Map<String, Any?> {
        val text = raw.trim().lines().lastOrNull { it.startsWith("{") } ?: raw.trim()
        val json = JSONObject(text)
        val duration = if (json.isNull("duration")) null else json.optDouble("duration")
        return mapOf(
            "title" to if (json.isNull("title")) null else json.optString("title"),
            "durationSeconds" to duration,
            "webpageUrl" to if (json.isNull("webpage_url")) null else json.optString("webpage_url"),
            "ext" to if (json.isNull("ext")) null else json.optString("ext"),
        )
    }

    private fun download(
        url: String,
        outputDir: String,
        requestedName: String,
        taskId: String,
    ): Map<String, Any?> {
        val dir = File(outputDir).apply { mkdirs() }
        val base = uniqueBase(dir, sanitize(requestedName))

        val tail = listOf(
            "--no-playlist",
            "--newline",
            "--no-mtime",
            "-f", "bestaudio/best",
            "-o", File(dir, "$base.%(ext)s").absolutePath,
            "--no-simulate",
            "--print", "after_move:filepath",
            url,
        )

        val root = prefix ?: error("engine not initialised")
        val process = ProcessBuilder(command(tail))
            .directory(appContext.cacheDir)
            .apply { environment().putAll(environmentFor(root)) }
            .start()
        running[taskId] = process

        val err = StringBuilder()
        val errThread = Thread {
            process.errorStream.bufferedReader().use { reader ->
                reader.forEachLine { if (err.length < 4000) err.appendLine(it) }
            }
        }
        errThread.start()

        val printed = ArrayList<String>()
        process.inputStream.bufferedReader().use { reader ->
            reader.forEachLine { line ->
                if (line.startsWith("/")) printed.add(line.trim())
                PROGRESS.find(line)?.let { match ->
                    val percent = match.groupValues[1].toDoubleOrNull() ?: return@let
                    mainHandler.post {
                        progressSink?.success(
                            mapOf("taskId" to taskId, "progress" to percent)
                        )
                    }
                }
            }
        }
        process.waitFor()
        errThread.join()
        running.remove(taskId)

        if (process.exitValue() != 0) {
            val detail = err.trim().lines().lastOrNull { it.isNotBlank() }
                ?: "extractor exited with ${process.exitValue()}"
            throw EngineException(detail)
        }

        val path = printed.lastOrNull { File(it).exists() }
            ?: throw EngineException("extractor finished but produced no file")

        return mapOf(
            "path" to path,
            "fileName" to File(path).name,
            "sizeBytes" to File(path).length(),
        )
    }

    private fun sanitize(name: String): String {
        val cleaned = name
            .replace(Regex("""[/\\:*?"<>|\u0000-\u001f]"""), "_")
            .replace("%", "_")
            .trim()
            .trim('.')
        val clamped = if (cleaned.length > 80) cleaned.substring(0, 80) else cleaned
        return clamped.ifBlank { "audio" }
    }

    /** `Song.m4a` exists -> `Song 2.m4a`, so imports never overwrite. */
    private fun uniqueBase(dir: File, base: String): String {
        val existing = dir.listFiles()?.map { it.name } ?: emptyList()
        if (existing.none { it == base || it.startsWith("$base.") }) return base
        var index = 2
        while (existing.any { it == "$base $index" || it.startsWith("$base $index.") }) {
            index++
        }
        return "$base $index"
    }

    private fun environmentFor(root: File): Map<String, String> {
        val env = mutableMapOf(
            "PYTHONHOME" to root.absolutePath,
            "LD_LIBRARY_PATH" to File(root, "lib").absolutePath,
            "PATH" to "/system/bin:/system/xbin",
            "HOME" to appContext.filesDir.absolutePath,
            "TMPDIR" to appContext.cacheDir.absolutePath,
            "PYTHONUNBUFFERED" to "1",
            "LANG" to "C.UTF-8",
        )
        // OpenSSL has no default trust store on Android. The payload ships the
        // Mozilla bundle; without pointing at it every request fails with
        // CERTIFICATE_VERIFY_FAILED before yt-dlp even reaches the site.
        val bundle = File(root, "etc/tls/cert.pem")
        if (bundle.exists()) {
            env["SSL_CERT_FILE"] = bundle.absolutePath
        } else {
            env["SSL_CERT_DIR"] = "/system/etc/security/cacerts"
        }
        return env
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("engine", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    class EngineException(message: String) : RuntimeException(message)

    companion object {
        const val ENGINE_CHANNEL = "com.buildwithanshul.reeltunes/engine"
        const val PROGRESS_CHANNEL = "com.buildwithanshul.reeltunes/engine/progress"

        private const val PYTHON_LIB = "libpython.so"
        private const val QJS_LIB = "libqjs.so"
        private const val STDLIB_ZIP = "libpython.zip.so"
        private const val YTDLP_LIB = "libytdlp.so"
        private const val STDLIB_DIR = "python-3.12"
        private const val MARKER = ".unpacked-v2"
        private val PROGRESS = Regex("""\[download]\s+(\d+(?:\.\d+)?)%""")
    }
}
