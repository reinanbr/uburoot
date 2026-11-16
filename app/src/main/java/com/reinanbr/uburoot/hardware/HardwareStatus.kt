// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.hardware

/** One hardware class from `hardware.sh status`: `class=NAME|ROUTE|STATE|NODES|GROUP|USERS`. */
data class HwClass(
    val name: String,
    /** direct, bridge, takeover, read or none. */
    val route: String,
    /** available, missing, taken, unsupported or bridge. */
    val state: String,
    val nodes: Int,
    /** Ubuntu group that grants it (empty: none). */
    val group: String,
    val users: List<String>,
)

/** A cpufreq policy: `cpu=POLICY|CPUS|GOVERNOR|MIN|MAX|HWMAX` (kHz). */
data class CpuPolicy(
    val name: String,
    val cpus: String,
    val governor: String,
    val min: Int,
    val max: Int,
    val hwMax: Int,
)

/** Parsed output of `hardware.sh status`. */
data class HardwareStatus(
    val access: Boolean,
    val classes: List<HwClass>,
    val cpus: List<CpuPolicy>,
    /** "85|Charging|312" = percent, status, tenths of a degree; null if there is no battery. */
    val battery: Triple<Int?, String, Int?>?,
    val wakeLock: Boolean,
    val changes: Int,
    /** Bridges whose token file is published in Ubuntu: `bridge=NAME|on`. */
    val bridges: Set<String> = emptySet(),
    /** UbuRoot's functions in the USB gadget (`gadget=ncm,acm|UDC`); empty = none. */
    val gadget: List<String> = emptyList(),
) {
    val wifiTaken get() = classes.any { it.name == "wifi" && it.state == "taken" }

    companion object {
        fun parse(lines: List<String>): HardwareStatus {
            var access = false
            val classes = mutableListOf<HwClass>()
            val cpus = mutableListOf<CpuPolicy>()
            var battery: Triple<Int?, String, Int?>? = null
            var wake = false
            var changes = 0
            val bridges = mutableSetOf<String>()
            var gadget = emptyList<String>()
            for (line in lines) {
                val i = line.indexOf('=')
                if (i <= 0) continue
                val value = line.substring(i + 1)
                when (line.substring(0, i)) {
                    "access" -> access = value == "on"

                    "class" -> {
                        val f = value.split('|')
                        if (f.size >= 6) {
                            classes += HwClass(
                                name = f[0],
                                route = f[1],
                                state = f[2],
                                nodes = f[3].toIntOrNull() ?: 0,
                                group = f[4],
                                users = f[5].split(',').filter { it.isNotBlank() },
                            )
                        }
                    }

                    "cpu" -> {
                        val f = value.split('|')
                        if (f.size >= 6) {
                            cpus += CpuPolicy(
                                f[0],
                                f[1],
                                f[2],
                                f[3].toIntOrNull() ?: 0,
                                f[4].toIntOrNull() ?: 0,
                                f[5].toIntOrNull() ?: 0,
                            )
                        }
                    }

                    "battery" -> {
                        val f = value.split('|')
                        battery =
                            Triple(f.getOrNull(0)?.toIntOrNull(), f.getOrElse(1) { "" }, f.getOrNull(2)?.toIntOrNull())
                    }

                    "wakelock" -> wake = value == "on"

                    "changes" -> changes = value.toIntOrNull() ?: 0

                    "bridge" -> if (value.endsWith("|on")) bridges += value.substringBefore('|')

                    "gadget" -> gadget = value.substringBefore('|').split(',').filter { it.isNotBlank() }
                }
            }
            return HardwareStatus(access, classes, cpus, battery, wake, changes, bridges, gadget)
        }
    }
}
