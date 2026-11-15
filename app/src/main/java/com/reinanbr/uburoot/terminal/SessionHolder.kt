package com.reinanbr.uburoot.terminal

import android.content.Context
import com.reinanbr.uburoot.root.UbuPaths
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient

/**
 * Keeps the single MVP session alive across activity recreation. Phase 3
 * moves sessions into a foreground service.
 */
object SessionHolder {
    private const val TRANSCRIPT_ROWS = 5000

    var session: TerminalSession? = null
        private set

    fun getOrCreate(context: Context, client: TerminalSessionClient): TerminalSession {
        session?.let {
            if (it.isRunning) {
                it.updateTerminalSessionClient(client)
                return it
            }
        }
        return create(context, client)
    }

    fun clear() {
        session?.finishIfRunning()
        session = null
    }

    fun create(context: Context, client: TerminalSessionClient): TerminalSession {
        session?.finishIfRunning()
        return TerminalSession(
            "su",
            context.filesDir.absolutePath,
            // The command must be ONE string after -c: Magisk joins trailing
            // args, but ksud/apd only take the value of -c (see CLAUDE.md).
            arrayOf("su", "--mount-master", "-c", UbuPaths.script("enter.sh")),
            environment(),
            TRANSCRIPT_ROWS,
            client,
        ).also { session = it }
    }

    /**
     * The app's own environment (PATH to find su, BOOTCLASSPATH etc. for
     * android-env) plus the terminal type. enter.sh starts the chroot with
     * `env -i`, so none of this leaks into Ubuntu.
     */
    private fun environment(): Array<String> {
        val env = System.getenv().toMutableMap()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        return env.map { (k, v) -> "$k=$v" }.toTypedArray()
    }
}
