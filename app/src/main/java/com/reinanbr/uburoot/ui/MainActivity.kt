package com.reinanbr.uburoot.ui

import android.content.Intent
import android.os.Bundle
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
                LaunchedEffect(stage) {
                    if (stage == Stage.Ready) {
                        startActivity(Intent(this@MainActivity, TerminalActivity::class.java))
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
}
