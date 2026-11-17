// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.gui

import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.Sh
import com.reinanbr.uburoot.root.UbuPaths

/** `gpu.sh status`. */
data class GpuStatus(
    /** "adreno" or "none". */
    val gpu: String,
    val model: String,
    val installed: Boolean,
    val mesa: String,
    val zink: Boolean,
) {
    val adreno get() = gpu == "adreno"

    companion object {
        fun parse(lines: List<String>): GpuStatus {
            val m = lines.mapNotNull { l ->
                val i = l.indexOf('=')
                if (i > 0) l.substring(0, i) to l.substring(i + 1) else null
            }.toMap()
            return GpuStatus(
                gpu = m["gpu"] ?: "none",
                model = m["model"].orEmpty(),
                installed = m["driver"] == "installed",
                mesa = m["mesa"].orEmpty(),
                zink = m["zink"] == "on",
            )
        }
    }
}

/**
 * GPU acceleration (docs/GUI.md): Mesa's Turnip built with Android's KGSL backend
 * (tools/gpu/build-turnip.sh), published by CI with each release; gpu.sh installs it
 * into Ubuntu and turns on Zink (OpenGL on Vulkan).
 */
object Gpu {
    const val ASSET = "turnip-kgsl-arm64.tar.gz"
    const val RELEASE = "https://github.com/reinanbr/uburoot/releases/latest/download/"
    private val gpu = UbuPaths.script("gpu.sh")

    /** The SHA-256 of [name] in a `SHA256SUMS` file (`HASH  NAME` or `HASH *NAME`). */
    fun sumFor(sums: String, name: String): String? = sums.lineSequence().mapNotNull { l ->
        val f = l.trim().split(Regex("\\s+"), limit = 2)
        if (f.size == 2 && f[1].removePrefix("*") == name && f[0].matches(Regex("[0-9a-fA-F]{64}"))) {
            f[0].lowercase()
        } else {
            null
        }
    }.firstOrNull()

    suspend fun status() = GpuStatus.parse(RootShell.run("$gpu status").out)

    suspend fun install(path: String, sha256: String) =
        RootShell.run("$gpu install ${Sh.quote(path)} ${Sh.quote(sha256)}")

    suspend fun remove() = RootShell.run("$gpu remove")

    suspend fun zink(on: Boolean) = RootShell.run("$gpu zink ${if (on) "on" else "off"}")

    /** `vulkan=…` and `opengl=…` as [user] sees them. */
    suspend fun renderer(user: String) = RootShell.run("$gpu renderer ${Sh.quote(user)}").out
}
