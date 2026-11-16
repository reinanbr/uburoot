// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.ui

import android.R as AndroidR
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.addCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.reinanbr.uburoot.R
import com.reinanbr.uburoot.install.UbuConfig
import com.reinanbr.uburoot.settings.DoctorReport
import com.reinanbr.uburoot.settings.ModuleState
import com.reinanbr.uburoot.settings.Notice
import com.reinanbr.uburoot.settings.SettingsState
import com.reinanbr.uburoot.settings.SettingsViewModel
import com.reinanbr.uburoot.terminal.SessionManager

/** uburoot.conf editor plus the maintenance actions (repair mounts, reset). */
class SettingsActivity : ComponentActivity() {
    private val vm: SettingsViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        onBackPressedDispatcher.addCallback(this) { leave() }
        setContent {
            UbuRootTheme {
                val state by vm.state.collectAsStateWithLifecycle()
                LaunchedEffect(state.resetDone) {
                    if (state.resetDone) toPreflight()
                }
                Surface(Modifier.fillMaxSize()) {
                    SettingsScreen(state)
                }
            }
        }
    }

    /** With no session left (repair closes them all) the terminal is gone: go through the preflight. */
    private fun leave() {
        if (SessionManager.sessions.isEmpty()) toPreflight() else finish()
    }

    private fun toPreflight() {
        startActivity(
            Intent(
                this,
                MainActivity::class.java,
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        )
        finish()
    }

    @Composable
    private fun SettingsScreen(state: SettingsState) {
        Column(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = ::leave) { Text("←", fontSize = 20.sp) }
                Text(stringResource(R.string.settings_title), style = MaterialTheme.typography.headlineSmall)
            }
            val saved = state.saved
            when {
                state.loading -> CircularProgressIndicator()

                saved == null -> {
                    Text(stringResource(R.string.settings_load_failed, state.loadError ?: ""))
                    Button(onClick = vm::load) { Text(stringResource(R.string.action_retry)) }
                }

                else -> ConfigForm(saved, state)
            }
            HorizontalDivider()
            Diagnostics(state)
            HorizontalDivider()
            Maintenance(state)
            if (state.busy) CircularProgressIndicator()
            state.notice?.let { NoticeText(it) }
            if (state.log.isNotEmpty()) {
                Text(
                    state.log.joinToString("\n"),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }

    @Composable
    private fun ConfigForm(saved: UbuConfig, state: SettingsState) {
        // Keyed on the saved config, so a reload resets the form.
        var user by rememberSaveable(saved) { mutableStateOf(saved.defaultUser.ifEmpty { "root" }) }
        var initCommand by rememberSaveable(saved) { mutableStateOf(saved.initCommand) }
        var sdcard by rememberSaveable(saved) { mutableStateOf(saved.mountSdcard) }
        var android by rememberSaveable(saved) { mutableStateOf(saved.androidIntegration) }
        var dns by rememberSaveable(saved) { mutableStateOf(saved.dnsServers) }
        var boot by rememberSaveable(saved) { mutableStateOf(saved.bootStart) }
        var mirror by rememberSaveable(saved) { mutableStateOf(saved.aptMirror) }
        var kernel by rememberSaveable(saved) { mutableStateOf(saved.kernelAccess) }
        var kernelWarning by rememberSaveable { mutableStateOf(false) }

        val edited = saved.copy(
            defaultUser = if (user == "root") "" else user,
            initCommand = initCommand,
            mountSdcard = sdcard,
            androidIntegration = android,
            dnsServers = dns.trim().replace(Regex("\\s+"), " "),
            bootStart = boot,
            aptMirror = mirror.trim(),
            kernelAccess = kernel,
        )
        val dnsOk = UbuConfig.isValidDns(dns)
        val mirrorOk = mirror.isBlank() || UbuConfig.isValidMirror(mirror.trim())

        Section(R.string.settings_session)
        Text(stringResource(R.string.settings_default_user), style = MaterialTheme.typography.labelLarge)
        val users = (state.users + user).distinct()
        for (u in users) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .selectable(selected = u == user, role = Role.RadioButton, onClick = { user = u }),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = u == user, onClick = null)
                Text(u, modifier = Modifier.padding(start = 8.dp))
            }
        }
        OutlinedTextField(
            value = initCommand,
            onValueChange = { initCommand = it },
            label = { Text(stringResource(R.string.settings_init_command)) },
            supportingText = { Text(stringResource(R.string.settings_init_command_hint)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )

        Section(R.string.settings_mounts)
        Toggle(R.string.settings_mount_sdcard, sdcard) { sdcard = it }
        Toggle(R.string.settings_android_integration, android) { android = it }
        Text(stringResource(R.string.settings_mounts_hint), style = MaterialTheme.typography.bodySmall)

        Section(R.string.settings_kernel)
        Toggle(R.string.settings_kernel_access, kernel) { on -> if (on) kernelWarning = true else kernel = false }
        Text(stringResource(R.string.settings_kernel_hint), style = MaterialTheme.typography.bodySmall)
        if (kernelWarning) {
            AlertDialog(
                onDismissRequest = { kernelWarning = false },
                title = { Text(stringResource(R.string.kernel_warning_title)) },
                text = { Text(stringResource(R.string.kernel_warning_body)) },
                confirmButton = {
                    TextButton(onClick = {
                        kernel = true
                        kernelWarning = false
                    }) { Text(stringResource(R.string.kernel_warning_accept)) }
                },
                dismissButton = {
                    TextButton(onClick = { kernelWarning = false }) { Text(stringResource(AndroidR.string.cancel)) }
                },
            )
        }

        Section(R.string.settings_network)
        OutlinedTextField(
            value = dns,
            onValueChange = { dns = it },
            label = { Text(stringResource(R.string.settings_dns)) },
            supportingText = {
                Text(stringResource(if (dnsOk) R.string.settings_dns_hint else R.string.settings_dns_invalid))
            },
            isError = !dnsOk,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = mirror,
            onValueChange = { mirror = it },
            label = { Text(stringResource(R.string.form_mirror)) },
            placeholder = { Text("http://ports.ubuntu.com/ubuntu-ports/") },
            supportingText = {
                Text(stringResource(if (mirrorOk) R.string.settings_mirror_hint else R.string.mirror_invalid))
            },
            isError = !mirrorOk,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth(),
        )

        Section(R.string.settings_boot)
        Toggle(R.string.settings_boot_start, boot) { boot = it }
        Text(stringResource(R.string.settings_boot_hint), style = MaterialTheme.typography.bodySmall)
        Text(
            stringResource(moduleText(state.module)),
            style = MaterialTheme.typography.bodySmall,
            color = if (state.module == ModuleState.ENABLED) {
                MaterialTheme.colorScheme.primary
            } else {
                MaterialTheme.colorScheme.error
            },
        )
        OutlinedButton(
            onClick = vm::runBootNow,
            enabled = !state.busy,
            modifier = Modifier.fillMaxWidth(),
        ) { Text(stringResource(R.string.action_run_boot)) }

        Button(
            onClick = { vm.save(edited) },
            enabled = !state.busy && dnsOk && mirrorOk && edited != saved,
            modifier = Modifier.fillMaxWidth(),
        ) { Text(stringResource(R.string.action_save)) }
    }

    /** doctor.sh: shown redacted by default, and shared exactly as shown. */
    @Composable
    private fun Diagnostics(state: SettingsState) {
        var identifiers by rememberSaveable { mutableStateOf(false) }
        Section(R.string.settings_diagnostics)
        Text(stringResource(R.string.settings_diagnostics_hint), style = MaterialTheme.typography.bodySmall)
        Row(
            Modifier
                .fillMaxWidth()
                .selectable(selected = identifiers, role = Role.Checkbox, onClick = { identifiers = !identifiers }),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Checkbox(checked = identifiers, onCheckedChange = null)
            Text(stringResource(R.string.doctor_identifiers), modifier = Modifier.padding(start = 8.dp))
        }
        OutlinedButton(
            onClick = { vm.runDoctor(redact = !identifiers) },
            enabled = !state.doctorRunning,
            modifier = Modifier.fillMaxWidth(),
        ) { Text(stringResource(R.string.action_run_doctor)) }
        if (state.doctorRunning) CircularProgressIndicator()
        state.doctor?.let { DoctorView(it) }
    }

    @Composable
    private fun DoctorView(report: DoctorReport) {
        if (!report.redacted) {
            Text(stringResource(R.string.doctor_not_redacted), color = MaterialTheme.colorScheme.error)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { shareDoctor(report.text) }) { Text(stringResource(R.string.action_share)) }
            OutlinedButton(onClick = {
                getSystemService(ClipboardManager::class.java)
                    .setPrimaryClip(ClipData.newPlainText("UbuRoot doctor", report.text))
            }) { Text(stringResource(R.string.action_copy)) }
        }
        Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.small) {
            Text(
                report.text,
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp,
                lineHeight = 12.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(8.dp),
            )
        }
    }

    private fun shareDoctor(text: String) {
        val send = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_SUBJECT, "UbuRoot doctor")
            .putExtra(Intent.EXTRA_TEXT, text)
        startActivity(Intent.createChooser(send, getString(R.string.action_share)))
    }

    @Composable
    private fun Maintenance(state: SettingsState) {
        var confirmRepair by remember { mutableStateOf(false) }
        var confirmReset by remember { mutableStateOf(false) }

        Section(R.string.settings_maintenance)
        OutlinedButton(
            onClick = { confirmRepair = true },
            enabled = !state.busy,
            modifier = Modifier.fillMaxWidth(),
        ) { Text(stringResource(R.string.action_repair_mounts)) }
        Button(
            onClick = { confirmReset = true },
            enabled = !state.busy,
            colors = ButtonDefaults.buttonColors(
                containerColor = MaterialTheme.colorScheme.error,
                contentColor = MaterialTheme.colorScheme.onError,
            ),
            modifier = Modifier.fillMaxWidth(),
        ) { Text(stringResource(R.string.action_reset)) }

        if (confirmRepair) {
            AlertDialog(
                onDismissRequest = { confirmRepair = false },
                title = { Text(stringResource(R.string.action_repair_mounts)) },
                text = { Text(stringResource(R.string.repair_body)) },
                confirmButton = {
                    TextButton(onClick = {
                        confirmRepair = false
                        vm.repairMounts()
                    }) { Text(stringResource(R.string.action_repair)) }
                },
                dismissButton = {
                    TextButton(onClick = { confirmRepair = false }) { Text(stringResource(android.R.string.cancel)) }
                },
            )
        }
        if (confirmReset) {
            ResetDialog(onDismiss = { confirmReset = false }) {
                confirmReset = false
                vm.reset()
            }
        }
    }

    /** "Reset Ubuntu" only goes ahead after the user types the confirmation word (DELETE / APAGAR). */
    @Composable
    private fun ResetDialog(onDismiss: () -> Unit, onConfirm: () -> Unit) {
        val word = stringResource(R.string.reset_confirm_word)
        var typed by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text(stringResource(R.string.reset_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.reset_body, word))
                    OutlinedTextField(
                        value = typed,
                        onValueChange = { typed = it },
                        singleLine = true,
                        label = { Text(stringResource(R.string.reset_type_word, word)) },
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = onConfirm,
                    enabled = typed.trim() == word,
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
                ) { Text(stringResource(R.string.action_reset)) }
            },
            dismissButton = {
                TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.cancel)) }
            },
        )
    }

    @Composable
    private fun NoticeText(notice: Notice) {
        val (text, error) = when (notice) {
            Notice.SAVED -> R.string.notice_saved to false
            Notice.SAVED_REPAIR_NEEDED -> R.string.notice_saved_repair to false
            Notice.REPAIRED -> R.string.notice_repaired to false
            Notice.REPAIR_FAILED -> R.string.notice_repair_failed to true
            Notice.RESET_REFUSED -> R.string.notice_reset_refused to true
            Notice.RESET_FAILED -> R.string.notice_reset_failed to true
            Notice.BOOT_RAN -> R.string.notice_boot_ran to false
            Notice.BOOT_FAILED -> R.string.notice_boot_failed to true
        }
        Text(
            stringResource(text),
            color = if (error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
        )
    }

    private fun moduleText(m: ModuleState) = when (m) {
        ModuleState.ENABLED -> R.string.module_enabled
        ModuleState.DISABLED -> R.string.module_disabled
        ModuleState.REMOVING -> R.string.module_removing
        ModuleState.PENDING -> R.string.module_pending
        ModuleState.MISSING -> R.string.module_missing
        ModuleState.UNKNOWN -> R.string.module_unknown
    }

    @Composable
    private fun Section(title: Int) {
        Spacer(Modifier.height(4.dp))
        Text(
            stringResource(title),
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.primary,
        )
    }

    @Composable
    private fun Toggle(label: Int, checked: Boolean, onChange: (Boolean) -> Unit) {
        Row(
            Modifier
                .fillMaxWidth()
                .selectable(selected = checked, role = Role.Switch, onClick = { onChange(!checked) }),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(stringResource(label), modifier = Modifier.weight(1f))
            Switch(checked = checked, onCheckedChange = null)
        }
    }
}
