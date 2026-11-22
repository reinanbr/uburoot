// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.gui

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.reinanbr.uburoot.install.ConfigStore
import com.reinanbr.uburoot.install.Downloader
import com.reinanbr.uburoot.install.Http
import com.reinanbr.uburoot.root.RootShell
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
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
    /** Open windows (with the X server running and wmctrl installed). */
    val windows: List<LinuxWindow> = emptyList(),
    val icons: Map<String, Bitmap> = emptyMap(),
    val busy: Boolean = false,
    /** Output of the last action (installing the window manager, an error). */
    val output: String = "",
    val gpu: GpuStatus? = null,
    /** `vulkan=…`/`opengl=…` from the last renderer check. */
    val renderer: List<String> = emptyList(),
    /** Download progress of the GPU driver, 0..1, or null. */
    val gpuProgress: Float? = null,
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
        val gpu = Gpu.status()
        val windows = if (status.running && status.switch) LinuxApps.windows(user) else emptyList()
        _state.update {
            it.copy(loading = false, status = status, user = user, apps = apps, gpu = gpu, windows = windows)
        }
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
            refresh()
        }
    }

    /**
     * Downloads the GPU driver from the latest release (the user tapped the button),
     * checks it against the release's SHA256SUMS, then gpu.sh installs it.
     */
    fun installGpu() = work {
        val dir = File(getApplication<Application>().cacheDir, "gpu")
        val result = runCatching {
            val sums = withContext(Dispatchers.IO) { Http.getText(Gpu.RELEASE + "SHA256SUMS") }
            val sha = Gpu.sumFor(sums, Gpu.ASSET) ?: error("${Gpu.ASSET} is not in the latest release yet")
            val file = Downloader().download(Gpu.RELEASE + Gpu.ASSET, File(dir, Gpu.ASSET), sha) { done, total ->
                if (total > 0) _state.update { it.copy(gpuProgress = done.toFloat() / total) }
            }
            val r = Gpu.install(file.path, sha)
            if (!r.ok) error(r.text.trim())
        }
        dir.deleteRecursively()
        _state.update { it.copy(gpuProgress = null, output = result.exceptionOrNull()?.message.orEmpty()) }
    }

    fun removeGpu() = work {
        Gpu.remove()
        _state.update { it.copy(renderer = emptyList()) }
    }

    fun setZink(on: Boolean) = work { Gpu.zink(on) }

    fun checkRenderer() = work { _state.update { it.copy(renderer = Gpu.renderer(it.user)) } }

    private fun work(block: suspend () -> Unit) {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true, output = "") }
        viewModelScope.launch {
            block()
            _state.update { it.copy(busy = false, gpu = Gpu.status()) }
        }
    }

    /** apt-get install of the window tools (matchbox, wmctrl, xkb-data), shown as it runs. */
    fun installWm() = stream(LinuxApps.setupCmd())

    /** apt-get install of XFCE. */
    fun installDesktop() = stream(LinuxApps.setupCmd("desktop"))

    /** apt-get install of TigerVNC's server. */
    fun installVnc() = stream(LinuxApps.setupCmd("vnc"))

    fun setVncPassword(password: String) = task { LinuxApps.vncPassword(_state.value.user, password) }

    fun startVnc(lan: Boolean) = task { LinuxApps.vncStart(_state.value.user, lan) }

    fun stopVnc() = task { LinuxApps.vncStop() }

    /** Runs [block], shows its output if it failed (or [okText]), then refreshes. */
    private fun task(block: suspend () -> RootShell.Result) {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true, output = "") }
        viewModelScope.launch {
            val r = block()
            _state.update { it.copy(busy = false, output = r.text.trim()) }
            refresh()
        }
    }

    /** Mozilla's APT repository + Firefox (the user tapped the button). */
    fun installFirefox() = stream(LinuxApps.firefoxCmd)

    /** Brings an open window to the front, then the screen opens Termux:X11. */
    fun focus(w: LinuxWindow) = act(w.title) { LinuxApps.focus(w.window) }

    fun openDesktop() = act("desktop") { LinuxApps.desktop(_state.value.user) }

    /** Asks the window to close (the app may still ask to save). */
    fun close(w: LinuxWindow) {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true, output = "") }
        viewModelScope.launch {
            val r = LinuxApps.close(w.window)
            delay(800)
            val windows = LinuxApps.windows(_state.value.user)
            _state.update { it.copy(busy = false, windows = windows, output = if (r.ok) "" else r.text.trim()) }
        }
    }

    private fun act(name: String, block: suspend () -> RootShell.Result) {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true, output = "") }
        viewModelScope.launch {
            val r = block()
            _state.update { it.copy(busy = false, output = if (r.ok) "" else r.text.trim()) }
            if (r.ok) _opened.tryEmit(name)
            refresh()
        }
    }

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
