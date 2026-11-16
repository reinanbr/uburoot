// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.terminal

import androidx.annotation.StringRes
import com.reinanbr.uburoot.R
import com.termux.terminal.TerminalColors
import com.termux.terminal.TerminalSession
import java.util.Properties

/**
 * Terminal color schemes, in Termux's `colors.properties` keys. They go into
 * the global [TerminalColors.COLOR_SCHEME], which every emulator copies on
 * creation and on `mColors.reset()`.
 */
enum class TerminalTheme(
    @StringRes val label: Int,
    val background: Int,
    val foreground: Int,
    colors: Map<String, String>,
) {
    // Termux's built-in defaults: updateWith() starts from reset(), so no overrides.
    DARK(R.string.theme_dark, 0xFF000000.toInt(), 0xFFFFFFFF.toInt(), emptyMap()),

    // Tango palette on white.
    LIGHT(
        R.string.theme_light,
        0xFFFFFFFF.toInt(),
        0xFF2E3436.toInt(),
        mapOf(
            "foreground" to "#2e3436", "background" to "#ffffff", "cursor" to "#2e3436",
            "color0" to "#2e3436", "color1" to "#cc0000", "color2" to "#4e9a06", "color3" to "#c4a000",
            "color4" to "#3465a4", "color5" to "#75507b", "color6" to "#06989a", "color7" to "#d3d7cf",
            "color8" to "#555753", "color9" to "#ef2929", "color10" to "#4e9a06", "color11" to "#c4a000",
            "color12" to "#3465a4", "color13" to "#75507b", "color14" to "#06989a", "color15" to "#eeeeec",
        ),
    ),

    // Ethan Schoonover's Solarized (https://ethanschoonover.com/solarized/), terminal mapping.
    SOLARIZED_DARK(
        R.string.theme_solarized_dark,
        0xFF002B36.toInt(),
        0xFF839496.toInt(),
        SOLARIZED + mapOf("foreground" to "#839496", "background" to "#002b36", "cursor" to "#93a1a1"),
    ),
    SOLARIZED_LIGHT(
        R.string.theme_solarized_light,
        0xFFFDF6E3.toInt(),
        0xFF657B83.toInt(),
        SOLARIZED + mapOf("foreground" to "#657b83", "background" to "#fdf6e3", "cursor" to "#586e75"),
    ),
    ;

    val isLight get() = this == LIGHT || this == SOLARIZED_LIGHT

    private val properties = Properties().apply { putAll(colors) }

    /** Make this the scheme of new sessions and repaint [sessions]. */
    fun apply(sessions: List<TerminalSession>) {
        TerminalColors.COLOR_SCHEME.updateWith(properties)
        for (s in sessions) s.emulator?.mColors?.reset()
    }
}

private val SOLARIZED = mapOf(
    "color0" to "#073642", "color1" to "#dc322f", "color2" to "#859900", "color3" to "#b58900",
    "color4" to "#268bd2", "color5" to "#d33682", "color6" to "#2aa198", "color7" to "#eee8d5",
    "color8" to "#002b36", "color9" to "#cb4b16", "color10" to "#586e75", "color11" to "#657b83",
    "color12" to "#839496", "color13" to "#6c71c4", "color14" to "#93a1a1", "color15" to "#fdf6e3",
)
