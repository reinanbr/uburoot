// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.ui

import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.reinanbr.uburoot.R
import com.reinanbr.uburoot.gui.GpuStatus
import com.reinanbr.uburoot.gui.LaunchActivity
import com.reinanbr.uburoot.gui.LinuxApp
import com.reinanbr.uburoot.gui.LinuxApps
import com.reinanbr.uburoot.gui.LinuxAppsState
import com.reinanbr.uburoot.gui.LinuxAppsViewModel
import com.reinanbr.uburoot.gui.LinuxWindow
import com.reinanbr.uburoot.gui.X11Status

/**
 * Linux apps: the GUI programs installed in Ubuntu (their .desktop entries). Tap one to
 * open it on Termux:X11's screen (or bring its window back); long-press to put it on the
 * Android home screen. Also: the open windows, the XFCE desktop, Firefox from Mozilla.
 */
class LinuxAppsActivity : ComponentActivity() {
    private val vm: LinuxAppsViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            UbuRootTheme {
                Surface(Modifier.fillMaxSize()) {
                    val state by vm.state.collectAsState()
                    LaunchedEffect(Unit) {
                        vm.opened.collect {
                            if (!LinuxApps.openDisplay(
                                    this@LinuxAppsActivity,
                                )
                            ) {
                                toast(getString(R.string.gui_x11_missing))
                            }
                        }
                    }
                    Screen(state)
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        vm.refresh()
    }

    private fun toast(text: String) = Toast.makeText(this, text, Toast.LENGTH_LONG).show()

    private fun pin(app: LinuxApp, icon: Bitmap?) {
        if (!ShortcutManagerCompat.isRequestPinShortcutSupported(
                this,
            )
        ) {
            return toast(getString(R.string.gui_pin_unsupported))
        }
        val info = ShortcutInfoCompat.Builder(this, "linux-${app.id}")
            .setShortLabel(app.name)
            .setIcon(
                if (icon !=
                    null
                ) {
                    IconCompat.createWithBitmap(icon)
                } else {
                    IconCompat.createWithResource(this, R.mipmap.ic_launcher)
                },
            )
            .setIntent(
                Intent(this, LaunchActivity::class.java)
                    .setAction(Intent.ACTION_VIEW)
                    .putExtra(LaunchActivity.EXTRA_ID, app.id)
                    .putExtra(LaunchActivity.EXTRA_NAME, app.name),
            )
            .build()
        ShortcutManagerCompat.requestPinShortcut(this, info, null)
    }

    @Composable
    private fun Screen(state: LinuxAppsState) {
        Column(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = ::finish) { Text("←", fontSize = 20.sp) }
                Text(stringResource(R.string.gui_title), style = MaterialTheme.typography.headlineSmall)
            }
            val s = state.status
            if (state.loading || s == null) {
                CircularProgressIndicator()
                return@Column
            }
            if (!s.installed) {
                Text(stringResource(R.string.gui_x11_needed))
                Button(
                    onClick = { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(LinuxApps.X11_RELEASES))) },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.gui_x11_get)) }
                return@Column
            }
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                item { Top(state, s) }
                if (state.windows.isNotEmpty()) {
                    item { Title(stringResource(R.string.gui_windows)) }
                    items(state.windows, key = { "w" + it.window }) { w ->
                        WindowRow(w, state.icons[w.app], state.apps.firstOrNull { it.id == w.app }, !state.busy)
                    }
                }
                item { Title(stringResource(R.string.gui_apps)) }
                if (state.apps.isEmpty()) item { Hint(stringResource(R.string.gui_none)) }
                items(state.apps, key = { it.id }) { app -> AppRow(app, state.icons[app.id], !state.busy) }
                item { Extras(state, s) }
                state.gpu?.let { g -> item { GpuCard(state, g) } }
            }
        }
    }

    /** Hints, the display's state, and the output of the last action. */
    @Composable
    private fun Top(state: LinuxAppsState, s: X11Status) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (s.toolsMissing) {
                Hint(stringResource(R.string.gui_wm_needed))
                OutlinedButton(onClick = vm::installWm, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.gui_wm_install))
                }
            }
            Hint(stringResource(R.string.gui_hint, state.user))
            if (s.running) {
                OutlinedButton(onClick = vm::stopDisplay, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.gui_stop))
                }
            }
            if (state.busy) CircularProgressIndicator()
            if (state.output.isNotEmpty()) {
                Text(state.output, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
            }
        }
    }

    /** The XFCE desktop and Firefox from Mozilla. */
    @Composable
    private fun Extras(state: LinuxAppsState, s: X11Status) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Title(stringResource(R.string.gui_desktop_title))
            if (s.desktop == "missing") {
                Hint(stringResource(R.string.gui_desktop_missing))
                OutlinedButton(
                    onClick = vm::installDesktop,
                    enabled = !state.busy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.gui_desktop_install))
                }
            } else {
                Hint(stringResource(R.string.gui_desktop_hint))
                Button(onClick = vm::openDesktop, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.gui_desktop_open))
                }
            }
            Vnc(state, s)
            if (s.firefox != "installed") {
                Title(stringResource(R.string.gui_firefox_title))
                Hint(stringResource(R.string.gui_firefox_hint))
                OutlinedButton(
                    onClick = vm::installFirefox,
                    enabled = !state.busy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.gui_firefox_install))
                }
            }
        }
    }

    /** The XFCE desktop over VNC (display :1), for AVNC on the phone or a computer. */
    @Composable
    private fun Vnc(state: LinuxAppsState, s: X11Status) {
        var password by rememberSaveable { mutableStateOf("") }
        var lan by rememberSaveable { mutableStateOf(false) }
        Title(stringResource(R.string.vnc_title))
        Hint(stringResource(R.string.vnc_hint))
        when {
            s.desktop == "missing" -> Hint(stringResource(R.string.vnc_needs_desktop))

            s.vnc == "missing" -> OutlinedButton(
                onClick = vm::installVnc,
                enabled = !state.busy,
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.vnc_install)) }

            s.vnc == "local" || s.vnc == "lan" -> {
                Text(
                    stringResource(if (s.vnc == "lan") R.string.vnc_on_lan else R.string.vnc_on_local, s.vncAddr),
                    fontFamily = FontFamily.Monospace,
                )
                OutlinedButton(onClick = vm::stopVnc, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.vnc_stop))
                }
            }

            else -> {
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it.take(8) },
                    label = { Text(stringResource(R.string.vnc_password)) },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedButton(
                    onClick = {
                        vm.setVncPassword(password)
                        password = ""
                    },
                    enabled = !state.busy && LinuxApps.vncPasswordOk(password),
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.vnc_set_password)) }
                // The whole row toggles (on the S9 a tap on the text did nothing).
                Row(
                    Modifier
                        .fillMaxWidth()
                        .toggleable(value = lan, role = Role.Checkbox, onValueChange = { lan = it }),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(checked = lan, onCheckedChange = null)
                    Text(
                        stringResource(R.string.vnc_lan),
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                }
                Button(
                    onClick = { vm.startVnc(lan) },
                    enabled = !state.busy,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.vnc_start)) }
            }
        }
    }

    @Composable
    private fun WindowRow(w: LinuxWindow, icon: Bitmap?, app: LinuxApp?, enabled: Boolean) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(enabled = enabled) { vm.focus(w) }
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            AppIcon(icon, app?.name ?: w.title)
            Column(Modifier.weight(1f)) {
                Text(
                    w.title,
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                app?.let { Text(it.name, style = MaterialTheme.typography.bodySmall) }
            }
            TextButton(onClick = { vm.close(w) }, enabled = enabled) {
                Text("✕", fontSize = 18.sp, modifier = Modifier.semantics { contentDescription = closeLabel })
            }
        }
    }

    private val closeLabel get() = getString(R.string.gui_close)

    @Composable
    private fun AppIcon(icon: Bitmap?, name: String) {
        Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) {
            if (icon != null) {
                Image(icon.asImageBitmap(), contentDescription = null, modifier = Modifier.size(40.dp))
            } else {
                Text(name.take(1).uppercase(), style = MaterialTheme.typography.titleLarge)
            }
        }
    }

    @Composable
    private fun Title(text: String) = Text(text, style = MaterialTheme.typography.titleMedium)

    @OptIn(ExperimentalFoundationApi::class)
    @Composable
    private fun AppRow(app: LinuxApp, icon: Bitmap?, enabled: Boolean) {
        Row(
            Modifier
                .fillMaxWidth()
                .combinedClickable(
                    enabled = enabled,
                    onClick = { vm.launch(app) },
                    onLongClick = { pin(app, icon) },
                    onLongClickLabel = stringResource(R.string.gui_pin),
                )
                .padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            AppIcon(icon, app.name)
            Text(app.name, style = MaterialTheme.typography.bodyLarge)
        }
    }

    @Composable
    private fun GpuCard(state: LinuxAppsState, g: GpuStatus) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Title(stringResource(R.string.gpu_title))
            when {
                !g.adreno -> Hint(stringResource(R.string.gpu_none))

                !g.installed -> {
                    Hint(stringResource(R.string.gpu_missing, g.model))
                    OutlinedButton(
                        onClick = vm::installGpu,
                        enabled = !state.busy,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(stringResource(R.string.gpu_install))
                    }
                    state.gpuProgress?.let {
                        LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth())
                    }
                }

                else -> {
                    Hint(stringResource(R.string.gpu_installed, g.model, g.mesa))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.gpu_zink), Modifier.weight(1f))
                        Switch(checked = g.zink, onCheckedChange = vm::setZink, enabled = !state.busy)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = vm::checkRenderer, enabled = !state.busy) {
                            Text(stringResource(R.string.gpu_check))
                        }
                        TextButton(onClick = vm::removeGpu, enabled = !state.busy) {
                            Text(stringResource(R.string.gpu_remove))
                        }
                    }
                    state.renderer.forEach { Text(it, fontFamily = FontFamily.Monospace, fontSize = 12.sp) }
                }
            }
        }
    }

    @Composable
    private fun Hint(text: String) = Text(text, style = MaterialTheme.typography.bodySmall)
}
