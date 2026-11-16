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

    /**
     * UbuRoot requires root with full kernel access: every capability in the
     * effective and bounding sets, no seccomp filter, no no_new_privs
     * (`ubu_root_report` in common.sh). A root manager can hand out less, e.g. a
     * KernelSU App Profile with fewer capabilities. Older scripts don't report
     * it: then it is not checked.
     */
    val fullRoot: Boolean get() = values["full_root"] != "no"

    /** What the root gate saw, for the error screen. */
    val rootDetail: String
        get() = listOf("cap_eff", "cap_bnd", "seccomp", "no_new_privs", "selinux")
            .joinToString("\n") { "$it=${values[it].orEmpty()}" }

    /** Integration schema of the installed rootfs (/etc/uburoot-release; 0 = before it existed). */
    val schema: Int get() = values["schema"]?.toIntOrNull() ?: 0

    /** The schema these scripts write (UBU_SCHEMA). */
    val schemaCurrent: Int get() = values["schema_current"]?.toIntOrNull() ?: 0

    /** A set-up rootfs whose integration files are older than the scripts: `setup.sh --migrate`. */
    val needsMigration get() = rootfsInstalled && setupDone && schema < schemaCurrent

    companion object {
        fun parse(lines: List<String>): RootInfo = RootInfo(
            lines.mapNotNull { line ->
                val i = line.indexOf('=')
                if (i > 0) line.substring(0, i) to line.substring(i + 1) else null
            }.toMap(),
        )
    }
}
