// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.reinanbr.uburoot.R
import com.reinanbr.uburoot.kernel.KernelState
import com.reinanbr.uburoot.kernel.KernelViewModel
import com.reinanbr.uburoot.terminal.TerminalActivity

/**
 * Kernel access: state, developer mode, SELinux, modules loaded through UbuRoot,
 * kernel logs and Revert changes. Every change goes through kernel.sh, which
 * records it; Stop all reverts it too.
 */
class KernelActivity : ComponentActivity() {
    private val vm: KernelViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            UbuRootTheme {
                Surface(Modifier.fillMaxSize()) {
                    val state by vm.state.collectAsState()
                    Screen(state)
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        vm.refresh()
    }

    @Composable
    private fun Screen(state: KernelState) {
        var askPermissive by rememberSaveable { mutableStateOf(false) }
        var askRevert by rememberSaveable { mutableStateOf(false) }
        Column(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = ::finish) { Text("←", fontSize = 20.sp) }
                Text(stringResource(R.string.kernel_title), style = MaterialTheme.typography.headlineSmall)
            }
            val s = state.status
            if (state.loading || s == null) {
                CircularProgressIndicator()
                return@Column
            }
            Text(
                stringResource(if (s.access) R.string.kernel_access_on else R.string.kernel_access_off),
                color = if (s.access) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
            )
            val enabled = s.access && !state.busy

            Text(stringResource(R.string.kernel_state), style = MaterialTheme.typography.titleMedium)
            Mono(
                (listOf("selinux" to s.selinux, "modules" to s.modulesLoaded.toString()) + s.sysctls)
                    .joinToString("\n") { (k, v) -> "$k = $v" },
            )

            Toggle(R.string.kernel_devmode, s.devMode, enabled) { vm.setDevMode(it) }
            Hint(R.string.kernel_devmode_hint)
            Toggle(R.string.kernel_permissive, s.permissive, enabled || (s.permissive && !state.busy)) { on ->
                if (on) askPermissive = true else vm.setPermissive(false)
            }
            Hint(R.string.kernel_permissive_hint)

            HorizontalDivider()
            Text(stringResource(R.string.kernel_changes, s.changes.size), style = MaterialTheme.typography.titleMedium)
            if (s.changes.isNotEmpty()) {
                val was = stringResource(R.string.kernel_change_was)
                Mono(
                    s.changes.joinToString("\n") { c ->
                        if (c.type == "module") "module ${c.name}" else "${c.type} ${c.name} ($was ${c.original})"
                    },
                )
            }
            Hint(R.string.kernel_changes_hint)
            Button(
                onClick = { askRevert = true },
                enabled = s.changes.isNotEmpty() && !state.busy,
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.kernel_revert)) }

            HorizontalDivider()
            Text(stringResource(R.string.kernel_modules), style = MaterialTheme.typography.titleMedium)
            val ours = state.modules.filter { it.second }
            if (state.modules.isEmpty()) {
                Hint(R.string.kernel_modules_none)
            } else {
                Mono(state.modules.joinToString("\n") { (n, mine) -> if (mine) "* $n" else "  $n" })
            }
            for ((name, _) in ours) {
                OutlinedButton(onClick = {
                    vm.unload(name)
                }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.kernel_unload, name))
                }
            }
            Hint(R.string.kernel_modules_hint)

            HorizontalDivider()
            Text(stringResource(R.string.kernel_logs), style = MaterialTheme.typography.titleMedium)
            OutlinedButton(onClick = { openTerminal("dmesg -w") }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.kernel_dmesg))
            }
            OutlinedButton(
                onClick = { openTerminal("uburoot-kernel lastlog | less") },
                enabled = s.access,
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.kernel_lastlog)) }
            OutlinedButton(onClick = vm::loadReport, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.kernel_report))
            }
            state.report?.let { Mono(it) }

            if (state.busy) CircularProgressIndicator()
            if (state.output.isNotEmpty()) Mono(state.output)
        }
        if (askPermissive) {
            AlertDialog(
                onDismissRequest = { askPermissive = false },
                title = { Text(stringResource(R.string.kernel_permissive_title)) },
                text = { Text(stringResource(R.string.kernel_permissive_body)) },
                confirmButton = {
                    TextButton(onClick = {
                        askPermissive = false
                        vm.setPermissive(true)
                    }) { Text(stringResource(R.string.kernel_permissive_accept)) }
                },
                dismissButton = {
                    TextButton(onClick = { askPermissive = false }) { Text(stringResource(android.R.string.cancel)) }
                },
            )
        }
        if (askRevert) {
            AlertDialog(
                onDismissRequest = { askRevert = false },
                title = { Text(stringResource(R.string.kernel_revert)) },
                text = { Text(stringResource(R.string.kernel_revert_body)) },
                confirmButton = {
                    TextButton(onClick = {
                        askRevert = false
                        vm.revert()
                    }) { Text(stringResource(R.string.kernel_revert)) }
                },
                dismissButton = {
                    TextButton(onClick = { askRevert = false }) { Text(stringResource(android.R.string.cancel)) }
                },
            )
        }
    }

    /** A root session in a new tab running [command] (Ubuntu is mounted by enter.sh). */
    private fun openTerminal(command: String) {
        startActivity(TerminalActivity.intent(this, newSession = true, user = "root", command = command))
    }

    @Composable
    private fun Toggle(label: Int, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
        Row(
            Modifier
                .fillMaxWidth()
                .selectable(selected = checked, enabled = enabled, role = Role.Switch, onClick = {
                    onChange(!checked)
                }),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(stringResource(label), modifier = Modifier.weight(1f))
            Switch(checked = checked, onCheckedChange = null, enabled = enabled)
        }
    }

    @Composable
    private fun Hint(text: Int) = Text(stringResource(text), style = MaterialTheme.typography.bodySmall)

    @Composable
    private fun Mono(text: String) = Text(text, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
}
