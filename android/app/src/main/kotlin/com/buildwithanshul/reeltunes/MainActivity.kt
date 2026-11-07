package com.buildwithanshul.reeltunes

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity is REQUIRED by just_audio_background: it wires the
// Flutter engine to the media session service. Without it, init() fails on
// the platform side and every play() throws LateInitializationError.
//
// Two Android concerns live here rather than in plugins:
//  1. picking media files / a media folder over the Storage Access Framework.
//     Scoped storage denies raw File access to DCIM, Movies and Download
//     (verified: EACCES as the app UID even on Android 13), and the granular
//     READ_MEDIA_* permissions do NOT re-enable directory listing — SAF does,
//     with no storage permission at all. Only content:// URIs are handed back,
//     so nothing is copied or moved.
//  2. clearing the media notification when ReelTunes is swiped out of recents.
class MainActivity : AudioServiceActivity() {
    private var leavingWithBack = false
    private var pendingMedia: MethodChannel.Result? = null
    private var engine: EngineBridge? = null
    private var folder: FolderBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+ hides the media notification until this grant exists.
        // Denying it does not stop playback, only the shade/lock-screen player.
        if (android.os.Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATIONS
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // On-device extractor: bundled CPython + yt-dlp, nothing downloaded.
        engine = EngineBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        // The audios folder as a SAF tree (saves land there, file-manager drops
        // are picked up by scan, playlists are mirrored inside it).
        folder = FolderBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickMediaFiles" -> launchPicker(result, folder = false)
                    "pickMediaFolder" -> launchPicker(result, folder = true)
                    else -> result.notImplemented()
                }
            }
    }

    private fun launchPicker(result: MethodChannel.Result, folder: Boolean) {
        // The picker UI is modal, so only one request can be in flight.
        if (pendingMedia != null) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }
        pendingMedia = result
        val intent = if (folder) {
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("audio/*", "video/*"))
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
        }
        intent.addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
        )
        try {
            startActivityForResult(
                intent,
                if (folder) REQUEST_FOLDER else REQUEST_FILES
            )
        } catch (e: Exception) {
            pendingMedia = null
            result.error(
                "picker_failed",
                e.message ?: "No file manager available",
                null
            )
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FolderBridge.REQUEST_LIBRARY) {
            folder?.onTreePicked(resultCode, data)
            return
        }
        if (requestCode != REQUEST_FILES && requestCode != REQUEST_FOLDER) return
        val pending = pendingMedia ?: return
        pendingMedia = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.success(emptyList<Map<String, Any?>>())
            return
        }

        val treeUri = if (requestCode == REQUEST_FOLDER) data.data else null
        val fileUris = ArrayList<Uri>()
        if (requestCode == REQUEST_FILES) {
            data.clipData?.let { clip ->
                for (i in 0 until clip.itemCount) fileUris.add(clip.getItemAt(i).uri)
            }
            data.data?.let { fileUris.add(it) }
        }

        // Persist the read grant so imported tracks keep playing after a
        // reboot (and after the app is swiped away).
        for (uri in fileUris) takeReadGrant(uri)
        if (treeUri != null) takeReadGrant(treeUri)

        Thread {
            val payload: List<Map<String, Any?>>? = try {
                when {
                    requestCode == REQUEST_FOLDER && treeUri != null ->
                        collectTree(treeUri)
                    requestCode == REQUEST_FOLDER -> emptyList()
                    else -> fileUris.mapNotNull { fileEntry(it) }
                }
            } catch (e: Exception) {
                null
            }
            runOnUiThread {
                if (payload == null) {
                    pending.error(
                        "read_failed",
                        "Could not read the selected media",
                        null
                    )
                } else {
                    pending.success(payload)
                }
            }
        }.start()
    }

    private fun takeReadGrant(uri: Uri) {
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (_: Exception) {
            // Non-persistable providers still work for this session.
        }
    }

    private fun fileEntry(uri: Uri): Map<String, Any?>? {
        val name = displayName(uri) ?: return null
        val mime = contentResolver.getType(uri) ?: ""
        if (!isMedia(mime, name)) return null
        return mapOf("uri" to uri.toString(), "name" to name, "mime" to mime)
    }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    } catch (_: Exception) {
        null
    }

    private fun collectTree(treeUri: Uri): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        walkTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri), out, 0)
        return out
    }

    /** Depth-first walk of a SAF tree; returns every audio/video document. */
    private fun walkTree(
        treeUri: Uri,
        documentId: String,
        out: MutableList<Map<String, Any?>>,
        depth: Int
    ) {
        if (depth > 6) return
        val children =
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE
            ),
            null,
            null,
            null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                val mime = cursor.getString(2) ?: ""
                if (name.startsWith(".")) continue
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walkTree(treeUri, id, out, depth + 1)
                } else if (isMedia(mime, name)) {
                    out.add(
                        mapOf(
                            "uri" to DocumentsContract
                                .buildDocumentUriUsingTree(treeUri, id)
                                .toString(),
                            "name" to name,
                            "mime" to mime
                        )
                    )
                }
            }
        }
    }

    private fun isMedia(mime: String, name: String): Boolean {
        if (mime.startsWith("audio/") || mime.startsWith("video/")) return true
        return name.substringAfterLast('.', "").lowercase() in MEDIA_EXTENSIONS
    }

    override fun onBackPressed() {
        leavingWithBack = true
        super.onBackPressed()
    }

    override fun onDestroy() {
        // isFinishing covers task removal; config changes are handled by the
        // activity itself, and background memory reclaims are not finishing.
        if (isFinishing && !isChangingConfigurations && !leavingWithBack) {
            clearMediaNotification()
        }
        super.onDestroy()
    }

    // Recents-swipe cleanup reuses audio_service's "notification deleted"
    // signal: it stops playback and takes the media notification/widget away.
    // The receiver is addressed by class NAME because its supertype lives in
    // a legacy androidx.media artifact that is not on this module's classpath.
    private fun clearMediaNotification() {
        try {
            sendBroadcast(
                Intent(ACTION_NOTIFICATION_DELETE).setClassName(
                    this,
                    AUDIO_SERVICE_MEDIA_BUTTON_RECEIVER
                )
            )
        } catch (_: Throwable) {
            // Nothing to clean up if the service already went away.
        }
    }
}

private val MEDIA_EXTENSIONS = setOf(
    "mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac",
    "mp4", "mkv", "webm", "avi", "m4v", "mov", "3gp"
)
private const val MEDIA_CHANNEL = "com.buildwithanshul.reeltunes/media"
private const val REQUEST_FILES = 4312
private const val REQUEST_FOLDER = 4313
private const val REQUEST_NOTIFICATIONS = 4315
private const val AUDIO_SERVICE_MEDIA_BUTTON_RECEIVER =
    "com.ryanheise.audioservice.MediaButtonReceiver"
private const val ACTION_NOTIFICATION_DELETE =
    "com.ryanheise.audioservice.intent.action.ACTION_NOTIFICATION_DELETE"
