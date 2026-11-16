// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.terminal

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.addCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import com.reinanbr.uburoot.R
import com.reinanbr.uburoot.ui.AboutActivity
import com.reinanbr.uburoot.ui.HardwareActivity
import com.reinanbr.uburoot.ui.KernelActivity
import com.reinanbr.uburoot.ui.MainActivity
import com.reinanbr.uburoot.ui.SettingsActivity
import com.reinanbr.uburoot.ui.UbuRootTheme
import com.termux.terminal.KeyHandler
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import kotlin.math.roundToInt

/** Terminal tabs on top of [SessionManager]'s sessions, plus the extra keys. */
class TerminalActivity : ComponentActivity() {
    private lateinit var terminalView: TerminalView
    private lateinit var prefs: TerminalPrefs
    private var textSizeSp = TerminalPrefs.DEFAULT_TEXT_SIZE_SP

    private var current by mutableStateOf<TerminalSession?>(null)
    private var terminalTheme by mutableStateOf(TerminalTheme.DARK)
    private var ctrlDown by mutableStateOf(false)
    private var altDown by mutableStateOf(false)

    /** Set when the last session ended with Enter: go back through the preflight. */
    private var backToPreflight = false

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = TerminalPrefs(this)
        textSizeSp = prefs.textSizeSp
        // Before any session exists: new emulators copy the global scheme.
        applyTheme(prefs.theme)

        terminalView = TerminalView(this, null).apply {
            setTerminalViewClient(viewClient)
            setOnKeyListener { _, _, event -> onShortcut(event) }
            setTextSize(px(textSizeSp))
            isFocusable = true
            isFocusableInTouchMode = true
            keepScreenOn = true
        }
        SessionManager.client = sessionClient
        handleIntent(intent, fresh = savedInstanceState == null)

        onBackPressedDispatcher.addCallback(this) {
            // Keep the activity: the sessions live on, and coming back is instant.
            moveTaskToBack(true)
        }

