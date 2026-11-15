package com.reinanbr.uburoot.root

import com.topjohnwu.superuser.CallbackList
import com.topjohnwu.superuser.Shell
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Thin coroutine wrapper over the libsu main shell. The default builder (see
 * UbuRootApp) asks for `su --mount-master`; libsu silently falls back to plain
 * `su` and then `sh`, so callers must check [RootInfo.globalNamespace].
 */
object RootShell {
    data class Result(val code: Int, val out: List<String>) {
        val ok get() = code == 0
        val text get() = out.joinToString("\n")
    }

    /**
     * Blocks until the root manager answers the grant prompt. libsu caches the
     * main shell, and after a denial that is the non-root `sh` fallback: drop
     * it so a retry asks `su` again.
     */
    suspend fun isRoot(): Boolean = withContext(Dispatchers.IO) {
        Shell.getCachedShell()?.let { if (!it.isRoot) it.close() }
        Shell.getShell().isRoot
    }

    /** Run [cmd] with stderr merged into stdout. */
    suspend fun run(cmd: String): Result = withContext(Dispatchers.IO) {
        val r = Shell.cmd(merged(cmd)).exec()
        Result(r.code, r.out)
    }

    /** Run [cmd], delivering each output line to [onLine] on the main thread. */
    suspend fun stream(cmd: String, onLine: (String) -> Unit): Int = withContext(Dispatchers.IO) {
        val lines = object : CallbackList<String>() {
            override fun onAddElement(e: String) = onLine(e)
        }
        Shell.cmd(merged(cmd)).to(lines).exec().code
    }

    // A subshell, so `set -e`, `cd` or `exit` never leak into the shared shell.
    private fun merged(cmd: String) = "(\n$cmd\n) 2>&1"
}
