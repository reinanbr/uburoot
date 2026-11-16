// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import com.reinanbr.uburoot.R

/**
 * App license (GPL-3.0-or-later) and the third-party notices. The texts are the
 * repository's LICENSE, NOTICE and LICENSES/ files, copied into the APK's assets at
 * build time (LicenseAssetsTask in app/build.gradle.kts).
 */
class AboutActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val version = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull().orEmpty()
        setContent {
            UbuRootTheme {
                Surface(Modifier.fillMaxSize()) { About(version) }
            }
        }
    }

    @Composable
    private fun About(version: String) {
        var shown by rememberSaveable { mutableStateOf<String?>(null) }
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
                Text(stringResource(R.string.about_title), style = MaterialTheme.typography.headlineSmall)
            }
            Text("${stringResource(R.string.app_name)} $version", style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.about_license))
            OutlinedButton(
                onClick = { startActivity(Intent(Intent.ACTION_VIEW, SOURCE.toUri())) },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.about_source)) }
            for ((file, label) in TEXTS) {
                OutlinedButton(
                    onClick = { shown = if (shown == file) null else file },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(label)) }
                if (shown == file) {
                    Text(
                        readAsset(file),
                        fontFamily = FontFamily.Monospace,
                        fontSize = 10.sp,
                        lineHeight = 12.sp,
                    )
                }
            }
        }
    }

    private fun readAsset(name: String): String =
        runCatching { assets.open("licenses/$name").bufferedReader().use { it.readText() } }.getOrDefault("")

    private companion object {
        const val SOURCE = "https://github.com/reinanbr/uburoot"
        val TEXTS = listOf(
            "NOTICE" to R.string.about_notice,
            "GPL-3.0-or-later.txt" to R.string.about_gpl,
            "Apache-2.0.txt" to R.string.about_apache,
        )
    }
}
