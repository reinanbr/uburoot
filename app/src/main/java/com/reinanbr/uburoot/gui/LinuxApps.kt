// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.gui

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.Sh
import com.reinanbr.uburoot.root.UbuPaths

/** One GUI entry from `x11.sh apps`: `ID|NAME|ICON`. */
data class LinuxApp(val id: String, val name: String, val icon: String)

/** `x11.sh status`: the X server (Termux:X11) and the window manager. */
data class X11Status(
    /** missing (Termux:X11 not installed), stopped or running. */
    val x11: String,
    /** The running window manager's name, "none", or "missing" (not installed). */
    val wm: String,
) {
    val installed get() = x11 != "missing"

    companion object {
        fun parse(lines: List<String>): X11Status {
            val m = lines.mapNotNull { l ->
                l.indexOf('=').takeIf { it > 0 }?.let {
                    l.substring(0, it) to
                        l.substring(it + 1)
                }
            }
                .toMap()
            return X11Status(m["x11"] ?: "missing", m["wm"] ?: "missing")
        }
    }
}

/**
 * Linux GUI apps through Termux:X11 (docs/GUI.md): x11.sh starts its X server as root
 * for Ubuntu and the app opens Termux:X11's activity, which shows it.
 */
object LinuxApps {
    const val X11_PACKAGE = "com.termux.x11"
    const val X11_RELEASES = "https://github.com/termux/termux-x11/releases"
    private val x11 = UbuPaths.script("x11.sh")

    fun parseApps(lines: List<String>): List<LinuxApp> = lines.mapNotNull { l ->
        val f = l.split('|')
        if (f.size >= 3 && f[0].isNotEmpty() && f[1].isNotEmpty()) LinuxApp(f[0], f[1], f[2]) else null
    }

    /** `ID|BASE64` lines of `x11.sh icons`. */
    fun parseIcons(lines: List<String>): Map<String, String> = lines.mapNotNull { l ->
        val i = l.indexOf('|')
        if (i > 0 && i < l.length - 1) l.substring(0, i) to l.substring(i + 1) else null
    }.toMap()

    suspend fun status() = X11Status.parse(RootShell.run("$x11 status").out)

    suspend fun apps(user: String) = parseApps(RootShell.run("$x11 apps ${Sh.quote(user)}").out)

    suspend fun icons(user: String) = parseIcons(RootShell.run("$x11 icons ${Sh.quote(user)}").out)

    /** Starts the X server if needed, then the app as [user]. */
    suspend fun run(user: String, id: String) = RootShell.run("$x11 run ${Sh.quote(user)} ${Sh.quote(id)}")

    suspend fun stop() = RootShell.run("$x11 stop")

    /** Termux:X11's own screen, where the X server's windows are. */
    fun openDisplay(context: Context): Boolean = try {
        context.startActivity(
            Intent().setComponent(ComponentName(X11_PACKAGE, "$X11_PACKAGE.MainActivity"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        true
    } catch (_: ActivityNotFoundException) {
        false
    }

    /** The user apps run as: DEFAULT_USER, else root. */
    fun userOf(defaultUser: String) = defaultUser.ifEmpty { "root" }
}
