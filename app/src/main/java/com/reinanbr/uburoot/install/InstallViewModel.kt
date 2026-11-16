// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.install

import android.annotation.SuppressLint
import android.app.Application
import android.net.Uri
import android.os.PowerManager
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.reinanbr.uburoot.root.RootInfo
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.ScriptDeployer
import com.reinanbr.uburoot.root.Sh
import com.reinanbr.uburoot.root.UbuPaths
import com.reinanbr.uburoot.terminal.SessionService
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Why the app cannot continue; the UI maps each one to a message. */
enum class Problem { NO_ROOT, NOT_GLOBAL_NAMESPACE, RESTRICTED_ROOT, NOT_ARM64, NO_SPACE, DEPLOY_FAILED }

enum class Step { DISCOVER, DOWNLOAD, COPY, EXTRACT, SETUP, MIGRATE }

sealed interface Stage {
    data object Checking : Stage
    data class Blocked(val problem: Problem, val info: RootInfo?, val detail: String = "") : Stage
    data class Form(val info: RootInfo) : Stage
    data class Working(val step: Step, val progress: Float? = null, val detail: String = "") : Stage
    data class Failed(val message: String) : Stage
    data object Ready : Stage
}

/** A rootfs archive the user picked (SAF) instead of the download; [sha256] may be empty. */
data class LocalArchive(val uri: Uri, val name: String, val sha256: String)

data class InstallRequest(
    val user: String,
    val password: String,
    val nopasswd: Boolean,
    /** http:// ports mirror, empty = ports.ubuntu.com (APT_MIRROR). */
    val mirror: String = "",
    val local: LocalArchive? = null,
)

class InstallViewModel(app: Application) : AndroidViewModel(app) {
    private val _stage = MutableStateFlow<Stage>(Stage.Checking)
    val stage: StateFlow<Stage> = _stage.asStateFlow()

    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log: StateFlow<List<String>> = _log.asStateFlow()

    private val downloadDir get() = File(getApplication<Application>().filesDir, "download")

    init {
        check()
    }

    fun check() {
        _stage.value = Stage.Checking
        viewModelScope.launch {
            _stage.value = preflight()
        }
    }

    private suspend fun preflight(): Stage {
        // A "Stop all" still unmounting: opening a session now would race mount.sh against umount.sh.
        SessionService.stopping.first { !it }
        if (!RootShell.isRoot()) return Stage.Blocked(Problem.NO_ROOT, null)
        val deployed = ScriptDeployer.deploy(getApplication())
        if (!deployed.ok) return Stage.Blocked(Problem.DEPLOY_FAILED, null, deployed.text)
        val info = ScriptDeployer.rootInfo()
        // A run killed between install.sh and its cleanup leaves the tarball.
        if (info.rootfsInstalled) withContext(Dispatchers.IO) { downloadDir.deleteRecursively() }
        return when {
            !info.globalNamespace -> Stage.Blocked(Problem.NOT_GLOBAL_NAMESPACE, info)

            !info.fullRoot -> Stage.Blocked(Problem.RESTRICTED_ROOT, info, info.rootDetail)

            !info.isArm64 -> Stage.Blocked(Problem.NOT_ARM64, info, info.arch)

            info.needsMigration -> migrate(info)

            info.rootfsInstalled && info.setupDone -> Stage.Ready

            !info.rootfsInstalled && (info.freeBytes ?: Long.MAX_VALUE) < MIN_FREE_BYTES ->
                Stage.Blocked(Problem.NO_SPACE, info)

            else -> Stage.Form(info)
        }
    }

    /** A newer app version brings integration files the installed rootfs doesn't have yet. */
    private suspend fun migrate(info: RootInfo): Stage {
        _log.value = emptyList()
        _stage.value = Stage.Working(Step.MIGRATE, detail = "${info.schema} → ${info.schemaCurrent}")
        val code = RootShell.stream("${UbuPaths.script("setup.sh")} --migrate", ::appendLog)
        return if (code == 0) Stage.Ready else Stage.Failed("setup.sh --migrate failed (exit $code)")
    }

    fun install(req: InstallRequest, info: RootInfo) {
        if (!UbuConfig.isValidUserName(req.user)) return
        if (req.mirror.isNotEmpty() && !UbuConfig.isValidMirror(req.mirror)) return
        _log.value = emptyList()
        viewModelScope.launch {
            // Android may stop an app whose screen goes off mid-install (NetHunter warns
            // about it too): the screen stays on while working (MainActivity) and the
            // CPU stays awake with this lock.
            val lock = wakeLock()
            _stage.value = try {
                runInstall(req, info)
                Stage.Ready
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                appendLog("ERROR: ${e.message ?: e.javaClass.simpleName}")
                Stage.Failed(e.message ?: e.javaClass.simpleName)
            } finally {
                if (lock.isHeld) lock.release()
            }
        }
    }

