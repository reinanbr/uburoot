// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.ui

import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.reinanbr.uburoot.R
import com.reinanbr.uburoot.install.InstallRequest
import com.reinanbr.uburoot.install.Problem
import com.reinanbr.uburoot.install.Stage
import com.reinanbr.uburoot.install.Step
import com.reinanbr.uburoot.install.UbuConfig
import com.reinanbr.uburoot.root.RootInfo

@Composable
fun InstallScreen(
    stage: Stage,
    log: List<String>,
    onRetry: () -> Unit,
    onInstall: (InstallRequest, RootInfo) -> Unit,
) {
    Scaffold { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                // Keep the form's button above the soft keyboard.
                .imePadding()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineMedium)
            when (stage) {
                Stage.Checking, Stage.Ready -> Busy(stringResource(R.string.checking_root))
                is Stage.Blocked -> Blocked(stage, onRetry)
                is Stage.Form -> SetupForm(stage.info, onInstall)
                is Stage.Working -> Working(stage, log)
                is Stage.Failed -> Failed(stage, log, onRetry)
            }
        }
    }
}

@Composable
private fun Busy(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        CircularProgressIndicator()
        Text(text)
    }
}

@Composable
private fun Blocked(stage: Stage.Blocked, onRetry: () -> Unit) {
    val (title, body) = when (stage.problem) {
        Problem.NO_ROOT -> R.string.problem_no_root_title to R.string.problem_no_root_body
        Problem.NOT_GLOBAL_NAMESPACE -> R.string.problem_namespace_title to R.string.problem_namespace_body
        Problem.NOT_ARM64 -> R.string.problem_arch_title to R.string.problem_arch_body
        Problem.NO_SPACE -> R.string.problem_space_title to R.string.problem_space_body
        Problem.DEPLOY_FAILED -> R.string.problem_deploy_title to R.string.problem_deploy_body
    }
    Column(
        Modifier.verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            stringResource(title),
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.error,
        )
        Text(stringResource(body))
        stage.info?.let { RootInfoCard(it) }
        if (stage.detail.isNotEmpty()) Mono(stage.detail)
        Button(onClick = onRetry) { Text(stringResource(R.string.action_retry)) }
    }
}

@Composable
private fun RootInfoCard(info: RootInfo) {
    val ctx = LocalContext.current
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            InfoRow(R.string.info_root, "${info.impl} ${info.version}".trim())
            InfoRow(R.string.info_busybox, info.busybox)
            InfoRow(R.string.info_arch, info.arch)
            info.freeBytes?.let { InfoRow(R.string.info_free, Formatter.formatFileSize(ctx, it)) }
            InfoRow(
                R.string.info_namespace,
                stringResource(if (info.globalNamespace) R.string.namespace_global else R.string.namespace_private),
            )
        }
    }
}

@Composable
private fun InfoRow(label: Int, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(stringResource(label), style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace)
    }
}

@Composable
private fun SetupForm(info: RootInfo, onInstall: (InstallRequest, RootInfo) -> Unit) {
    var user by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var nopasswd by rememberSaveable { mutableStateOf(true) }
    val valid = UbuConfig.isValidUserName(user)

    Column(
        Modifier.verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        RootInfoCard(info)
        if (info.busybox == "none") {
            Text(stringResource(R.string.warning_no_busybox), color = MaterialTheme.colorScheme.error)
        }
        Text(
            stringResource(if (info.rootfsInstalled) R.string.form_intro_setup_only else R.string.form_intro),
        )
        OutlinedTextField(
            value = user,
            onValueChange = { user = it.trim().lowercase() },
            label = { Text(stringResource(R.string.form_user)) },
            supportingText = { Text(stringResource(R.string.form_user_hint)) },
            isError = user.isNotEmpty() && !valid,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = password,
            onValueChange = { password = it.filter { c -> c != '\n' && c != '\r' } },
            label = { Text(stringResource(R.string.form_password)) },
            supportingText = { Text(stringResource(R.string.form_password_hint)) },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            modifier = Modifier.fillMaxWidth(),
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked = nopasswd, onCheckedChange = { nopasswd = it })
            Text(stringResource(R.string.form_nopasswd))
        }
        Button(
            onClick = { onInstall(InstallRequest(user, password, nopasswd), info) },
            enabled = valid,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(stringResource(if (info.rootfsInstalled) R.string.action_setup else R.string.action_install))
        }
    }
}

@Composable
private fun Working(stage: Stage.Working, log: List<String>) {
    val label = when (stage.step) {
        Step.DISCOVER -> R.string.step_discover
        Step.DOWNLOAD -> R.string.step_download
        Step.EXTRACT -> R.string.step_extract
        Step.SETUP -> R.string.step_setup
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(label), style = MaterialTheme.typography.titleMedium)
        val p = stage.progress
        if (p != null) {
            LinearProgressIndicator(progress = { p }, modifier = Modifier.fillMaxWidth())
        } else {
            LinearProgressIndicator(Modifier.fillMaxWidth())
        }
        if (stage.detail.isNotEmpty()) Text(stage.detail, style = MaterialTheme.typography.bodySmall)
    }
    LogView(log)
}

@Composable
private fun Failed(stage: Stage.Failed, log: List<String>, onRetry: () -> Unit) {
    Text(
        stringResource(R.string.install_failed),
        style = MaterialTheme.typography.titleLarge,
        color = MaterialTheme.colorScheme.error,
    )
    Text(stage.message)
    Button(onClick = onRetry) { Text(stringResource(R.string.action_retry)) }
    LogView(log)
}

@Composable
private fun LogView(log: List<String>) {
    val state = rememberLazyListState()
    LaunchedEffect(log.size) {
        if (log.isNotEmpty()) state.scrollToItem(log.lastIndex)
    }
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = MaterialTheme.shapes.small,
        modifier = Modifier.fillMaxSize(),
    ) {
        LazyColumn(state = state, modifier = Modifier.padding(8.dp)) {
            items(log) { Text(it, fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 13.sp) }
        }
    }
    Spacer(Modifier.height(8.dp))
}

@Composable
private fun Mono(text: String) {
    Text(text, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
}
