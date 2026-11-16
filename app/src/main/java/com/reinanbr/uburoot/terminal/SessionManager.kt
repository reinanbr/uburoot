package com.reinanbr.uburoot.terminal

import android.content.Context
import android.util.Log
import androidx.core.content.ContextCompat
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.Sh
import com.reinanbr.uburoot.root.UbuPaths
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Every terminal session of the process. They outlive the activity; while
 * there is at least one, [SessionService] runs in the foreground so Android
 * keeps the process (and the shells) alive. All calls on the main thread:
 * TerminalSession delivers its callbacks there.
 */
object SessionManager {
    private const val TRANSCRIPT_ROWS = 5000
    private const val TAG = "UbuRoot"

    data class State(val sessions: List<TerminalSession> = emptyList(), val version: Int = 0) {
        val running get() = sessions.count { it.isRunning }
    }

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()
    val sessions get() = _state.value.sessions

    /** The visible activity; callbacks that need a screen go there. */
    var client: TerminalSessionClient? = null

    private var counter = 0
    private val scope = MainScope()

    /**
     * A new chroot session. [user] null = DEFAULT_USER from uburoot.conf;
     * [cwd] = start directory inside Ubuntu (enter.sh's UBU_CWD).
     * The command must be ONE string after -c: Magisk joins trailing args,
     * but ksud/apd only take the value of -c (see CLAUDE.md).
     */
    fun create(context: Context, user: String? = null, cwd: String? = null): TerminalSession {
        val cmd = (cwd?.let { "UBU_CWD=${Sh.quote(it)} " } ?: "") +
            UbuPaths.script("enter.sh") + (user?.let { " " + Sh.quote(it) } ?: "")
        val app = context.applicationContext
        val session = TerminalSession(
            "su",
            app.filesDir.absolutePath,
            arrayOf("su", "--mount-master", "-c", cmd),
            environment(),
            TRANSCRIPT_ROWS,
            delegate,
        )
        session.mSessionName = (++counter).toString()
        _state.update { State(it.sessions + session, it.version + 1) }
        ContextCompat.startForegroundService(app, SessionService.intent(app))
        return session
    }

    /**
     * Drops the tab and hangs the session up. Killing our `su` client alone is
     * not enough: the chroot's session leader (util-linux su) blocks SIGHUP, so
     * the shell would keep running. hangup.sh signals what runs on that pty first.
     */
    fun close(session: TerminalSession) {
        _state.update { State(it.sessions - session, it.version + 1) }
        if (!session.isRunning) return
        val pid = session.pid
        scope.launch {
            if (pid > 0) RootShell.run("${UbuPaths.script("hangup.sh")} $pid")
            session.finishIfRunning()
        }
    }

    fun closeAll() {
        val all = sessions
        all.forEach { it.finishIfRunning() }
        _state.update { State(emptyList(), it.version + 1) }
    }

    fun title(session: TerminalSession): String {
        val t = session.title?.takeIf { it.isNotBlank() }
        return if (t == null) session.mSessionName else "${session.mSessionName}: $t"
    }

    private fun changed() = _state.update { it.copy(version = it.version + 1) }

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

    private val delegate = object : TerminalSessionClient {
        override fun onTextChanged(changedSession: TerminalSession) {
            client?.onTextChanged(changedSession)
        }

        override fun onTitleChanged(changedSession: TerminalSession) {
            changed()
            client?.onTitleChanged(changedSession)
        }

        // TerminalSession itself prints "[Process completed ... - press Enter]".
        override fun onSessionFinished(finishedSession: TerminalSession) {
            changed()
            client?.onSessionFinished(finishedSession)
        }

        override fun onCopyTextToClipboard(session: TerminalSession, text: String) {
            client?.onCopyTextToClipboard(session, text)
        }

        override fun onPasteTextFromClipboard(session: TerminalSession) {
            client?.onPasteTextFromClipboard(session)
        }

        override fun onBell(session: TerminalSession) {
            client?.onBell(session)
        }

        override fun onColorsChanged(session: TerminalSession) {
            client?.onColorsChanged(session)
        }

        override fun onTerminalCursorStateChange(state: Boolean) {
            client?.onTerminalCursorStateChange(state)
        }

        override fun getTerminalCursorStyle(): Int = TerminalEmulator.DEFAULT_TERMINAL_CURSOR_STYLE

        override fun logError(tag: String, message: String) {
            Log.e(TAG, "$tag: $message")
        }

        override fun logWarn(tag: String, message: String) {
            Log.w(TAG, "$tag: $message")
        }

        override fun logInfo(tag: String, message: String) {
            Log.i(TAG, "$tag: $message")
        }

        override fun logDebug(tag: String, message: String) = Unit

        override fun logVerbose(tag: String, message: String) = Unit

        override fun logStackTraceWithMessage(tag: String, message: String, e: Exception) {
            Log.e(TAG, "$tag: $message", e)
        }

        override fun logStackTrace(tag: String, e: Exception) {
            Log.e(TAG, tag, e)
        }
    }
}
