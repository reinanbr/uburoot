// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.kernel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.Sh
import com.reinanbr.uburoot.root.UbuPaths
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class KernelState(
    val loading: Boolean = true,
    val status: KernelStatus? = null,
    val modules: List<Pair<String, Boolean>> = emptyList(),
    val busy: Boolean = false,
    /** Output of the last action (kernel.sh's own messages). */
    val output: String = "",
    /** The kernel section of doctor.sh, once asked for. */
    val report: String? = null,
)

/**
 * The Kernel screen: everything goes through kernel.sh on the Android side, which
 * records each change for Revert / Stop all. The app asks for confirmation itself,
 * so the commands get -y.
 */
class KernelViewModel(app: Application) : AndroidViewModel(app) {
    private val _state = MutableStateFlow(KernelState())
    val state: StateFlow<KernelState> = _state.asStateFlow()

    private val kernel = UbuPaths.script("kernel.sh")

    init {
        refresh()
    }

    fun refresh() = viewModelScope.launch { reload() }

    private suspend fun reload() {
        val status = KernelStatus.parse(RootShell.run("$kernel status").out)
        val modules = KernelStatus.parseModules(RootShell.run("$kernel module list").out)
        _state.update { it.copy(loading = false, status = status, modules = modules) }
    }

    fun setDevMode(on: Boolean) = act("$kernel -y devmode ${if (on) "on" else "off"}")

    fun setPermissive(on: Boolean) = act("$kernel -y selinux ${if (on) "permissive" else "enforcing"}")

    fun unload(module: String) = act("$kernel -y module unload ${Sh.quote(module)}")

    fun revert() = act("$kernel -y revert")

    /** The Kernel section of the doctor report (read-only, a few seconds). */
    fun loadReport() = viewModelScope.launch {
        _state.update { it.copy(busy = true) }
        val text = RootShell.run(UbuPaths.script("doctor.sh")).out
        val section = text.dropWhile { it != "== Kernel ==" }.drop(1).takeWhile { !it.startsWith("== ") }
        _state.update { it.copy(busy = false, report = section.joinToString("\n").trim()) }
    }

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
