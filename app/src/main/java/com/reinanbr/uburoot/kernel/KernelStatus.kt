// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.kernel

/** One recorded kernel change from kernel.sh: `change=TYPE NAME ORIGINAL`. */
data class KernelChange(val type: String, val name: String, val original: String)

/** Parsed output of `kernel.sh status` (key=value lines). */
data class KernelStatus(
    val access: Boolean,
    val selinux: String,
    val devMode: Boolean,
    val modulesLoaded: Int,
    /** kernel.kptr_restrict etc. as reported, in order. */
    val sysctls: List<Pair<String, String>>,
    val changes: List<KernelChange>,
) {
    val permissive get() = selinux == "permissive"

    companion object {
        fun parse(lines: List<String>): KernelStatus {
            var access = false
            var selinux = "absent"
            var devMode = false
            var modules = 0
            val sysctls = mutableListOf<Pair<String, String>>()
            val changes = mutableListOf<KernelChange>()
            for (line in lines) {
                val i = line.indexOf('=')
                if (i <= 0) continue
                val key = line.substring(0, i)
                val value = line.substring(i + 1)
                when {
                    key == "access" -> access = value == "on"

                    key == "selinux" -> selinux = value

                    key == "devmode" -> devMode = value == "on"

                    key == "modules_loaded" -> modules = value.toIntOrNull() ?: 0

                    key == "change" -> {
                        val parts = value.split(' ', limit = 3)
                        if (parts.size >= 2) changes += KernelChange(parts[0], parts[1], parts.getOrElse(2) { "" })
                    }

                    key.startsWith("kernel.") -> sysctls += key to value
                }
            }
            return KernelStatus(access, selinux, devMode, modules, sysctls, changes)
        }

        /** `kernel.sh module list`: "* name" = loaded through UbuRoot, "  name" = by Android. */
        fun parseModules(lines: List<String>): List<Pair<String, Boolean>> = lines.mapNotNull { l ->
            when {
                l.startsWith("* ") -> l.substring(2).trim() to true
                l.startsWith("  ") && l.isNotBlank() -> l.trim() to false
                else -> null
            }
        }
    }
}
