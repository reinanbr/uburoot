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

/** One open window from `x11.sh windows`: `WINDOW|ID|TITLE` (ID: its app, may be empty). */
data class LinuxWindow(val window: String, val app: String, val title: String)

/** `x11.sh status`: the X server (Termux:X11), the window manager and the extras. */
data class X11Status(
    /** missing (Termux:X11 not installed), stopped or running. */
    val x11: String,
    /** The running window manager's name, "none", or "missing" (not installed). */
    val wm: String,
    /** wmctrl is installed: open windows can be listed and switched. */
    val switch: Boolean = false,
    /** The XFCE desktop: missing, ready or running. */
    val desktop: String = "missing",
    /** Firefox (from Mozilla's repository): installed or missing. */
    val firefox: String = "missing",
    /** The VNC desktop: missing, off, local (this phone only) or lan (Wi-Fi, TLS). */
    val vnc: String = "missing",
    /** Where it listens (`IP:PORT`) while on. */
    val vncAddr: String = "",
) {
    val installed get() = x11 != "missing"
    val running get() = x11 == "running"

    /** The window tools (matchbox + wmctrl) need installing. */
    val toolsMissing get() = wm == "missing" || !switch

    companion object {
        fun parse(lines: List<String>): X11Status {
            val m = lines.mapNotNull { l ->
                l.indexOf('=').takeIf { it > 0 }?.let {
                    l.substring(0, it) to
                        l.substring(it + 1)
                }
            }
                .toMap()
            return X11Status(
                x11 = m["x11"] ?: "missing",
                wm = m["wm"] ?: "missing",
                switch = m["switch"] == "yes",
                desktop = m["desktop"] ?: "missing",
                firefox = m["firefox"] ?: "missing",
                vnc = m["vnc"] ?: "missing",
                vncAddr = m["vnc_addr"].orEmpty(),
            )
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

    fun parseWindows(lines: List<String>): List<LinuxWindow> = lines.mapNotNull { l ->
        val f = l.split('|', limit = 3)
        if (f.size == 3 && f[0].matches(Regex("0x[0-9a-fA-F]+"))) LinuxWindow(f[0], f[1], f[2]) else null
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

    suspend fun windows(user: String) = parseWindows(RootShell.run("$x11 windows ${Sh.quote(user)}").out)

    suspend fun focus(window: String) = RootShell.run("$x11 focus ${Sh.quote(window)}")

    suspend fun close(window: String) = RootShell.run("$x11 close ${Sh.quote(window)}")

    /** The XFCE desktop session as [user] (starts the X server if needed). */
    suspend fun desktop(user: String) = RootShell.run("$x11 desktop ${Sh.quote(user)}")

    /** apt: the window tools, or "desktop" (XFCE) / "vnc" (TigerVNC). */
    fun setupCmd(what: String = "") = "$x11 setup" + if (what.isEmpty()) "" else " $what"

    /**
     * A VNC password x11.sh accepts (6–8 printable ASCII characters). Stricter here: it
     * travels through `echo` (a builtin, so in no argv), which may read a leading "-" or
     * a backslash.
     */
    fun vncPasswordOk(p: String) = p.length in 6..8 && p.all { it in '!'..'~' && it != '\\' } && !p.startsWith("-")

    /** Sets [user]'s VNC password (on stdin, never in an argument). */
    suspend fun vncPassword(user: String, password: String): RootShell.Result {
        require(vncPasswordOk(password))
        return RootShell.run("echo ${Sh.quote(password)} | $x11 vnc password ${Sh.quote(user)}")
    }

    suspend fun vncStart(user: String, lan: Boolean) =
        RootShell.run("$x11 vnc start ${Sh.quote(user)}" + if (lan) " lan" else "")

    suspend fun vncStop() = RootShell.run("$x11 vnc stop")

    /** Adds Mozilla's APT repository and installs Firefox from it. */
    val firefoxCmd get() = "$x11 firefox"

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
