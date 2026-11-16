// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.root

/** Parsed output of rootinfo.sh (`key=value` lines). */
data class RootInfo(private val values: Map<String, String>) {
    val impl get() = values["impl"].orEmpty().ifEmpty { "unknown" }
    val version get() = values["version"].orEmpty()
    val busybox get() = values["busybox"].orEmpty().ifEmpty { "none" }
    val arch get() = values["arch"].orEmpty()
    val freeBytes: Long? get() = values["free_kb"]?.toLongOrNull()?.times(1024)
    val rootfsInstalled get() = values["rootfs"] == "installed"
    val setupDone get() = values["setup"] == "done"
    val isArm64 get() = arch == "aarch64"

    /** Mounts are only visible to every session from the init mount namespace. */
    val globalNamespace: Boolean
        get() {
            val ns = values["mnt_ns"].orEmpty()
            return ns.isNotEmpty() && ns == values["init_mnt_ns"]
        }

    companion object {
        fun parse(lines: List<String>): RootInfo = RootInfo(
            lines.mapNotNull { line ->
                val i = line.indexOf('=')
                if (i > 0) line.substring(0, i) to line.substring(i + 1) else null
            }.toMap(),
        )
    }
}
