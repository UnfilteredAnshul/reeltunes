package com.buildwithanshul.reeltunes

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * Durable record of the Privacy Policy / Terms acceptance.
 *
 * Why this is native: Play wants a record that the user agreed to the policy
 * that shipped with the build, and Flutter's SharedPreferences are deleted by
 * "Clear data" and by an uninstall. A JSON file in
 * Download/ReelTunes/consent.json through MediaStore survives both, is not in
 * the audios folder, and can be read back after a reinstall to ask the user to
 * confirm again.
 *
 * API < 29 has no MediaStore Downloads collection, so the JSON is mirrored in
 * the app's own prefs there; the Dart side keeps its own copy either way.
 */
class ConsentBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val prefs =
        context.getSharedPreferences("reeltunes_consent", Context.MODE_PRIVATE)

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> result.success(read())
                "write" -> {
                    val at = call.argument<Number>("acceptedAtMs")?.toLong()
                        ?: System.currentTimeMillis()
                    val version = call.argument<String>("policyVersion") ?: ""
                    result.success(write(at, version))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun read(): Map<String, Any?> {
        val durable = readDurable()
        val json = durable ?: readPrefs()
        val map = HashMap<String, Any?>()
        map["durable"] = durable != null
        if (json == null) {
            map["found"] = false
            map["agreed"] = false
            return map
        }
        val agreed = json.optBoolean("agreed", false)
        map["found"] = agreed
        map["agreed"] = agreed
        map["acceptedAtMs"] = json.optLong("acceptedAtMs", 0L)
        map["firstAcceptedAtMs"] = json.optLong("firstAcceptedAtMs", 0L)
        map["policyVersion"] = json.optString("policyVersion", "")
        val history = json.optJSONArray("acceptances")
        val stamps = ArrayList<Long>()
        if (history != null) {
            for (i in 0 until history.length()) {
                val entry = history.optJSONObject(i) ?: continue
                val at = entry.optLong("atMs", 0L)
                if (at > 0L) stamps.add(at)
            }
        }
        map["acceptances"] = stamps
        return map
    }

    /**
     * Returns true when the durable file was written. The in-app pref mirror is
     * always updated first so a MediaStore refusal (OEM builds that hide the
     * Downloads collection) still leaves a usable local record.
     */
    private fun write(atMs: Long, version: String): Boolean {
        val previous = readDurable() ?: readPrefs()
        val history = previous?.optJSONArray("acceptances") ?: JSONArray()
        val merged = JSONArray()
        merged.put(JSONObject().put("atMs", atMs).put("policyVersion", version))
        for (i in 0 until history.length()) {
            if (merged.length() >= MAX_HISTORY) break
            history.optJSONObject(i)?.let { merged.put(it) }
        }
        val first = previous?.optLong("firstAcceptedAtMs", 0L) ?: 0L
        val json = JSONObject().apply {
            put("agreed", true)
            put("acceptedAtMs", atMs)
            put("firstAcceptedAtMs", if (first > 0L) first else atMs)
            put("policyVersion", version)
            put("acceptances", merged)
        }
        prefs.edit().putString(KEY, json.toString()).apply()
        return writeDurable(json.toString())
    }

    // ---- MediaStore (Download/ReelTunes/consent.json) --------------------

    private fun durableUri(): Uri? {
        if (Build.VERSION.SDK_INT < 29) return null
        return try {
            context.contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND " +
                    "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
                arrayOf("${Environment.DIRECTORY_DOWNLOADS}/$FOLDER/", FILE_NAME),
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    ContentUris.withAppendedId(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                        cursor.getLong(0),
                    )
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun readDurable(): JSONObject? {
        val uri = durableUri() ?: return null
        return try {
            context.contentResolver.openInputStream(uri)?.use { stream ->
                val text = stream.bufferedReader().use { it.readText() }
                if (text.isBlank()) null else JSONObject(text)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun writeDurable(text: String): Boolean {
        if (Build.VERSION.SDK_INT < 29) return false
        return try {
            val existing = durableUri()
            val uri = existing ?: context.contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, FILE_NAME)
                    put(MediaStore.MediaColumns.MIME_TYPE, "application/json")
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER",
                    )
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                },
            ) ?: return false
            val bytes = text.toByteArray(Charsets.UTF_8)
            context.contentResolver.openOutputStream(uri, "wt")?.use { out ->
                out.write(bytes)
            } ?: return false
            if (existing == null) {
                context.contentResolver.update(
                    uri,
                    ContentValues().apply {
                        put(MediaStore.MediaColumns.IS_PENDING, 0)
                    },
                    null,
                    null,
                )
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun readPrefs(): JSONObject? {
        val raw = prefs.getString(KEY, null) ?: return null
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        const val CHANNEL = "com.buildwithanshul.reeltunes/consent"

        /// Deliberately outside the audios folder: the user may delete or
        /// re-pick that folder, and consent is not media.
        private const val FOLDER = "ReelTunes"
        private const val FILE_NAME = "consent.json"
        private const val KEY = "consent_json"
        private const val MAX_HISTORY = 12
    }
}
