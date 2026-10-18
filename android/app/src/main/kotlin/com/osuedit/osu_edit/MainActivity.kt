package com.osuedit.osu_edit

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Receives `.osz` beatmap sets and `.osk` skins opened with / shared to the
 * app ("Open with", share sheet). Each one is copied into `<documents>/Inbox` — the folder
 * path_provider's getApplicationDocumentsDirectory() returns on Android —
 * where the library screen lists it as a pending import, then Dart is told
 * to refresh over the `osuedit/incoming` channel.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val LAZER_PACKAGE = "sh.ppy.osulazer"
    }

    private var channel: MethodChannel? = null

    /** Audio focus and unplug handling while the editor plays. */
    internal var audioSession: AudioSession? = null

    // Main thread only. Files that arrive before Dart listens (cold start) are
    // announced in the reply to its "ready" call instead of being lost.
    private var dartReady = false
    private var unannounced = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioSession = AudioSession(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        channel =MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "osuedit/incoming").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "ready") {
                    dartReady = true
                    result.success(unannounced)
                    unannounced = false
                } else if (call.method == "openDefaultAppSettings") {
                    result.success(openDefaultAppSettings())
                } else if (call.method == "openFolder") {
                    result.success(openFolder(call.arguments as String))
                } else if (call.method == "openUrl") {
                    result.success(openUrl(call.arguments as String))
                } else if (call.method == "appVersion") {
                    result.success(appVersion())
                } else if (call.method == "installApk") {
                    result.success(installApk(call.arguments as String))
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    /**
     * Opens the App info screen of osu!lazer if installed (that is where its
     * "Open by default" → "Clear defaults" lives, which is what makes Android
     * stop sending .osz to lazer), else of this app. Returns "lazer" / "self",
     * or null if the screen could not be opened.
     */
    private fun openDefaultAppSettings(): String? {
        val lazerInstalled = try {
            packageManager.getPackageInfo(LAZER_PACKAGE, 0)
            true
        } catch (e: Exception) {
            false
        }
        val target = if (lazerInstalled) LAZER_PACKAGE else packageName
        return try {
            startActivity(
                Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$target"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            if (lazerInstalled) "lazer" else "self"
        } catch (e: Exception) {
            android.util.Log.w("osuEdit", "Could not open app settings for $target", e)
            null
        }
    }

    /**
     * Opens the library folder at [path] in the system Files app, through
     * [LibraryDocumentsProvider]. Returns "folder", "root" (only the
     * library's root could be opened) or null (no Files app / not in the
     * library).
     */
    private fun openFolder(path: String): String? {
        val id = LibraryDocumentsProvider.documentIdOf(this, File(path)) ?: return null
        val authority = LibraryDocumentsProvider.authority(this)
        val attempts = listOf(
            "folder" to Intent(Intent.ACTION_VIEW).setDataAndType(
                DocumentsContract.buildDocumentUri(authority, id), DocumentsContract.Document.MIME_TYPE_DIR),
            "root" to Intent(Intent.ACTION_VIEW).setDataAndType(
                DocumentsContract.buildRootUri(authority, LibraryDocumentsProvider.ROOT_ID), "vnd.android.document/root"),
        )
        for ((what, intent) in attempts) {
            // Same task: Back in the Files app returns here.
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            try {
                startActivity(intent)
                return what
            } catch (e: Exception) {
                android.util.Log.w("osuEdit", "Could not open $what for $path", e)
            }
        }
        return null
    }

    /** Opens a web page in the browser; false if none could be started. */
    private fun openUrl(url: String): Boolean = try {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        true
    } catch (e: Exception) {
        android.util.Log.w("osuEdit", "Could not open $url", e)
        false
    }

    /** The installed versionName (pubspec `version` before the `+`). */
    private fun appVersion(): String? = try {
        packageManager.getPackageInfo(packageName, 0).versionName
    } catch (e: Exception) {
        null
    }

    /**
     * Hands a downloaded APK (in the cache's `updates` folder) to the system
     * installer. Returns "started", "permission" (the "install unknown apps"
     * switch of this app was off: its settings page is opened) or null.
     */
    private fun installApk(path: String): String? {
        return try {
            val file = File(path)
            val updates = File(cacheDir, "updates").canonicalFile
            if (!file.canonicalFile.startsWith(updates) || !file.name.endsWith(".apk")) return null
            if (!packageManager.canRequestPackageInstalls()) {
                startActivity(
                    Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                )
                return "permission"
            }
            val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.updates", file)
            startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, "application/vnd.android.package-archive")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            )
            "started"
        } catch (e: Exception) {
            android.util.Log.w("osuEdit", "Could not install $path", e)
            null
        }
    }

    private fun announce() {
        if (dartReady) channel?.invokeMethod("changed", null) else unannounced = true
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Not on a re-creation (rotation etc.): that intent was handled already.
        if (savedInstanceState == null) receive(intent)
    }

    override fun onDestroy() {
        audioSession?.release()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receive(intent)
    }

    private fun receive(intent: Intent?) {
        val uris = urisOf(intent ?: return)
        if (uris.isEmpty()) return
        val inbox = File(getDir("flutter", MODE_PRIVATE), "Inbox")
        val main = Handler(Looper.getMainLooper())
        // Copies can be large (tens of MB from a cloud provider): off the main thread.
        Thread {
            var copied = 0
            for (uri in uris) {
                try {
                    inbox.mkdirs()
                    val target = uniqueFile(inbox, archiveName(uri, intent.type))
                    contentResolver.openInputStream(uri)?.use { input ->
                        target.outputStream().use { input.copyTo(it) }
                        copied++
                    }
                } catch (e: Exception) {
                    android.util.Log.w("osuEdit", "Could not receive $uri", e)
                }
            }
            if (copied > 0) main.post { announce() }
        }.start()
    }

    @Suppress("DEPRECATION")
    private fun urisOf(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_VIEW -> listOfNotNull(intent.data)
        Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM))
        Intent.ACTION_SEND_MULTIPLE ->
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.toList() ?: emptyList()
        else -> emptyList()
    }

    /**
     * The provider's display name (or the path's last segment), ending in
     * .osk for skins (by name or MIME type), else .osz (Dart also recognises
     * a skin inside a nameless .osz).
     */
    private fun archiveName(uri: Uri, intentType: String?): String {
        var name: String? = null
        if (uri.scheme == "content") {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) name = it.getString(0)
            }
        }
        val base = (name ?: uri.lastPathSegment ?: "shared")
            .substringAfterLast('/')
            .replace(Regex("[\\/:*?\"<>|]"), "_")
            .ifBlank { "shared" }
        val lower = base.lowercase()
        if (lower.endsWith(".osz") || lower.endsWith(".osk")) return base
        val mime = (if (uri.scheme == "content") contentResolver.getType(uri) else null) ?: intentType
        return if (mime == "application/x-osu-skin-archive") "$base.osk" else "$base.osz"
    }

    private fun uniqueFile(dir: File, name: String): File {
        var f = File(dir, name)
        var n = 2
        val ext = name.substringAfterLast('.', "osz")
        val stem = name.substring(0, name.length - ext.length - 1)
        while (f.exists()) f = File(dir, "$stem ($n).$ext").also { n++ }
        return f
    }
}
