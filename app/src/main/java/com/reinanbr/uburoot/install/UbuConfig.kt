// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.install

import com.reinanbr.uburoot.root.Sh

/** uburoot.conf: shell variables sourced as root by every script. */
data class UbuConfig(
    val defaultUser: String = "",
    val mountSdcard: Boolean = true,
    val androidIntegration: Boolean = true,
    val dnsServers: String = DEFAULT_DNS,
    val initCommand: String = "",
    val hostname: String = "uburoot",
    /** Raised (never lowered) by mount.sh; global kernel setting. 0 = leave alone. */
    val inotifyMaxWatches: Int = DEFAULT_INOTIFY,
    /** Optional override of the /sdcard bind source (empty = auto-detect). */
    val sdcardSource: String = "",
    /** The root module's service.sh runs boot.sh at boot (mount + /etc/uburoot-boot.d). */
    val bootStart: Boolean = false,
    /** http:// Ubuntu ports mirror for the release suites (empty = ports.ubuntu.com); setup.sh. */
    val aptMirror: String = "",
    /** Keys this app version doesn't know (hand edits, newer versions): kept as they are. */
    val extra: Map<String, String> = emptyMap(),
) {
    /** Every value is single-quoted: the file is executed by a root shell. */
    fun render(): String = buildString {
        appendLine("# Written by the UbuRoot app. Sourced by the scripts as root.")
        line("MOUNT_SDCARD", if (mountSdcard) "1" else "0")
        line("ANDROID_INTEGRATION", if (androidIntegration) "1" else "0")
        line("DNS_SERVERS", dnsServers)
        line("DEFAULT_USER", defaultUser)
        line("INIT_COMMAND", initCommand)
        line("UBU_HOSTNAME", hostname)
        line("INOTIFY_MAX_WATCHES", inotifyMaxWatches.coerceAtLeast(0).toString())
        if (sdcardSource.isNotEmpty()) line("SDCARD_SOURCE", sdcardSource)
        line("BOOT_START", if (bootStart) "1" else "0")
        if (aptMirror.isNotEmpty()) line("APT_MIRROR", aptMirror)
        for ((k, v) in extra) if (k !in KNOWN && SHELL_NAME.matches(k)) line(k, v)
    }

    private fun StringBuilder.line(key: String, value: String) {
        append(key).append('=').append(Sh.quote(value)).append('\n')
    }

    companion object {
        const val DEFAULT_DNS = "1.1.1.1 9.9.9.9"
        const val DEFAULT_INOTIFY = 524288

        private val USER_NAME = Regex("[a-z_][a-z0-9_-]{0,31}")
        private val SHELL_NAME = Regex("[A-Za-z_][A-Za-z0-9_]*")
        private val DNS_SERVER = Regex("[0-9a-fA-F.:]+")
        private val KNOWN = setOf(
            "MOUNT_SDCARD",
            "ANDROID_INTEGRATION",
            "DNS_SERVERS",
            "DEFAULT_USER",
            "INIT_COMMAND",
            "UBU_HOSTNAME",
            "INOTIFY_MAX_WATCHES",
            "SDCARD_SOURCE",
            "BOOT_START",
            "APT_MIRROR",
        )

        // Accounts that already exist in Ubuntu Base: setup.sh would reuse
        // them (and grant sudo) instead of creating a new user.
        private val RESERVED = setOf(
            "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news",
            "uucp", "proxy", "www-data", "backup", "list", "irc", "_apt", "nobody",
        )

        fun isValidUserName(name: String) = USER_NAME.matches(name) && name !in RESERVED

        /** The same rule as setup.sh: at least one server, each only hex digits, dots and colons. */
        fun isValidDns(servers: String): Boolean {
            val list = servers.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
            return list.isNotEmpty() && list.all { DNS_SERVER.matches(it) }
        }

        /**
         * The same rule as `ubu_valid_mirror` in common.sh: plain http (Ubuntu Base has no
         * CA certificates before its first apt run), a host, an optional path, a final `/`.
         */
        fun isValidMirror(url: String) = MIRROR.matches(url)

        private val MIRROR = Regex("http://[A-Za-z0-9._~:-]+(/[A-Za-z0-9._~:-]+)*/")

        /** Reads a file written by [render]; missing keys get the scripts' defaults. */
        fun parse(text: String): UbuConfig {
            val map = ShellAssignments.parse(text)
            val d = UbuConfig()
            fun flag(key: String, default: Boolean) = map[key]?.let { it == "1" } ?: default
            return UbuConfig(
                defaultUser = map["DEFAULT_USER"] ?: d.defaultUser,
                mountSdcard = flag("MOUNT_SDCARD", d.mountSdcard),
                androidIntegration = flag("ANDROID_INTEGRATION", d.androidIntegration),
                dnsServers = map["DNS_SERVERS"]?.takeIf { it.isNotBlank() } ?: d.dnsServers,
                initCommand = map["INIT_COMMAND"] ?: d.initCommand,
                hostname = map["UBU_HOSTNAME"]?.takeIf { it.isNotBlank() } ?: d.hostname,
                inotifyMaxWatches = map["INOTIFY_MAX_WATCHES"]?.toIntOrNull() ?: d.inotifyMaxWatches,
                sdcardSource = map["SDCARD_SOURCE"] ?: d.sdcardSource,
                bootStart = flag("BOOT_START", d.bootStart),
                aptMirror = map["APT_MIRROR"] ?: d.aptMirror,
                extra = map.filterKeys { it !in KNOWN },
            )
        }
    }
}

/**
 * Minimal reader for `KEY=value` lines as a POSIX shell would assign them:
 * single quotes, double quotes (with `\` escapes) and bare words, concatenated.
 * Enough for what [UbuConfig.render] writes and for simple hand edits; anything
 * else (commands, `$`) is kept literally and never executed here.
 */
object ShellAssignments {
    private val ASSIGNMENT = Regex("^\\s*(?:export\\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")

    fun parse(text: String): LinkedHashMap<String, String> {
        val out = LinkedHashMap<String, String>()
        for (line in text.lineSequence()) {
            val m = ASSIGNMENT.find(line) ?: continue
            out[m.groupValues[1]] = value(m.groupValues[2])
        }
        return out
    }

    private fun value(s: String): String {
        val b = StringBuilder()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            when {
                c == '\'' -> {
                    val end = s.indexOf('\'', i + 1).let { if (it < 0) s.length else it }
                    b.append(s, i + 1, end)
                    i = end + 1
                }

                c == '"' -> {
                    i++
                    while (i < s.length && s[i] != '"') {
                        if (s[i] == '\\' && i + 1 < s.length && s[i + 1] in "\"\\$`") i++
                        b.append(s[i])
                        i++
                    }
                    i++
                }

                c == '\\' && i + 1 < s.length -> {
                    b.append(s[i + 1])
                    i += 2
                }

                c.isWhitespace() || c == ';' || c == '#' -> break

                else -> {
                    b.append(c)
                    i++
                }
            }
        }
        return b.toString()
    }
}
