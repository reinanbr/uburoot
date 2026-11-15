package com.reinanbr.uburoot.terminal

import android.content.Context
import androidx.core.content.edit

/** App-side terminal preferences (not part of uburoot.conf: the scripts never need them). */
class TerminalPrefs(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("terminal", Context.MODE_PRIVATE)

    var theme: TerminalTheme
        get() = prefs.getString(KEY_THEME, null)
            ?.let { name -> TerminalTheme.entries.firstOrNull { it.name == name } }
            ?: TerminalTheme.DARK
        set(value) = prefs.edit { putString(KEY_THEME, value.name) }

    /** Font size in sp; changed by pinch-to-zoom. */
    var textSizeSp: Float
        get() = prefs.getFloat(KEY_TEXT_SIZE, DEFAULT_TEXT_SIZE_SP)
        set(value) = prefs.edit { putFloat(KEY_TEXT_SIZE, value) }

    var askedNotificationPermission: Boolean
        get() = prefs.getBoolean(KEY_ASKED_NOTIF, false)
        set(value) = prefs.edit { putBoolean(KEY_ASKED_NOTIF, value) }

    companion object {
        const val DEFAULT_TEXT_SIZE_SP = 14f
        private const val KEY_THEME = "theme"
        private const val KEY_TEXT_SIZE = "text_size_sp"
        private const val KEY_ASKED_NOTIF = "asked_notification_permission"
    }
}
