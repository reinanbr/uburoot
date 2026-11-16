// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.bridge

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import com.reinanbr.uburoot.R
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.Sh
import com.reinanbr.uburoot.root.UbuPaths
import com.reinanbr.uburoot.ui.MainActivity
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The Android end of the uburoot-* commands. Ubuntu sends them with
 * `am broadcast` through the root helper uburoot-send (chroot-send.sh): the
 * receiver is protected by a signature permission that only root, the system
 * and this app pass. `am broadcast` is ordered, so the answer goes back to the
 * terminal: RESULT_OK, or result 1 with the error message as result data.
 */
class CommandReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val app = context.applicationContext
        val cmd = intent.getStringExtra("cmd")
        if (cmd == "open" && intent.getStringExtra("url") == null) {
            // Taking the file from the outbox needs root: off the main thread,
            // with the broadcast (and its background-activity-start grant) kept
            // open until the viewer has started.
            val pending = goAsync()
            scope.launch {
                // null = timed out; the Result holds null (done) or the error text.
                val outcome = withTimeoutOrNull(OPEN_TIMEOUT_MS) { runCatching { openFile(app, intent) } }
                val error = if (outcome == null) {
                    app.getString(R.string.bridge_timeout)
                } else {
                    outcome.fold({ it }, ::message)
                }
                pending.resultCode = if (error == null) Activity.RESULT_OK else RESULT_ERROR
                pending.resultData = error
                pending.finish()
            }
            return
        }
        val error = runCatching { handle(app, cmd, intent) }.fold({ it }, ::message)
        resultCode = if (error == null) Activity.RESULT_OK else RESULT_ERROR
        resultData = error
    }

    private fun message(e: Throwable): String {
        Log.w(TAG, "bridge command failed", e)
        return e.message ?: e.toString()
    }

    /** null = done, else the error shown in the terminal. */
    private fun handle(app: Context, cmd: String?, intent: Intent): String? = when (cmd) {
        "notify" -> notify(app, intent.getStringExtra("title").orEmpty(), intent.getStringExtra("text").orEmpty())

        "toast" -> {
            Toast.makeText(app, intent.getStringExtra("text").orEmpty(), Toast.LENGTH_LONG).show()
            null
        }

        "vibrate" -> vibrate(app, intent.getStringExtra("ms")?.toLongOrNull()?.coerceIn(1, MAX_VIBRATE_MS) ?: 300)

        "clip" -> {
            val cm = app.getSystemService(ClipboardManager::class.java)
            cm.setPrimaryClip(ClipData.newPlainText("UbuRoot", intent.getStringExtra("text").orEmpty()))
            null
        }

        "open" -> openUrl(app, intent.getStringExtra("url").orEmpty())

        else -> app.getString(R.string.bridge_unknown_command, cmd.orEmpty())
    }

    private fun notify(app: Context, title: String, text: String): String? {
        val nm = NotificationManagerCompat.from(app)
        if (!nm.areNotificationsEnabled()) return app.getString(R.string.bridge_notifications_off)
        app.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(
                CHANNEL,
                app.getString(R.string.bridge_channel),
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
        if (nm.getNotificationChannelCompat(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) {
            return app.getString(R.string.bridge_notifications_off)
        }
        val tap = PendingIntent.getActivity(
            app,
            0,
            Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(app, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text.ifEmpty { null })
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build()
        @Suppress("MissingPermission") // checked: areNotificationsEnabled()
        nm.notify(nextId.incrementAndGet(), n)
        return null
    }

    private fun vibrate(app: Context, ms: Long): String? {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            app.getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            app.getSystemService(Vibrator::class.java)
        }
        if (vibrator == null || !vibrator.hasVibrator()) return app.getString(R.string.bridge_no_vibrator)
        vibrator.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
        return null
    }

    private fun openUrl(app: Context, url: String): String? {
        val uri = url.toUri()
        if (uri.scheme.isNullOrEmpty()) return app.getString(R.string.bridge_bad_url, url)
        return view(app, Intent(Intent.ACTION_VIEW, uri), url)
    }

    /** Copies the outbox file into our cache and hands it to a viewer through FileProvider. */
    private suspend fun openFile(app: Context, intent: Intent): String? {
        val id = intent.getStringExtra("id").orEmpty()
        if (!ID.matches(id)) return app.getString(R.string.bridge_bad_request)
        val name = SharedPaths.safeName(intent.getStringExtra("name"))
        val root = File(app.cacheDir, OPEN_DIR)
        pruneOld(root)
        val dir = File(root, id)
        dir.mkdirs()
        val file = File(dir, name)
        // Created by the app, so owner and SELinux label are ours; root only writes into it.
        file.createNewFile()
        val r = RootShell.run("${UbuPaths.script("bridge.sh")} take ${Sh.quote(id)} ${Sh.quote(file.absolutePath)}")
        if (!r.ok) {
            dir.deleteRecursively()
            return app.getString(R.string.bridge_take_failed, r.text)
        }
        val uri = FileProvider.getUriForFile(app, "${app.packageName}.files", file)
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mimeOf(name, intent.getStringExtra("mime")))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return view(app, view, name)
    }

    private fun view(app: Context, view: Intent, what: String): String? = try {
        app.startActivity(view.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        null
    } catch (_: ActivityNotFoundException) {
        app.getString(R.string.bridge_no_app, what)
    }

    companion object {
        const val ACTION = "com.reinanbr.uburoot.CMD"
        private const val TAG = "UbuRoot"
        private const val CHANNEL = "messages"
        private const val OPEN_DIR = "open"
        private const val RESULT_ERROR = 1
        private const val MAX_VIBRATE_MS = 10_000L
        private const val OPEN_TIMEOUT_MS = 8_000L // a foreground broadcast gets 10 s
        private const val KEEP_MS = 24 * 3600 * 1000L
        private val ID = Regex("[0-9a-f]{16}")
        private val nextId = AtomicInteger(1000)
        private val scope = MainScope()

        /** The extension's type is what viewers register for; `file`'s guess comes second. */
        fun mimeOf(name: String, sniffed: String?): String {
            val ext = name.substringAfterLast('.', "").lowercase()
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
                ?: sniffed?.takeIf { MIME.matches(it) && it != "application/octet-stream" }
                ?: "application/octet-stream"
        }

        private val MIME = Regex("[a-z]+/[a-zA-Z0-9.+_-]+")

        /** Files handed to viewers stay a day: the viewer may read them long after the start. */
        private fun pruneOld(root: File) {
            val old = System.currentTimeMillis() - KEEP_MS
            root.listFiles()?.filter { it.lastModified() < old }?.forEach { it.deleteRecursively() }
        }
    }
}
