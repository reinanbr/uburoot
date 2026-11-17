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
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.reinanbr.uburoot.R
import com.reinanbr.uburoot.gui.LaunchActivity
import com.reinanbr.uburoot.gui.LinuxApp
import com.reinanbr.uburoot.gui.LinuxApps
import com.reinanbr.uburoot.gui.LinuxAppsState
import com.reinanbr.uburoot.gui.LinuxAppsViewModel

/**
 * Linux apps: the GUI programs installed in Ubuntu (their .desktop entries). Tap one to
 * open it on Termux:X11's screen; long-press to put it on the Android home screen.
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
            if (s.wm == "missing") {
                Hint(stringResource(R.string.gui_wm_needed))
                OutlinedButton(onClick = vm::installWm, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.gui_wm_install))
                }
            }
            Hint(stringResource(R.string.gui_hint, state.user))
            if (s.x11 == "running") {
                OutlinedButton(onClick = vm::stopDisplay, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.gui_stop))
                }
            }
            if (state.busy) CircularProgressIndicator()
            if (state.output.isNotEmpty()) {
                Text(state.output, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
            }
            if (state.apps.isEmpty()) {
                Hint(stringResource(R.string.gui_none))
            }
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                items(state.apps, key = { it.id }) { app -> AppRow(app, state.icons[app.id], !state.busy) }
            }
        }
    }

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
            Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) {
                if (icon != null) {
                    Image(icon.asImageBitmap(), contentDescription = null, modifier = Modifier.size(40.dp))
                } else {
                    Text(app.name.take(1).uppercase(), style = MaterialTheme.typography.titleLarge)
                }
            }
            Text(app.name, style = MaterialTheme.typography.bodyLarge)
        }
    }

    @Composable
    private fun Hint(text: String) = Text(text, style = MaterialTheme.typography.bodySmall)
}
