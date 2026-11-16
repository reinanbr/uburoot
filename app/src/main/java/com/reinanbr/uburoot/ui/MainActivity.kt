// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.reinanbr.uburoot.install.InstallViewModel
import com.reinanbr.uburoot.install.Stage
import com.reinanbr.uburoot.terminal.TerminalActivity

/** Preflight checks and first-run installer; hands over to the terminal. */
class MainActivity : ComponentActivity() {
    private val vm: InstallViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            UbuRootTheme {
                val stage by vm.stage.collectAsStateWithLifecycle()
                val log by vm.log.collectAsStateWithLifecycle()
                LaunchedEffect(stage is Stage.Working) {
                    // Install, setup and migrations: the screen stays on (a phone that
                    // locks may stop the app mid-extract).
                    if (stage is Stage.Working) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                LaunchedEffect(stage) {
                    if (stage == Stage.Ready) {
                        val cwd = intent.getStringExtra(EXTRA_CWD)
                        startActivity(TerminalActivity.intent(this@MainActivity, newSession = cwd != null, cwd = cwd))
                        finish()
                    }
                }
                InstallScreen(
                    stage = stage,
                    log = log,
                    onRetry = vm::check,
                    onInstall = vm::install,
                )
            }
        }
    }

    companion object {
        private const val EXTRA_CWD = "cwd"

        /** The preflight in a fresh task; then a session in [cwd] (a path inside Ubuntu), if given. */
        fun intent(context: Context, cwd: String? = null): Intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            .apply { if (cwd != null) putExtra(EXTRA_CWD, cwd) }
    }
}