    @SuppressLint("WakelockTimeout") // it has one
    private fun wakeLock(): PowerManager.WakeLock = getApplication<Application>()
        .getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "uburoot:install")
        .apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_MS)
        }

    private suspend fun runInstall(req: InstallRequest, info: RootInfo) {
        if (!info.rootfsInstalled && req.local != null) {
            val archive = copyLocal(req.local)
            _stage.value = Stage.Working(Step.EXTRACT)
            val sha = req.local.sha256.lowercase()
            val code = RootShell.stream(
                "${UbuPaths.script("install.sh")} ${Sh.quote(archive.absolutePath)} ${Sh.quote(sha)}",
                ::appendLog,
            )
            withContext(Dispatchers.IO) { downloadDir.deleteRecursively() }
            if (code != 0) error("install.sh failed (exit $code)")
        } else if (!info.rootfsInstalled) {
            _stage.value = Stage.Working(Step.DISCOVER)
            val release = ReleaseDiscovery.discover()
            appendLog("Ubuntu ${release.version}: ${release.url}")
            appendLog("sha256 ${release.sha256}")

            val tarball = File(downloadDir, release.fileName)
            _stage.value = Stage.Working(Step.DOWNLOAD, 0f, release.version)
            Downloader().download(release.url, tarball, release.sha256) { done, total ->
                val p = if (total > 0) done.toFloat() / total else null
                _stage.value = Stage.Working(Step.DOWNLOAD, p, "${mb(done)} / ${if (total > 0) mb(total) else "?"}")
            }

            _stage.value = Stage.Working(Step.EXTRACT)
            val code = RootShell.stream(
                "${UbuPaths.script("install.sh")} ${Sh.quote(tarball.absolutePath)} ${release.sha256}",
                ::appendLog,
            )
            if (code != 0) error("install.sh failed (exit $code)")
            withContext(Dispatchers.IO) { downloadDir.deleteRecursively() }
        }

        // Keep what an earlier attempt (or a hand edit) left in the file.
        val previous = runCatching { ConfigStore.read() }.getOrDefault(UbuConfig())
        ConfigStore.write(getApplication(), previous.copy(defaultUser = req.user, aptMirror = req.mirror))

        _stage.value = Stage.Working(Step.SETUP)
        val args = buildString {
            append(UbuPaths.script("setup.sh")).append(" --user ").append(Sh.quote(req.user))
            if (req.nopasswd) append(" --nopasswd")
            if (req.password.isNotEmpty()) append(" --password-stdin")
        }
        // printf is a shell builtin, so the password never shows up in argv.
        val cmd = if (req.password.isNotEmpty()) "printf '%s\\n' ${Sh.quote(req.password)} | $args" else args
        val code = RootShell.stream(cmd, ::appendLog)
        if (code != 0) error("setup.sh failed (exit $code)")
    }

    /** Copies the picked archive into our files dir, where install.sh (root) reads it. */
    private suspend fun copyLocal(local: LocalArchive): File = withContext(Dispatchers.IO) {
        val app = getApplication<Application>()
        val resolver = app.contentResolver
        val total = resolver.query(local.uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else -1L
        } ?: -1L
        appendLog("local file: ${local.name}" + if (total > 0) " (${mb(total)})" else "")
        downloadDir.mkdirs()
        val out = File(downloadDir, LOCAL_NAME)
        val input = resolver.openInputStream(local.uri) ?: error("cannot open ${local.name}")
        input.use { src ->
            out.outputStream().use { dst ->
                val buf = ByteArray(1 shl 16)
                var done = 0L
                var shown = 0L
                while (true) {
                    val n = src.read(buf)
                    if (n < 0) break
                    dst.write(buf, 0, n)
                    done += n
                    if (done - shown >= 1 shl 20) {
                        shown = done
                        val p = if (total > 0) done.toFloat() / total else null
                        _stage.value = Stage.Working(Step.COPY, p, "${mb(done)} / ${if (total > 0) mb(total) else "?"}")
                    }
                }
            }
        }
        out
    }

    private fun appendLog(line: String) {
        _log.update { (it + line).takeLast(MAX_LOG_LINES) }
    }

    private fun mb(bytes: Long) = "%.1f MB".format(bytes / 1048576.0)

    companion object {
        const val MIN_FREE_BYTES = 3L * 1024 * 1024 * 1024
        private const val WAKE_LOCK_MS = 60 * 60 * 1000L
        private const val LOCAL_NAME = "local-rootfs.tar"

        private val SHA256 = Regex("[0-9a-fA-F]{64}")

        /** Empty (no check) or 64 hex digits, as install.sh accepts. */
        fun isValidSha256(s: String) = s.isEmpty() || SHA256.matches(s)
        private const val MAX_LOG_LINES = 1000
    }
}