        setContent { Screen() }
        askNotificationPermission()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent, fresh = true)
    }

    override fun onResume() {
        super.onResume()
        terminalView.post { showKeyboard() }
    }

    override fun onDestroy() {
        if (SessionManager.client === sessionClient) SessionManager.client = null
        super.onDestroy()
    }

    private fun handleIntent(intent: Intent?, fresh: Boolean) {
        val wantsNew = fresh && intent?.getBooleanExtra(EXTRA_NEW_SESSION, false) == true
        if (SessionManager.sessions.isEmpty() || wantsNew) {
            newSession(
                intent?.getStringExtra(EXTRA_USER),
                intent?.getStringExtra(EXTRA_CWD)?.takeIf { fresh },
                intent?.getStringExtra(EXTRA_COMMAND)?.takeIf { fresh },
            )
        } else {
            select(current?.takeIf { it in SessionManager.sessions } ?: SessionManager.sessions.last())
        }
    }

    private fun newSession(user: String? = null, cwd: String? = null, command: String? = null) =
        select(SessionManager.create(this, user, cwd, command))

    private fun select(session: TerminalSession) {
        terminalView.attachSession(session)
        current = session
        terminalView.requestFocus()
    }

    /** Close [session]'s tab; the neighbor takes its place. */
    private fun close(session: TerminalSession) {
        val list = SessionManager.sessions
        val i = list.indexOf(session)
        SessionManager.close(session)
        val rest = SessionManager.sessions
        if (rest.isEmpty()) return // Screen() sees the empty list and leaves
        if (session == current) select(rest[(i - 1).coerceIn(0, rest.lastIndex)])
    }

    private fun leave() {
        if (backToPreflight) startActivity(Intent(this, MainActivity::class.java))
        finish()
    }

    private fun toggleWakeLock() {
        startService(SessionService.intent(this, SessionService.ACTION_TOGGLE_WAKE_LOCK))
    }

    private fun stopAll() {
        startService(SessionService.intent(this, SessionService.ACTION_STOP_ALL))
    }

    private fun applyTheme(t: TerminalTheme) {
        terminalTheme = t
        t.apply(SessionManager.sessions)
        prefs.theme = t
        val bars = if (t.isLight) {
            SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT)
        } else {
            SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        }
        enableEdgeToEdge(statusBarStyle = bars, navigationBarStyle = bars)
        window.decorView.setBackgroundColor(t.background)
        if (::terminalView.isInitialized) terminalView.invalidate()
    }

    @Composable
    private fun Screen() {
        val state by SessionManager.state.collectAsState()
        val wakeLock by SessionService.wakeLockHeld.collectAsState()
        LaunchedEffect(state.sessions.isEmpty()) {
            if (state.sessions.isEmpty()) leave()
        }
        val fg = Color(terminalTheme.foreground)
        val bg = Color(terminalTheme.background)
        UbuRootTheme {
            Column(
                Modifier
                    .fillMaxSize()
                    .background(bg)
                    // safeDrawing includes the IME, so the terminal shrinks
                    // above the keyboard instead of being covered by it.
                    .windowInsetsPadding(WindowInsets.safeDrawing),
            ) {
                TabBar(state, wakeLock, fg, bg)
                AndroidView(
                    factory = { terminalView },
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                )
                ExtraKeys(fg, bg, ctrlDown, altDown, ::onExtraKey)
            }
        }
    }

    @Composable
    private fun TabBar(state: SessionManager.State, wakeLock: Boolean, fg: Color, bg: Color) {
        var menu by remember { mutableStateOf(false) }
        var confirmStop by remember { mutableStateOf(false) }
        Row(Modifier.fillMaxWidth().height(40.dp).background(bg), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()).fillMaxHeight()) {
                for (s in state.sessions) {
                    val selected = s == current
                    Box(
                        Modifier
                            .fillMaxHeight()
                            .background(if (selected) fg.copy(alpha = 0.18f) else Color.Transparent)
                            .clickable { select(s) }
                            .padding(horizontal = 12.dp)
                            .alpha(if (s.isRunning) 1f else 0.5f),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            SessionManager.title(s),
                            color = fg,
                            fontSize = 13.sp,
                            fontFamily = FontFamily.Monospace,
                            fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.widthIn(max = 180.dp),
                        )
                    }
                }
            }
            BarButton("+", fg, stringResource(R.string.action_new_session)) { newSession() }
            Box {
                BarButton("⋮", fg, stringResource(R.string.action_menu)) { menu = true }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    @Composable
                    fun Item(label: Int, enabled: Boolean = true, action: () -> Unit) = DropdownMenuItem(
                        text = { Text(stringResource(label)) },
                        enabled = enabled,
                        onClick = {
                            menu = false
                            action()
                        },
                    )
                    Item(R.string.action_new_session) { newSession() }
                    Item(R.string.action_new_root_session) { newSession("root") }
                    // Always there (disabled without a session): the session can appear
                    // while the menu is open, and inserting the item then moved every
                    // item below it under the user's finger.
                    Item(R.string.action_close_session, enabled = current != null) { current?.let { close(it) } }
                    HorizontalDivider()
                    for (t in TerminalTheme.entries) {
                        DropdownMenuItem(
                            text = { Text((if (t == terminalTheme) "● " else "○ ") + stringResource(t.label)) },
                            onClick = {
                                menu = false
                                applyTheme(t)
                            },
                        )
                    }
                    HorizontalDivider()
                    Item(if (wakeLock) R.string.action_release_wake_lock else R.string.action_acquire_wake_lock) {
                        toggleWakeLock()
                    }
                    Item(R.string.action_settings) {
                        startActivity(Intent(this@TerminalActivity, SettingsActivity::class.java))
                    }
                    Item(R.string.kernel_title) {
                        startActivity(Intent(this@TerminalActivity, KernelActivity::class.java))
                    }
                    Item(R.string.hw_title) {
                        startActivity(Intent(this@TerminalActivity, HardwareActivity::class.java))
                    }
                    Item(R.string.about_title) {
                        startActivity(Intent(this@TerminalActivity, AboutActivity::class.java))
                    }
                    Item(R.string.action_stop_all) { confirmStop = true }
                }
            }
        }
        if (confirmStop) {
            AlertDialog(
                onDismissRequest = { confirmStop = false },
                title = { Text(stringResource(R.string.stop_all_title)) },
                text = { Text(stringResource(R.string.stop_all_body)) },
                confirmButton = {
                    TextButton(onClick = {
                        confirmStop = false
                        stopAll()
                    }) { Text(stringResource(R.string.action_stop_all)) }
                },
                dismissButton = {
                    TextButton(onClick = { confirmStop = false }) { Text(stringResource(android.R.string.cancel)) }
                },
            )
        }
    }

    @Composable
    private fun BarButton(label: String, fg: Color, description: String, onClick: () -> Unit) {
        Box(
            Modifier
                .fillMaxHeight()
                .clickable(onClickLabel = description, onClick = onClick)
                .padding(horizontal = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(label, color = fg, fontSize = 20.sp)
        }
    }

    private fun onExtraKey(key: ExtraKey) {
        val session = terminalView.currentSession ?: return
        if (!session.isRunning) return
        when (key) {
            ExtraKey.Ctrl -> ctrlDown = !ctrlDown

            ExtraKey.Alt -> altDown = !altDown

            // inputCodePoint() reads (and so clears) the sticky keys itself.
            is ExtraKey.Symbol -> terminalView.inputCodePoint(key.codePoint, false, false)

            is ExtraKey.Code -> {
                var mod = 0
                if (ctrlDown) mod = mod or KeyHandler.KEYMOD_CTRL
                if (altDown) mod = mod or KeyHandler.KEYMOD_ALT
                ctrlDown = false
                altDown = false
                terminalView.handleKeyCode(key.keyCode, mod)
            }
        }
    }

    /**
     * Hardware keyboard shortcuts. An OnKeyListener runs before TerminalView's
     * onKeyDown(), which drops the text selection before asking its client.
     */
    private fun onShortcut(event: KeyEvent): Boolean {
        // A hardware keyboard sends Ctrl and Shift as key events of their own, and
        // TerminalView.onKeyDown ends the text selection on ANY key: Ctrl+Shift+C
        // then found nothing to copy. Keep modifier-only events away from it while
        // selecting (C still carries them in its meta state).
        if (terminalView.isSelectingText && KeyEvent.isModifierKey(event.keyCode)) return true
        if (event.action == KeyEvent.ACTION_DOWN && event.isCtrlPressed && event.isShiftPressed) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_C -> {
                    terminalView.selectedText?.let { copy(it) }
                    terminalView.stopTextSelectionMode()
                    return true
                }

                KeyEvent.KEYCODE_V -> {
                    terminalView.currentSession?.let { paste(it) }
                    return true
                }

                KeyEvent.KEYCODE_T -> {
                    newSession()
                    return true
                }
            }
        }
        return false
    }

    private fun copy(text: String) {
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("UbuRoot", text))
    }

    private fun paste(session: TerminalSession) {
        val clip = getSystemService(ClipboardManager::class.java).primaryClip ?: return
        val text = clip.getItemAt(0)?.coerceToText(this)?.toString() ?: return
        session.emulator?.paste(text)
    }

    private fun showKeyboard() {
        terminalView.requestFocus()
        getSystemService(InputMethodManager::class.java).showSoftInput(terminalView, 0)
    }

    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33 || prefs.askedNotificationPermission) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        prefs.askedNotificationPermission = true
        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    /** Opens a tapped link; returns false when the tap was not on one. */
    private fun openLink(e: MotionEvent): Boolean {
        val emulator = terminalView.currentSession?.emulator ?: return false
        // Full-screen programs that track the mouse get the tap instead.
        if (emulator.isMouseTrackingActive) return false
        val url = runCatching {
            val (col, row) = terminalView.getColumnAndRow(e, true)
            Links.find(emulator.screen.getWordAtLocation(col, row))
        }.getOrNull() ?: return false
        try {
            startActivity(Intent(Intent.ACTION_VIEW, url.toUri()).addCategory(Intent.CATEGORY_BROWSABLE))
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(this, getString(R.string.no_app_for_link, url), Toast.LENGTH_SHORT).show()
        }
        return true
    }

    private fun px(sp: Float) =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, resources.displayMetrics).roundToInt()

    private val sessionClient = object : TerminalSessionClient {
        override fun onTextChanged(changedSession: TerminalSession) {
            if (changedSession == terminalView.currentSession) terminalView.onScreenUpdated()
        }

        override fun onTitleChanged(changedSession: TerminalSession) = Unit

        override fun onSessionFinished(finishedSession: TerminalSession) {
            if (finishedSession == terminalView.currentSession) terminalView.onScreenUpdated()
        }

        override fun onCopyTextToClipboard(session: TerminalSession, text: String) = copy(text)

        override fun onPasteTextFromClipboard(session: TerminalSession) = paste(session)

        override fun onBell(session: TerminalSession) = Unit

        override fun onColorsChanged(session: TerminalSession) = terminalView.invalidate()

        override fun onTerminalCursorStateChange(state: Boolean) = Unit

        override fun getTerminalCursorStyle(): Int = com.termux.terminal.TerminalEmulator.DEFAULT_TERMINAL_CURSOR_STYLE

        override fun logError(tag: String, message: String) = Unit

        override fun logWarn(tag: String, message: String) = Unit

        override fun logInfo(tag: String, message: String) = Unit

        override fun logDebug(tag: String, message: String) = Unit

        override fun logVerbose(tag: String, message: String) = Unit

        override fun logStackTraceWithMessage(tag: String, message: String, e: Exception) = Unit

        override fun logStackTrace(tag: String, e: Exception) = Unit
    }

    private val viewClient = object : TerminalViewClient {
        override fun onScale(scale: Float): Float {
            if (scale in 0.9f..1.1f) return scale
            textSizeSp = (textSizeSp + if (scale > 1f) 1f else -1f).coerceIn(MIN_TEXT_SP, MAX_TEXT_SP)
            terminalView.setTextSize(px(textSizeSp))
            prefs.textSizeSp = textSizeSp
            return 1f
        }

        override fun onSingleTapUp(e: MotionEvent) {
            if (!openLink(e)) showKeyboard()
        }

        override fun shouldBackButtonBeMappedToEscape() = false

        override fun shouldEnforceCharBasedInput() = false

        override fun shouldUseCtrlSpaceWorkaround() = false

        override fun isTerminalViewSelected() = true

        override fun copyModeChanged(copyMode: Boolean) = Unit

        override fun onKeyDown(keyCode: Int, e: KeyEvent, session: TerminalSession): Boolean {
            if (!session.isRunning) {
                if (keyCode == KeyEvent.KEYCODE_ENTER) {
                    // Last tab: back through the preflight instead of respawning
                    // enter.sh blindly (the rootfs may have been reset meanwhile).
                    if (SessionManager.sessions.size == 1) backToPreflight = true
                    close(session)
                }
                return true
            }
            return false
        }

        override fun onKeyUp(keyCode: Int, e: KeyEvent) = false

        override fun onLongPress(event: MotionEvent) = false

        // Sticky extra keys: reading one consumes it, as in Termux.
        override fun readControlKey(): Boolean = ctrlDown.also { if (it) ctrlDown = false }

        override fun readAltKey(): Boolean = altDown.also { if (it) altDown = false }

        override fun readShiftKey() = false

        override fun readFnKey() = false

        override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession) = false

        override fun onEmulatorSet() = Unit

        override fun logError(tag: String, message: String) {
            Log.e(tag, message)
        }

        override fun logWarn(tag: String, message: String) {
            Log.w(tag, message)
        }

        override fun logInfo(tag: String, message: String) = Unit

        override fun logDebug(tag: String, message: String) = Unit

        override fun logVerbose(tag: String, message: String) = Unit

        override fun logStackTraceWithMessage(tag: String, message: String, e: Exception) {
            Log.e(tag, message, e)
        }

        override fun logStackTrace(tag: String, e: Exception) {
            Log.e(tag, "", e)
        }
    }

    companion object {
        private const val EXTRA_NEW_SESSION = "new_session"
        private const val EXTRA_USER = "user"
        private const val EXTRA_CWD = "cwd"
        private const val EXTRA_COMMAND = "command"
        private const val MIN_TEXT_SP = 6f
        private const val MAX_TEXT_SP = 40f

        /**
         * [cwd]: start directory of the new session (a path inside Ubuntu); [command]: run it
         * instead of a login shell (needs [newSession]).
         */
        fun intent(
            context: Context,
            newSession: Boolean,
            user: String? = null,
            cwd: String? = null,
            command: String? = null,
        ): Intent = Intent(context, TerminalActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(EXTRA_NEW_SESSION, newSession)
            .apply {
                if (user != null) putExtra(EXTRA_USER, user)
                if (cwd != null) putExtra(EXTRA_CWD, cwd)
                if (command != null) putExtra(EXTRA_COMMAND, command)
            }
    }
}
