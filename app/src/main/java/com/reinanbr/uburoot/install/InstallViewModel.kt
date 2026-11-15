package com.reinanbr.uburoot.install

import android.app.Application
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
enum class Problem { NO_ROOT, NOT_GLOBAL_NAMESPACE, NOT_ARM64, NO_SPACE, DEPLOY_FAILED }

enum class Step { DISCOVER, DOWNLOAD, EXTRACT, SETUP }

sealed interface Stage {
    data object Checking : Stage
    data class Blocked(val problem: Problem, val info: RootInfo?, val detail: String = "") : Stage
    data class Form(val info: RootInfo) : Stage
    data class Working(val step: Step, val progress: Float? = null, val detail: String = "") : Stage
    data class Failed(val message: String) : Stage
    data object Ready : Stage
}

data class InstallRequest(val user: String, val password: String, val nopasswd: Boolean)

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

            !info.isArm64 -> Stage.Blocked(Problem.NOT_ARM64, info, info.arch)

            info.rootfsInstalled && info.setupDone -> Stage.Ready

            !info.rootfsInstalled && (info.freeBytes ?: Long.MAX_VALUE) < MIN_FREE_BYTES ->
                Stage.Blocked(Problem.NO_SPACE, info)

            else -> Stage.Form(info)
        }
    }

    fun install(req: InstallRequest, info: RootInfo) {
        if (!UbuConfig.isValidUserName(req.user)) return
        _log.value = emptyList()
        viewModelScope.launch {
            _stage.value = try {
                runInstall(req, info)
                Stage.Ready
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                appendLog("ERROR: ${e.message ?: e.javaClass.simpleName}")
                Stage.Failed(e.message ?: e.javaClass.simpleName)
            }
        }
    }

    private suspend fun runInstall(req: InstallRequest, info: RootInfo) {
        if (!info.rootfsInstalled) {
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
        ConfigStore.write(getApplication(), previous.copy(defaultUser = req.user))

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

    private fun appendLog(line: String) {
        _log.update { (it + line).takeLast(MAX_LOG_LINES) }
    }

    private fun mb(bytes: Long) = "%.1f MB".format(bytes / 1048576.0)

    companion object {
        const val MIN_FREE_BYTES = 3L * 1024 * 1024 * 1024
        private const val MAX_LOG_LINES = 1000
    }
}
