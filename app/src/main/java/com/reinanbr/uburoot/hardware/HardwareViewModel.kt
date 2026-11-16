// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.hardware

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.reinanbr.uburoot.install.ConfigStore
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.Sh
import com.reinanbr.uburoot.root.UbuPaths
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class HardwareState(
    val loading: Boolean = true,
    val status: HardwareStatus? = null,
    /** DEFAULT_USER from uburoot.conf; empty = root (needs no grants). */
    val user: String = "",
    val busy: Boolean = false,
    /** Output of the last action (hardware.sh's own messages). */
    val output: String = "",
    /** `hardware.sh info CLASS` of the class the user opened. */
    val info: Pair<String, String>? = null,
)

/**
 * The Hardware screen: everything goes through hardware.sh on the Android side, which
 * records each change in the same log as kernel.sh (Stop all reverts both). The app
 * asks for confirmation itself, so the commands get -y.
 */
class HardwareViewModel(app: Application) : AndroidViewModel(app) {
    private val _state = MutableStateFlow(HardwareState())
    val state: StateFlow<HardwareState> = _state.asStateFlow()

    private val hw = UbuPaths.script("hardware.sh")

    fun refresh() = viewModelScope.launch { reload() }

    private suspend fun reload() {
        val status = HardwareStatus.parse(RootShell.run("$hw status").out)
        val user = runCatching { ConfigStore.read().defaultUser }.getOrDefault("")
        _state.update { it.copy(loading = false, status = status, user = user) }
    }

    fun grant(cls: String, on: Boolean) {
        val user = _state.value.user
        if (user.isEmpty()) return
        act("$hw -y ${if (on) "grant" else "revoke"} ${Sh.quote(cls)} ${Sh.quote(user)}")
    }

    fun wifi(take: Boolean) = act("$hw -y ${if (take) "takeover" else "release"} wifi")

    fun wakeLock(on: Boolean) = act("$hw -y wakelock ${if (on) "on" else "off"}")

    /** The same revert as Stop all: every recorded kernel and hardware change. */
    fun revert() = act("${UbuPaths.script("kernel.sh")} -y revert")

    fun info(cls: String) = viewModelScope.launch {
        val text = RootShell.run("$hw info ${Sh.quote(cls)}").text
        _state.update { it.copy(info = cls to text.trim()) }
    }

    fun closeInfo() = _state.update { it.copy(info = null) }

    private fun act(cmd: String) {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true, output = "") }
        viewModelScope.launch {
            val out = try {
                RootShell.run(cmd).text
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                e.message ?: e.javaClass.simpleName
            }
            reload()
            _state.update { it.copy(busy = false, output = out.trim()) }
        }
    }
}
