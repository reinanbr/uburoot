// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.reinanbr.uburoot.install.ConfigStore
import com.reinanbr.uburoot.install.UbuConfig
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.Sh
import com.reinanbr.uburoot.root.UbuPaths
import com.reinanbr.uburoot.terminal.SessionManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class Notice {
    SAVED,
    SAVED_REPAIR_NEEDED,
    REPAIRED,
    REPAIR_FAILED,
    RESET_REFUSED,
    RESET_FAILED,
    BOOT_RAN,
    BOOT_FAILED,
}

/** State of the UbuRoot root module, from `boot.sh --status`. */
enum class ModuleState { ENABLED, DISABLED, REMOVING, PENDING, MISSING, UNKNOWN }

data class SettingsState(
    val loading: Boolean = true,
    val loadError: String? = null,
    /** What uburoot.conf holds now. */
    val saved: UbuConfig? = null,
    val users: List<String> = emptyList(),
    val module: ModuleState = ModuleState.UNKNOWN,
    val busy: Boolean = false,
    val log: List<String> = emptyList(),
    val notice: Notice? = null,
    /** The rootfs is gone: the screen hands over to the installer. */
    val resetDone: Boolean = false,
    val doctor: DoctorReport? = null,
    val doctorRunning: Boolean = false,
)

/** Output of doctor.sh; [redacted] = identifiers replaced (the default, what gets shared). */
data class DoctorReport(val text: String, val redacted: Boolean)

class SettingsViewModel(app: Application) : AndroidViewModel(app) {
    private val _state = MutableStateFlow(SettingsState())
    val state: StateFlow<SettingsState> = _state.asStateFlow()

    init {
        load()
    }

    fun load() {
        _state.update { it.copy(loading = true, loadError = null) }
        viewModelScope.launch {
            _state.update {
                try {
                    it.copy(
                        loading = false,
                        saved = ConfigStore.read(),
                        users = ConfigStore.users(),
                        module = moduleState(),
                    )
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    it.copy(loading = false, loadError = e.message ?: e.javaClass.simpleName)
                }
            }
        }
    }

    /** Writes uburoot.conf; a DNS change is applied to the rootfs right away. */
    fun save(config: UbuConfig) = work {
        val before = _state.value.saved
        ConfigStore.write(getApplication(), config)
        _state.update { it.copy(saved = config) }
        if (before?.dnsServers?.trim() != config.dnsServers.trim()) {
            val code = RootShell.stream("${UbuPaths.script("setup.sh")} --dns-only", ::log)
            if (code != 0) error("setup.sh --dns-only failed (exit $code)")
        }
        if (before?.aptMirror != config.aptMirror) {
            val code = RootShell.stream("${UbuPaths.script("setup.sh")} --sources-only", ::log)
            if (code != 0) error("setup.sh --sources-only failed (exit $code)")
        }
        // Mounts change only on Repair mounts / Stop all (a live mount is never pulled away).
        if (before != null && before.kernelAccess != config.kernelAccess) Notice.SAVED_REPAIR_NEEDED else Notice.SAVED
    }

    /** Closes every session, releases every mount (killing what is left) and mounts again. */
    fun repairMounts() = work {
        SessionManager.closeAll()
        val code = RootShell.stream(
            "${UbuPaths.script("umount.sh")} --kill && ${UbuPaths.script("mount.sh")}",
            ::log,
        )
        if (code == 0) Notice.REPAIRED else Notice.REPAIR_FAILED
    }

    /**
     * Deletes the rootfs. reset.sh unmounts first (umount.sh --kill) and refuses,
     * exit 3, while anything is still mounted under it (CLAUDE.md, critical rule).
     */
    fun reset() = work {
        SessionManager.closeAll()
        when (val code = RootShell.stream("${UbuPaths.script("reset.sh")} --yes", ::log)) {
            0 -> {
                _state.update { it.copy(resetDone = true) }
                null
            }

            3 -> Notice.RESET_REFUSED

            else -> {
                log("reset.sh: exit $code")
                Notice.RESET_FAILED
            }
        }
    }

    /** Runs boot.sh --now: mounts and starts the scripts in /etc/uburoot-boot.d (e.g. after Stop all). */
    fun runBootNow() = work {
        val code = RootShell.stream("${UbuPaths.script("boot.sh")} --now", ::log)
        if (code == 0) Notice.BOOT_RAN else Notice.BOOT_FAILED
    }

    private suspend fun moduleState(): ModuleState {
        val r = RootShell.run("${UbuPaths.script("boot.sh")} --status")
        val value = r.out.firstOrNull { it.startsWith("module=") }?.substringAfter('=')
        return ModuleState.entries.firstOrNull { it.name.equals(value, ignoreCase = true) } ?: ModuleState.UNKNOWN
    }

    /** Runs doctor.sh (read-only); [redact] hides IP addresses, user and host names, serials. */
    fun runDoctor(redact: Boolean) {
        if (_state.value.doctorRunning) return
        _state.update { it.copy(doctorRunning = true) }
        viewModelScope.launch {
            val app = getApplication<Application>()
            val version = runCatching { app.packageManager.getPackageInfo(app.packageName, 0).versionName }
                .getOrNull().orEmpty()
            val cmd = buildString {
                append(UbuPaths.script("doctor.sh"))
                if (redact) append(" --redact")
                if (version.isNotEmpty()) append(" --app-version ").append(Sh.quote(version))
            }
            val text = try {
                RootShell.run(cmd).text
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                "doctor.sh failed: ${e.message ?: e.javaClass.simpleName}"
            }
            _state.update { it.copy(doctorRunning = false, doctor = DoctorReport(text, redact)) }
        }
    }

    fun dismissNotice() = _state.update { it.copy(notice = null) }

    private fun work(block: suspend () -> Notice?) {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true, log = emptyList(), notice = null) }
        viewModelScope.launch {
            val notice = try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("ERROR: ${e.message ?: e.javaClass.simpleName}")
                null
            }
            _state.update { it.copy(busy = false, notice = notice) }
        }
    }

    private fun log(line: String) = _state.update { it.copy(log = (it.log + line).takeLast(MAX_LOG_LINES)) }

    private companion object {
        const val MAX_LOG_LINES = 500
    }
}
