// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot

import android.app.Application
import com.topjohnwu.superuser.Shell

class UbuRootApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // Every root call runs in the global mount namespace (CLAUDE.md:
        // "always pass --mount-master"); libsu builds `su --mount-master`.
        Shell.setDefaultBuilder(
            Shell.Builder.create()
                .setFlags(Shell.FLAG_MOUNT_MASTER)
                .setTimeout(60),
        )
    }
}
