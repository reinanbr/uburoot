package com.reinanbr.uburoot.bridge

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.IntentCompat
import androidx.lifecycle.lifecycleScope
import com.reinanbr.uburoot.R
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.Sh
import com.reinanbr.uburoot.root.UbuPaths
import com.reinanbr.uburoot.terminal.SessionManager
import com.reinanbr.uburoot.terminal.TerminalActivity
import com.reinanbr.uburoot.ui.MainActivity
import com.reinanbr.uburoot.ui.UbuRootTheme
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * "Open in UbuRoot" share target: a new session in the shared file's directory.
 * Files on the phone's shared storage are already in Ubuntu (/sdcard); anything
 * else (another app's private file, an SD card, a cloud file) is copied into
 * ~/Shared of the default user first.
 */
class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            UbuRootTheme {
                Surface(Modifier.fillMaxSize()) {
                    Column(
                        Modifier.padding(24.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        CircularProgressIndicator()
                        Text(stringResource(R.string.share_working))
                    }
                }
            }
        }
        if (savedInstanceState == null) lifecycleScope.launch { open(intent) }
    }

    private suspend fun open(intent: Intent) {
        val cwd = runCatching { cwdFor(intent) }.getOrElse {
            Log.w(TAG, "share failed", it)
            Toast.makeText(
                this,
                getString(R.string.share_failed, it.message ?: it.toString()),
                Toast.LENGTH_LONG,
            ).show()
            null
        }
        // Live sessions mean the preflight already passed and the rootfs is in place.
        startActivity(
            if (SessionManager.sessions.isNotEmpty()) {
                TerminalActivity.intent(this, newSession = cwd != null, cwd = cwd)
            } else {
                MainActivity.intent(this, cwd)
            },
        )
        finish()
    }

    /** The directory inside Ubuntu for the shared item, importing it when it isn't there. */
    private suspend fun cwdFor(intent: Intent): String {
        val stream = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
        if (stream == null) {
            // Plain text (a link, a snippet): saved as a file too.
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: error(getString(R.string.share_nothing))
            return import(getString(R.string.share_text_name)) { it.writeText(text) }
        }
        val dir = withContext(Dispatchers.IO) { locate(stream) }
        if (dir != null && RootShell.run("${UbuPaths.script("bridge.sh")} cwd ${Sh.quote(dir)}").ok) return dir
        return import(SharedPaths.safeName(displayName(stream))) { f ->
            val input = contentResolver.openInputStream(stream) ?: error(getString(R.string.share_nothing))
            input.use { i -> f.outputStream().use { i.copyTo(it) } }
        }
    }

    /** Copies the item into our cache, then into ~/Shared through bridge.sh; returns that directory. */
    private suspend fun import(name: String, write: (File) -> Unit): String {
        val tmp = File(cacheDir, "share").apply { mkdirs() }.let { File(it, "incoming") }
        try {
            withContext(Dispatchers.IO) { write(tmp) }
            val r = RootShell.run(
                "${UbuPaths.script("bridge.sh")} import ${Sh.quote(tmp.absolutePath)} ${Sh.quote(name)}",
            )
            val dir = r.out.lastOrNull()?.trim()
            if (!r.ok || dir == null || !dir.startsWith("/")) error(r.text)
            return dir
        } finally {
            tmp.delete()
        }
    }

    /** Where the file is on the phone's shared storage, as a path inside Ubuntu (null: not there). */
    private fun locate(uri: Uri): String? {
        if (uri.scheme == ContentResolver.SCHEME_FILE) return uri.path?.let(SharedPaths::fromAndroidPath)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) return null
        if (DocumentsContract.isDocumentUri(this, uri)) {
            val id = DocumentsContract.getDocumentId(uri)
            when (uri.authority) {
                "com.android.externalstorage.documents" -> return SharedPaths.fromExternalStorageDocId(id)
                "com.android.providers.downloads.documents" -> SharedPaths.fromDownloadsDocId(id)?.let { return it }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            query(uri, MediaStore.MediaColumns.VOLUME_NAME, MediaStore.MediaColumns.RELATIVE_PATH)?.let { (vol, rel) ->
                SharedPaths.fromMediaStore(vol, rel)?.let { return it }
            }
        }
        @Suppress("DEPRECATION") // still filled in by MediaStore and many file managers
        return query(uri, MediaStore.MediaColumns.DATA)?.firstOrNull()?.let(SharedPaths::fromAndroidPath)
    }

    /** The columns' values for [uri], or null when the provider doesn't have them. */
    private fun query(uri: Uri, vararg columns: String): List<String?>? = runCatching {
        contentResolver.query(uri, columns, null, null, null)?.use { c ->
            if (!c.moveToFirst()) return@use null
            columns.map { col -> c.getColumnIndex(col).takeIf { it >= 0 }?.let(c::getString) }
                .takeIf { values -> values.any { it != null } }
        }
    }.getOrNull()

    private fun displayName(uri: Uri): String? =
        query(uri, OpenableColumns.DISPLAY_NAME)?.firstOrNull() ?: uri.lastPathSegment

    private companion object {
        const val TAG = "UbuRoot"
    }
}
