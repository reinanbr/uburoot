package com.reinanbr.uburoot.install

import com.reinanbr.uburoot.root.Sh

/** uburoot.conf: shell variables sourced as root by every script. */
data class UbuConfig(
    val defaultUser: String = "",
    val mountSdcard: Boolean = true,
    val androidIntegration: Boolean = true,
    val dnsServers: String = "1.1.1.1 9.9.9.9",
    val initCommand: String = "",
    val hostname: String = "uburoot",
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
    }

    private fun StringBuilder.line(key: String, value: String) {
        append(key).append('=').append(Sh.quote(value)).append('\n')
    }

    companion object {
        private val USER_NAME = Regex("[a-z_][a-z0-9_-]{0,31}")

        // Accounts that already exist in Ubuntu Base: setup.sh would reuse
        // them (and grant sudo) instead of creating a new user.
        private val RESERVED = setOf(
            "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news",
            "uucp", "proxy", "www-data", "backup", "list", "irc", "_apt", "nobody",
        )

        fun isValidUserName(name: String) = USER_NAME.matches(name) && name !in RESERVED
    }
}
