package com.buildwithanshul.reeltunes

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The audios folder, accessed through the Storage Access Framework.
 *
 * Android 11+ refuses raw file access to Download / DCIM / Movies even with the
 * granular READ_MEDIA_* permissions (verified on device: EACCES as the app UID),
 * so the folder the user files land in is a SAF tree, not a path. That tree is
 * the single source of truth: saves go into it, anything the user drops in with
 * a file manager shows up on the next scan, and the library metadata is mirrored
 * inside it so a reinstall can restore playlists.
 *
 * Persistable grants survive reboots but NOT reinstalls, so after a reinstall
 * the user links the same folder once and everything comes back.
 */
class FolderBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val prefs =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val channel = MethodChannel(messenger, CHANNEL)
    var pendingLink: MethodChannel.Result? = null
        private set

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "state" -> result.success(stateMap())
                    "probe" -> runAsync(result) { probe() }
                    "ensureDefault" -> runAsync(result) { ensureDefaultFolder() }
                    "exists" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        runAsync(result) { exists(uri) }
                    }
                    "link" -> launchLink(
                        result,
                        call.argument<Boolean>("preferDefault") == true
                    )
                    "unlink" -> result.success(unlink())
                    "scan" -> runAsync(result) { scan() }
                    "save" -> {
                        val source = call.argument<String>("sourcePath")
                        val name = call.argument<String>("fileName")
                        val subdir = call.argument<String>("subdir")
                        if (source.isNullOrBlank() || name.isNullOrBlank()) {
                            result.error("bad_args", "sourcePath and fileName are required", null)
                        } else {
                            runAsync(result) { save(File(source), name, subdir) }
                        }
                    }
                    "readText" -> {
                        val name = call.argument<String>("name") ?: ""
                        runAsync(result) { readText(name) }
                    }
                    "writeText" -> {
                        val name = call.argument<String>("name") ?: ""
                        val text = call.argument<String>("text") ?: ""
                        runAsync(result) { writeText(name, text) }
                    }
                    "delete" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        runAsync(result) { delete(uri) }
                    }
                    "open" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        result.success(openDocument(uri))
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("folder_error", e.message ?: e.toString(), null)
            }
        }
    }

    // ---- link / unlink -----------------------------------------------------

    fun requestLink(
        activity: Activity,
        result: MethodChannel.Result,
        preferDefault: Boolean = false,
    ) {
        if (pendingLink != null) {
            result.error("busy", "The folder picker is already open", null)
            return
        }
        pendingLink = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
            // "Use default folder": create ReelTune Audios if it is missing,
            // then open the picker already INSIDE it. The user only has to
            // tap "Use this folder".
            if (preferDefault && Build.VERSION.SDK_INT >= 26) {
                val ready = ensureDefaultFolder()
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    defaultFolderUri(ready)
                )
            }
        }
        try {
            activity.startActivityForResult(intent, REQUEST_LIBRARY)
        } catch (e: Exception) {
            pendingLink = null
            result.error("picker_failed", e.message ?: "No file manager available", null)
        }
    }

    /** Called from the activity once the tree picker returns. */
    fun onTreePicked(resultCode: Int, data: Intent?) {
        val result = pendingLink ?: return
        pendingLink = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            result.success(null)
            return
        }
        try {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: Exception) {
            // Providers without persistable grants still work for this session.
        }
        try {
            // Land INSIDE "ReelTune Audios": if the user picked Download (or any
            // parent), step into the app folder, creating it if needed.
            val rootId = resolveRoot(uri)
            prefs.edit()
                .putString(KEY_TREE, uri.toString())
                .putString(KEY_ROOT, rootId)
                .apply()
            result.success(stateMap())
        } catch (e: Exception) {
            result.error("link_failed", e.message ?: "Could not open that folder", null)
        }
    }

    private fun unlink(): Boolean {
        val uri = treeUri()
        if (uri != null) {
            try {
                context.contentResolver.releasePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            } catch (_: Exception) {
            }
        }
        prefs.edit().remove(KEY_TREE).remove(KEY_ROOT).apply()
        return true
    }

    fun treeUri(): Uri? =
        prefs.getString(KEY_TREE, null)?.let { Uri.parse(it) }

    private fun rootDocId(): String? {
        val uri = treeUri() ?: return null
        val stored = prefs.getString(KEY_ROOT, null)
        if (stored != null) return stored
        return DocumentsContract.getTreeDocumentId(uri)
    }

    /**
     * True when the saved tree still resolves right now.
     *
     * Persisted grants survive reboots but NOT reinstalls, a system permission
     * reset, or an OEM "clean up" pass. When the grant is gone the folder still
     * looks linked (the URI is in our prefs) but every document read fails —
     * which on the player side shows up as "Source error". Asking for a cheap
     * read of the root separates "grant gone" from "file deleted".
     */
    private fun probe(): Boolean {
        val uri = treeUri() ?: return false
        val granted = context.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission
        }
        if (!granted) return false
        val rootId = rootDocId() ?: return false
        return try {
            context.contentResolver.query(
                DocumentsContract.buildChildDocumentsUriUsingTree(uri, rootId),
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null,
                null,
                null,
            )?.use { true } ?: false
        } catch (_: Exception) {
            false
        }
    }

    private fun stateMap(): Map<String, Any?> {
        val uri = treeUri()
        if (uri == null) return mapOf("linked" to false)
        val canWrite = context.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isWritePermission
        }
        return mapOf(
            "linked" to true,
            "uri" to uri.toString(),
            "name" to displayName(uri),
            "writable" to canWrite,
        )
    }

    private fun resolveRoot(treeUri: Uri): String {
        val treeId = DocumentsContract.getTreeDocumentId(treeUri)
        val treeName = documentName(treeUri, treeId) ?: ""
        if (treeName.equals(APP_FOLDER, ignoreCase = true)) return treeId
        if (!treeName.equals("Download", ignoreCase = true)) return treeId
        // Inside Download: reuse or create "ReelTune Audios".
        findChild(treeUri, treeId, APP_FOLDER, dir = true)?.let { return it }
        val created = DocumentsContract.createDocument(
            context.contentResolver,
            DocumentsContract.buildDocumentUriUsingTree(treeUri, treeId),
            DocumentsContract.Document.MIME_TYPE_DIR,
            APP_FOLDER,
        ) ?: return treeId
        return DocumentsContract.getDocumentId(created).substringAfterLast(':')
    }

    // ---- scan --------------------------------------------------------------

    /** Every audio/video file under the linked folder, with its document URI. */
    private fun scan(): List<Map<String, Any?>> {
        val uri = treeUri() ?: return emptyList()
        val rootId = rootDocId() ?: return emptyList()
        val out = ArrayList<Map<String, Any?>>()
        walk(uri, rootId, out, 0)
        return out
    }

    private fun walk(
        treeUri: Uri,
        documentId: String,
        out: MutableList<Map<String, Any?>>,
        depth: Int,
    ) {
        if (depth > 4) return
        val children =
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        context.contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_SIZE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                val mime = cursor.getString(2) ?: ""
                if (name.startsWith(".")) continue
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walk(treeUri, id, out, depth + 1)
                } else if (isMedia(mime, name)) {
                    out.add(
                        mapOf(
                            "uri" to DocumentsContract
                                .buildDocumentUriUsingTree(treeUri, id).toString(),
                            "name" to name,
                            "mime" to mime,
                            "size" to cursor.getLong(4),
                            "modified" to cursor.getLong(3),
                            "relative" to relativeDir(treeUri, id),
                        )
                    )
                }
            }
        }
    }

    /** "PlaylistName" when the file sits in a first-level sub-folder, else "". */
    private fun relativeDir(treeUri: Uri, documentId: String): String {
        val root = rootDocId() ?: return ""
        val path = DocumentsContract.getDocumentId(
            DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        ).substringAfter(':')
        val rootPath = DocumentsContract.getDocumentId(
            DocumentsContract.buildDocumentUriUsingTree(treeUri, root)
        ).substringAfter(':')
        val tail = path.removePrefix(rootPath).trim('/')
        if (!tail.contains('/')) return ""
        return tail.substringBefore('/')
    }

    // ---- writes ------------------------------------------------------------

    /** Copies [source] into the linked folder (optionally a sub-folder). */
    private fun save(source: File, name: String, subdir: String?): Map<String, Any?>? {
        val treeUri = treeUri() ?: return null
        val parentId = ensureDir(treeUri, subdir)
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)

        // Never overwrite: a second "Video from Instagram" becomes
        // "Video from Instagram 2". The library keeps both files.
        val finalName = uniqueChildName(treeUri, parentId, name)

        val mime = mimeFor(finalName)
        val docUri = DocumentsContract.createDocument(
            context.contentResolver, parentUri, mime, finalName
        ) ?: return null

        context.contentResolver.openOutputStream(docUri, "w")?.use { out ->
            source.inputStream().use { input -> input.copyTo(out, 64 * 1024) }
        } ?: return null

        val id = DocumentsContract.getDocumentId(docUri)
        return mapOf(
            "uri" to DocumentsContract.buildDocumentUriUsingTree(treeUri, id).toString(),
            "name" to finalName,
            "size" to source.length(),
        )
    }

    /** "Song.m4a" exists -> "Song 2.m4a", so saves never overwrite. */
    private fun uniqueChildName(treeUri: Uri, parentId: String, name: String): String {
        if (findChild(treeUri, parentId, name, dir = false) == null) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var index = 2
        while (findChild(treeUri, parentId, "$base $index$ext", dir = false) != null) {
            index++
        }
        return "$base $index$ext"
    }

    private fun ensureDir(treeUri: Uri, subdir: String?): String {
        val root = rootDocId()!!
        if (subdir.isNullOrBlank()) return root
        findChild(treeUri, root, subdir, dir = true)?.let { return it }
        val created = DocumentsContract.createDocument(
            context.contentResolver,
            DocumentsContract.buildDocumentUriUsingTree(treeUri, root),
            DocumentsContract.Document.MIME_TYPE_DIR,
            subdir,
        )
        return if (created != null) {
            DocumentsContract.getDocumentId(created).substringAfterLast(':')
        } else root
    }

    private fun readText(name: String): String? {
        val treeUri = treeUri() ?: return null
        val root = rootDocId() ?: return null
        val id = findChild(treeUri, root, name, dir = false) ?: return null
        return try {
            context.contentResolver.openInputStream(
                DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
            )?.bufferedReader()?.use { it.readText() }
        } catch (_: Exception) {
            null
        }
    }

    private fun writeText(name: String, text: String): Boolean {
        val treeUri = treeUri() ?: return false
        val root = rootDocId() ?: return false
        return try {
            val existing = findChild(treeUri, root, name, dir = false)
            val docUri = if (existing != null) {
                DocumentsContract.buildDocumentUriUsingTree(treeUri, existing)
            } else {
                DocumentsContract.createDocument(
                    context.contentResolver,
                    DocumentsContract.buildDocumentUriUsingTree(treeUri, root),
                    "application/json",
                    name,
                )
            } ?: return false
            context.contentResolver.openOutputStream(docUri, "wt")?.use {
                it.write(text.toByteArray())
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun delete(uriString: String): Boolean {
        val treeUri = treeUri() ?: return false
        return try {
            val uri = Uri.parse(uriString)
            val id = DocumentsContract.getDocumentId(uri)
            deleteById(treeUri, id)
        } catch (_: Exception) {
            false
        }
    }

    private fun deleteById(treeUri: Uri, documentId: String): Boolean = try {
        DocumentsContract.deleteDocument(
            context.contentResolver,
            DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        )
    } catch (_: Exception) {
        false
    }

    private fun openDocument(uriString: String): Boolean = try {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.parse(uriString), "audio/*")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }

    // ---- helpers -----------------------------------------------------------

    private fun findChild(
        treeUri: Uri,
        parentId: String,
        name: String,
        dir: Boolean,
    ): String? {
        val children =
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        context.contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0) ?: continue
                val childName = cursor.getString(1) ?: continue
                val mime = cursor.getString(2) ?: ""
                val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR
                if (isDir != dir) continue
                if (childName.equals(name, ignoreCase = true)) return id
            }
        }
        return null
    }

    private fun documentName(treeUri: Uri, documentId: String): String? = try {
        context.contentResolver.query(
            DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId),
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
    } catch (_: Exception) {
        null
    }

    private fun displayName(uri: Uri): String? = try {
        val id = DocumentsContract.getDocumentId(uri)
        documentName(uri, id)
    } catch (_: Exception) {
        null
    }

    private fun isMedia(mime: String, name: String): Boolean {
        if (mime.startsWith("audio/") || mime.startsWith("video/")) return true
        return name.substringAfterLast('.', "").lowercase() in MEDIA_EXTENSIONS
    }

    private fun mimeFor(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "mp3" -> "audio/mpeg"
        "m4a" -> "audio/mp4"
        "aac" -> "audio/aac"
        "wav" -> "audio/wav"
        "ogg", "oga" -> "audio/ogg"
        "opus" -> "audio/opus"
        "flac" -> "audio/flac"
        "webm" -> "video/webm"
        "mp4" -> "video/mp4"
        "mkv" -> "video/x-matroska"
        else -> "application/octet-stream"
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        Thread {
            var value: Any? = null
            var error: Exception? = null
            try {
                value = block()
            } catch (e: Exception) {
                error = e
            }
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                if (error != null) {
                    result.error("folder_error", error.message ?: error.toString(), null)
                } else {
                    result.success(value)
                }
            }
        }.start()
    }

    private fun launchLink(result: MethodChannel.Result, preferDefault: Boolean) {
        val activity = context as? Activity
        if (activity == null) {
            result.error("no_activity", "Folder picker needs the app window", null)
            return
        }
        requestLink(activity, result, preferDefault)
    }

    /**
     * Document URI the picker should start on: ReelTune Audios when it exists
     * (or was just created), otherwise Download (resolveRoot then steps into
     * the app folder).
     *
     * The existence check must come from [ensureDefaultFolder], not from
     * File.isDirectory: Android 11+ hides Download from raw file access even
     * when the folder is there.
     */
    private fun defaultFolderUri(folderReady: Boolean): Uri {
        val id = if (folderReady) {
            "primary:Download/$APP_FOLDER"
        } else {
            "primary:Download"
        }
        return DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            id,
        )
    }

    /**
     * Creates `Downloads/ReelTune Audios` ahead of the picker.
     *
     * Android 11+ refuses raw mkdirs() in Download, so on scoped storage the
     * directory is created through MediaStore with one tiny hidden marker
     * (".reeltune"). The marker keeps the folder from disappearing and is
     * skipped by the scanner. Android 9 and older can just mkdirs() it.
     */
    private fun ensureDefaultFolder(): Boolean {
        val legacy = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            APP_FOLDER,
        )
        if (legacy.isDirectory) return true
        if (Build.VERSION.SDK_INT < 29) {
            return try {
                legacy.mkdirs() || legacy.isDirectory
            } catch (_: Exception) {
                false
            }
        }
        return try {
            // Already created on an earlier run: do not add a second marker.
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val markerExists = context.contentResolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND " +
                    "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
                arrayOf("${Environment.DIRECTORY_DOWNLOADS}/$APP_FOLDER/", ".reeltune"),
                null,
            )?.use { it.moveToFirst() } ?: false
            if (markerExists) return true
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, ".reeltune")
                put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    "${Environment.DIRECTORY_DOWNLOADS}/$APP_FOLDER",
                )
            }
            context.contentResolver.insert(collection, values) != null ||
                legacy.isDirectory
        } catch (_: Exception) {
            legacy.isDirectory
        }
    }

    /** Cheap "does this content URI still resolve" check. */
    private fun exists(uriString: String): Boolean = try {
        context.contentResolver.query(
            Uri.parse(uriString),
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
            null,
            null,
            null,
        )?.use { it.moveToFirst() } ?: false
    } catch (_: Exception) {
        false
    }

    companion object {
        const val CHANNEL = "com.buildwithanshul.reeltunes/folder"
        const val REQUEST_LIBRARY = 4314
        const val APP_FOLDER = "ReelTune Audios"
        private const val PREFS = "reeltunes_folder"
        private const val KEY_TREE = "tree"
        private const val KEY_ROOT = "rootDocId"
        private val MEDIA_EXTENSIONS = setOf(
            "mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac",
            "mp4", "mkv", "webm", "avi", "m4v", "mov", "3gp"
        )
    }
}
