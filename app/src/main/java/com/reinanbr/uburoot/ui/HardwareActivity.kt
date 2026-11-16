// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.clickable
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
import com.reinanbr.uburoot.hardware.HardwareState
import com.reinanbr.uburoot.hardware.HardwareViewModel
import com.reinanbr.uburoot.hardware.HwClass
import com.reinanbr.uburoot.hwbridge.BridgeService

/**
 * Hardware access: every class with its route (direct, bridge, takeover), who may
 * use it, the Wi-Fi takeover, CPU and battery, the wake lock and Revert changes.
 * Every change goes through hardware.sh, which records it; Stop all reverts it.
 */
class HardwareActivity : ComponentActivity() {
    private val vm: HardwareViewModel by viewModels()

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
    private fun Screen(state: HardwareState) {
        var askWifi by rememberSaveable { mutableStateOf(false) }
        var askRevert by rememberSaveable { mutableStateOf(false) }
        var askGadget by rememberSaveable { mutableStateOf("") }
        var pendingBridge by rememberSaveable { mutableStateOf("") }
        var bridgeNote by rememberSaveable { mutableStateOf("") }
        val active by BridgeService.active.collectAsState()
        val bridgeError by BridgeService.error.collectAsState()
        val askPerms = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            val name = pendingBridge
            pendingBridge = ""
            // The microphone is optional (playback works without it); camera and GPS are not.
            val need = when (name) {
                "camera" -> Manifest.permission.CAMERA
                "location" -> Manifest.permission.ACCESS_FINE_LOCATION
                else -> null
            }
            if (need != null && checkSelfPermission(need) != PackageManager.PERMISSION_GRANTED) {
                bridgeNote = getString(R.string.hw_bridge_denied, name)
            } else if (name.isNotEmpty()) {
                bridgeNote = ""
                vm.bridge(name, true)
            }
        }
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
                Text(stringResource(R.string.hw_title), style = MaterialTheme.typography.headlineSmall)
            }
            val s = state.status
            if (state.loading || s == null) {
                CircularProgressIndicator()
                return@Column
            }
            Text(
                stringResource(if (s.access) R.string.hw_access_on else R.string.hw_access_off),
                color = if (s.access) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
            )
            val enabled = s.access && !state.busy
            Hint(
                if (state.user.isEmpty()) {
                    stringResource(R.string.hw_user_root)
                } else {
                    stringResource(R.string.hw_user, state.user)
                },
            )

            Text(stringResource(R.string.hw_classes), style = MaterialTheme.typography.titleMedium)
            for (c in s.classes) ClassRow(c, state, enabled)
            Hint(stringResource(R.string.hw_classes_hint))

            HorizontalDivider()
            Text(stringResource(R.string.hw_wifi), style = MaterialTheme.typography.titleMedium)
            Hint(stringResource(R.string.hw_wifi_hint))
            if (s.wifiTaken) {
                Button(onClick = { vm.wifi(false) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.hw_wifi_release))
                }
            } else {
                OutlinedButton(onClick = { askWifi = true }, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.hw_wifi_take))
                }
            }

            HorizontalDivider()
            Text(stringResource(R.string.hw_bridges), style = MaterialTheme.typography.titleMedium)
            Hint(stringResource(R.string.hw_bridges_hint))
            for ((name, label) in BRIDGES) {
                val on = name in active
                Row(
                    Modifier
                        .fillMaxWidth()
                        .selectable(
                            selected = on,
                            enabled = enabled || on,
                            role = Role.Switch,
                            onClick = {
                                if (on) {
                                    vm.bridge(name, false)
                                } else {
                                    pendingBridge = name
                                    askPerms.launch(bridgePermissions(name))
                                }
                            },
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(stringResource(label), modifier = Modifier.weight(1f))
                    Switch(checked = on, onCheckedChange = null, enabled = enabled || on)
                }
            }
            val note = bridgeNote.ifEmpty { bridgeError }
            if (note.isNotEmpty()) Text(note, color = MaterialTheme.colorScheme.error)

            HorizontalDivider()
            Text(stringResource(R.string.hw_gadget), style = MaterialTheme.typography.titleMedium)
            Hint(stringResource(R.string.hw_gadget_hint))
            if (s.gadget.isNotEmpty()) Text(stringResource(R.string.hw_gadget_active, s.gadget.joinToString(", ")))
            for ((func, label) in GADGET) {
                val has = s.gadget.any { it.startsWith(func) }
                OutlinedButton(
                    onClick = { askGadget = func },
                    enabled = enabled && !has,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(label)) }
            }
            if (s.gadget.isNotEmpty()) {
                Button(onClick = vm::gadgetOff, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.hw_gadget_off))
                }
            }

            HorizontalDivider()
            Text(stringResource(R.string.hw_power), style = MaterialTheme.typography.titleMedium)
            val lines = s.cpus.map { p ->
                "${p.name} (cpu ${p.cpus}): ${p.governor}, ${p.min / 1000}-${p.max / 1000} MHz (max ${p.hwMax / 1000})"
            } + listOfNotNull(
                s.battery?.let { (cap, st, temp) ->
                    "battery: ${cap ?: "?"}% $st" + (temp?.let { ", %.1f °C".format(it / 10.0) } ?: "")
                },
            )
            if (lines.isNotEmpty()) Mono(lines.joinToString("\n"))
            Hint(stringResource(R.string.hw_cpu_hint))
            Row(
                Modifier
                    .fillMaxWidth()
                    .selectable(
                        selected = s.wakeLock,
                        enabled = enabled || (s.wakeLock && !state.busy),
                        role = Role.Switch,
                        onClick = { vm.wakeLock(!s.wakeLock) },
                    ),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(R.string.hw_wakelock), modifier = Modifier.weight(1f))
                Switch(checked = s.wakeLock, onCheckedChange = null, enabled = enabled || s.wakeLock)
            }

            HorizontalDivider()
            Text(stringResource(R.string.kernel_changes, s.changes), style = MaterialTheme.typography.titleMedium)
            Hint(stringResource(R.string.hw_changes_hint))
            Button(
                onClick = { askRevert = true },
                enabled = s.changes > 0 && !state.busy,
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.kernel_revert)) }

            if (state.busy) CircularProgressIndicator()
            if (state.output.isNotEmpty()) Mono(state.output)
        }
        state.info?.let { (name, text) ->
            AlertDialog(
                onDismissRequest = vm::closeInfo,
                title = { Text(name) },
                text = {
                    Column(Modifier.verticalScroll(rememberScrollState())) { Mono(text) }
                },
                confirmButton = { TextButton(onClick = vm::closeInfo) { Text(stringResource(android.R.string.ok)) } },
            )
        }
        if (askWifi) {
            Confirm(
                title = R.string.hw_wifi_take_title,
                body = R.string.hw_wifi_take_body,
                accept = R.string.hw_wifi_take,
                onDismiss = { askWifi = false },
            ) { vm.wifi(true) }
        }
        if (askGadget.isNotEmpty()) {
            val func = askGadget
            Confirm(
                title = R.string.hw_gadget_confirm_title,
                body = R.string.hw_gadget_confirm_body,
                accept = android.R.string.ok,
                onDismiss = { askGadget = "" },
            ) { vm.gadget(func) }
        }
        if (askRevert) {
            Confirm(
                title = R.string.kernel_revert,
                body = R.string.hw_revert_body,
                accept = R.string.kernel_revert,
                onDismiss = { askRevert = false },
            ) { vm.revert() }
        }
    }

    @Composable
    private fun ClassRow(c: HwClass, state: HardwareState, enabled: Boolean) {
        val user = state.user
        Column(
            Modifier
                .fillMaxWidth()
                .clickable { vm.info(c.name) },
        ) {
            Text("${c.name}  ·  ${c.route}  ·  ${c.state}" + if (c.nodes > 0) "  ·  ${c.nodes}" else "")
            // Also while no device is plugged in: a serial/hidraw grant sets up the rule
            // for the next one. Not for route "none": this kernel can't use the device.
            if (c.group.isNotEmpty() && user.isNotEmpty() && c.route != "none") {
                val granted = user in c.users
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        stringResource(if (granted) R.string.hw_granted else R.string.hw_not_granted, user, c.group),
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = { vm.grant(c.name, !granted) }, enabled = enabled) {
                        Text(stringResource(if (granted) R.string.hw_revoke else R.string.hw_grant))
                    }
                }
            }
        }
    }

    @Composable
    private fun Confirm(title: Int, body: Int, accept: Int, onDismiss: () -> Unit, onAccept: () -> Unit) {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text(stringResource(title)) },
            text = { Text(stringResource(body)) },
            confirmButton = {
                TextButton(onClick = {
                    onDismiss()
                    onAccept()
                }) { Text(stringResource(accept)) }
            },
            dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.cancel)) } },
        )
    }

    private fun bridgePermissions(name: String): Array<String> = when (name) {
        "audio" -> arrayOf(Manifest.permission.RECORD_AUDIO)
        "camera" -> arrayOf(Manifest.permission.CAMERA)
        "location" -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        else -> emptyArray()
    }

    @Composable
    private fun Hint(text: String) = Text(text, style = MaterialTheme.typography.bodySmall)

    @Composable
    private fun Mono(text: String) = Text(text, fontFamily = FontFamily.Monospace, fontSize = 12.sp)

    private companion object {
        val BRIDGES = listOf(
            "audio" to R.string.hw_bridge_audio,
            "camera" to R.string.hw_bridge_camera,
            "sensors" to R.string.hw_bridge_sensors,
            "location" to R.string.hw_bridge_location,
        )

        // Status names: ncm, acm, hidkbd + hidmouse, storage.
        val GADGET = listOf(
            "ncm" to R.string.hw_gadget_ncm,
            "acm" to R.string.hw_gadget_acm,
            "hid" to R.string.hw_gadget_hid,
        )
    }
}
