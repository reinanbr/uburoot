// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.gui

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.reinanbr.uburoot.install.ConfigStore
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.UbuPaths
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class LinuxAppsState(
    val loading: Boolean = true,
    val status: X11Status? = null,
    val user: String = "root",
    val apps: List<LinuxApp> = emptyList(),
    val icons: Map<String, Bitmap> = emptyMap(),
    val busy: Boolean = false,
    /** Output of the last action (installing the window manager, an error). */
    val output: String = "",
)

class LinuxAppsViewModel(app: Application) : AndroidViewModel(app) {
    private val _state = MutableStateFlow(LinuxAppsState())
    val state: StateFlow<LinuxAppsState> = _state.asStateFlow()

    private val _opened = MutableSharedFlow<String>(extraBufferCapacity = 1)

    /** An app was started: the screen opens Termux:X11. */
    val opened: SharedFlow<String> = _opened

    fun refresh() = viewModelScope.launch {
        val user = LinuxApps.userOf(runCatching { ConfigStore.read().defaultUser }.getOrDefault(""))
        val status = LinuxApps.status()
        val apps = LinuxApps.apps(user)
        _state.update { it.copy(loading = false, status = status, user = user, apps = apps) }
        val icons = withContext(Dispatchers.Default) {
            LinuxApps.icons(user).mapNotNull { (id, b64) ->
                runCatching {
                    val bytes = Base64.decode(b64, Base64.DEFAULT)
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let { id to it }
                }.getOrNull()
            }.toMap()
        }
        _state.update { it.copy(icons = icons) }
    }

    fun launch(app: LinuxApp) {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true, output = "") }
        viewModelScope.launch {
            val r = LinuxApps.run(_state.value.user, app.id)
            _state.update { it.copy(busy = false, output = if (r.ok) "" else r.text.trim()) }
            if (r.ok) _opened.tryEmit(app.name)
            _state.update { it.copy(status = LinuxApps.status()) }
        }
    }

    /** apt-get install of the window manager (and xkb-data), shown as it runs. */
    fun installWm() = stream("${UbuPaths.script("x11.sh")} setup")

    fun stopDisplay() {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true, output = "") }
        viewModelScope.launch {
            LinuxApps.stop()
            _state.update { it.copy(busy = false, status = LinuxApps.status()) }
        }
    }

    private fun stream(cmd: String) {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true, output = "") }
        viewModelScope.launch {
            val lines = ArrayDeque<String>()
            RootShell.stream(cmd) { line ->
                lines.addLast(line)
                while (lines.size > 12) lines.removeFirst()
                _state.update { it.copy(output = lines.joinToString("\n")) }
            }
            _state.update { it.copy(busy = false) }
            refresh()
        }
    }
}
