// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.gui

import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import com.reinanbr.uburoot.R
import com.reinanbr.uburoot.install.ConfigStore
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.ScriptDeployer
import kotlinx.coroutines.launch

/**
 * Target of a Linux app's launcher shortcut: no screen of its own. Starts the X server
 * and the app (x11.sh run), then shows Termux:X11, the way an Android app opens.
 */
class LaunchActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val id = intent.getStringExtra(EXTRA_ID)
        val name = intent.getStringExtra(EXTRA_NAME) ?: id
        if (id.isNullOrEmpty()) return finish()
        Toast.makeText(this, getString(R.string.gui_opening, name), Toast.LENGTH_SHORT).show()
        lifecycleScope.launch {
            val error = when {
                !RootShell.isRoot() -> getString(R.string.gui_no_root)

                // The scripts may be older than the app (opened from a shortcut after an update).
                !ScriptDeployer.deploy(applicationContext).ok -> getString(R.string.gui_failed, name, "deploy")

                else -> {
                    val user = LinuxApps.userOf(runCatching { ConfigStore.read().defaultUser }.getOrDefault(""))
                    val r = LinuxApps.run(user, id)
                    if (r.ok) null else getString(R.string.gui_failed, name, r.out.lastOrNull().orEmpty())
                }
            }
            if (error != null) {
                Toast.makeText(applicationContext, error, Toast.LENGTH_LONG).show()
            } else if (!LinuxApps.openDisplay(applicationContext)) {
                Toast.makeText(applicationContext, R.string.gui_x11_missing, Toast.LENGTH_LONG).show()
            }
            finish()
        }
    }

    companion object {
        const val EXTRA_ID = "id"
        const val EXTRA_NAME = "name"
    }
}
