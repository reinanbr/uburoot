package com.reinanbr.uburoot.terminal

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.viewinterop.AndroidView
import com.reinanbr.uburoot.ui.MainActivity
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import kotlin.math.roundToInt

class TerminalActivity : ComponentActivity() {
    private lateinit var terminalView: TerminalView
    private var textSizePx = 0
    private var minTextSizePx = 0
    private var maxTextSizePx = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        textSizePx = sp(14f)
        minTextSizePx = sp(6f)
        maxTextSizePx = sp(40f)

        terminalView = TerminalView(this, null).apply {
            setTerminalViewClient(viewClient)
            setTextSize(textSizePx)
            isFocusable = true
            isFocusableInTouchMode = true
            keepScreenOn = true
        }
        terminalView.attachSession(SessionHolder.getOrCreate(this, sessionClient))

        setContent {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black)
                    // safeDrawing includes the IME, so the terminal shrinks
                    // above the keyboard instead of being covered by it.
                    .windowInsetsPadding(WindowInsets.safeDrawing),
            ) {
                AndroidView(factory = { terminalView }, modifier = Modifier.fillMaxSize())
            }
        }
    }

    override fun onResume() {
        super.onResume()
        terminalView.post { showKeyboard() }
    }

    private fun showKeyboard() {
        terminalView.requestFocus()
        getSystemService(InputMethodManager::class.java).showSoftInput(terminalView, 0)
    }

    /**
     * Back through the preflight instead of respawning enter.sh blindly: the
     * rootfs may have been reset or the root grant revoked meanwhile, and
     * MainActivity routes to the installer or opens a fresh session.
     */
    private fun restartSession() {
        SessionHolder.clear()
        startActivity(Intent(this, MainActivity::class.java))
        finish()
    }

    private fun sp(value: Float) =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, value, resources.displayMetrics).roundToInt()

    private val sessionClient = object : TerminalSessionClient {
        override fun onTextChanged(changedSession: TerminalSession) {
            if (changedSession == terminalView.currentSession) terminalView.onScreenUpdated()
        }

        override fun onTitleChanged(changedSession: TerminalSession) = Unit

        // TerminalSession itself prints "[Process completed ... - press Enter]".
        override fun onSessionFinished(finishedSession: TerminalSession) = terminalView.onScreenUpdated()

        override fun onCopyTextToClipboard(session: TerminalSession, text: String) {
            getSystemService(ClipboardManager::class.java)
                .setPrimaryClip(ClipData.newPlainText("UbuRoot", text))
        }

        override fun onPasteTextFromClipboard(session: TerminalSession) {
            val clip = getSystemService(ClipboardManager::class.java).primaryClip ?: return
            val text = clip.getItemAt(0)?.coerceToText(this@TerminalActivity)?.toString() ?: return
            session.emulator?.paste(text)
        }

        override fun onBell(session: TerminalSession) = Unit
        override fun onColorsChanged(session: TerminalSession) = terminalView.invalidate()
        override fun onTerminalCursorStateChange(state: Boolean) = Unit
        override fun getTerminalCursorStyle(): Int = TerminalEmulator.DEFAULT_TERMINAL_CURSOR_STYLE

        override fun logError(tag: String, message: String) { Log.e(tag, message) }
        override fun logWarn(tag: String, message: String) { Log.w(tag, message) }
        override fun logInfo(tag: String, message: String) { Log.i(tag, message) }
        override fun logDebug(tag: String, message: String) { Log.d(tag, message) }
        override fun logVerbose(tag: String, message: String) { Log.v(tag, message) }
        override fun logStackTraceWithMessage(tag: String, message: String, e: Exception) { Log.e(tag, message, e) }
        override fun logStackTrace(tag: String, e: Exception) { Log.e(tag, "", e) }
    }

    private val viewClient = object : TerminalViewClient {
        override fun onScale(scale: Float): Float {
            if (scale in 0.9f..1.1f) return scale
            val step = sp(1f).coerceAtLeast(1)
            textSizePx = (textSizePx + if (scale > 1f) step else -step).coerceIn(minTextSizePx, maxTextSizePx)
            terminalView.setTextSize(textSizePx)
            return 1f
        }

        override fun onSingleTapUp(e: MotionEvent) = showKeyboard()
        override fun shouldBackButtonBeMappedToEscape() = false
        override fun shouldEnforceCharBasedInput() = false
        override fun shouldUseCtrlSpaceWorkaround() = false
        override fun isTerminalViewSelected() = true
        override fun copyModeChanged(copyMode: Boolean) = Unit

        override fun onKeyDown(keyCode: Int, e: KeyEvent, session: TerminalSession): Boolean {
            if (!session.isRunning) {
                if (keyCode == KeyEvent.KEYCODE_ENTER) restartSession()
                return true
            }
            return false
        }

        override fun onKeyUp(keyCode: Int, e: KeyEvent) = false
        override fun onLongPress(event: MotionEvent) = false
        override fun readControlKey() = false
        override fun readAltKey() = false
        override fun readShiftKey() = false
        override fun readFnKey() = false
        override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession) = false
        override fun onEmulatorSet() = Unit

        override fun logError(tag: String, message: String) { Log.e(tag, message) }
        override fun logWarn(tag: String, message: String) { Log.w(tag, message) }
        override fun logInfo(tag: String, message: String) { Log.i(tag, message) }
        override fun logDebug(tag: String, message: String) { Log.d(tag, message) }
        override fun logVerbose(tag: String, message: String) { Log.v(tag, message) }
        override fun logStackTraceWithMessage(tag: String, message: String, e: Exception) { Log.e(tag, message, e) }
        override fun logStackTrace(tag: String, e: Exception) { Log.e(tag, "", e) }
    }
}
