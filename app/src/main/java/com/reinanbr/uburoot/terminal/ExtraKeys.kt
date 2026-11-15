package com.reinanbr.uburoot.terminal

import android.view.KeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** One button of the extra keys rows. */
sealed class ExtraKey(val label: String, val repeats: Boolean = true) {
    /** Sent through KeyHandler, so cursor/keypad application modes are honored. */
    class Code(label: String, val keyCode: Int) : ExtraKey(label)

    /** A character, typed as if it came from the keyboard (sticky CTRL/ALT apply). */
    class Symbol(label: String) : ExtraKey(label) {
        val codePoint = label.codePointAt(0)
    }

    data object Ctrl : ExtraKey("CTRL", repeats = false)
    data object Alt : ExtraKey("ALT", repeats = false)

    companion object {
        val ROWS: List<List<ExtraKey>> = listOf(
            listOf(
                Code("ESC", KeyEvent.KEYCODE_ESCAPE),
                Symbol("/"),
                Symbol("-"),
                Code("HOME", KeyEvent.KEYCODE_MOVE_HOME),
                Code("↑", KeyEvent.KEYCODE_DPAD_UP),
                Code("END", KeyEvent.KEYCODE_MOVE_END),
                Code("PGUP", KeyEvent.KEYCODE_PAGE_UP),
                Symbol("|"),
            ),
            listOf(
                Code("TAB", KeyEvent.KEYCODE_TAB),
                Ctrl,
                Alt,
                Code("←", KeyEvent.KEYCODE_DPAD_LEFT),
                Code("↓", KeyEvent.KEYCODE_DPAD_DOWN),
                Code("→", KeyEvent.KEYCODE_DPAD_RIGHT),
                Code("PGDN", KeyEvent.KEYCODE_PAGE_DOWN),
                Symbol("~"),
            ),
        )
    }
}

/**
 * The two extra keys rows. Pointer input instead of `clickable`, so a tap never
 * moves focus (and the soft keyboard) away from the terminal. Holding a key repeats it.
 */
@Composable
fun ExtraKeys(foreground: Color, background: Color, ctrlDown: Boolean, altDown: Boolean, onKey: (ExtraKey) -> Unit) {
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxWidth().background(background)) {
        for (row in ExtraKey.ROWS) {
            Row(Modifier.fillMaxWidth().height(38.dp)) {
                for (key in row) {
                    val active = (key == ExtraKey.Ctrl && ctrlDown) || (key == ExtraKey.Alt && altDown)
                    Box(
                        Modifier
                            .weight(1f)
                            .height(38.dp)
                            .background(if (active) foreground.copy(alpha = 0.35f) else Color.Transparent)
                            .pointerInput(key) {
                                detectTapGestures(onPress = {
                                    val job = scope.launch {
                                        onKey(key)
                                        if (key.repeats) {
                                            delay(REPEAT_DELAY_MS)
                                            while (isActive) {
                                                onKey(key)
                                                delay(REPEAT_INTERVAL_MS)
                                            }
                                        }
                                    }
                                    tryAwaitRelease()
                                    job.cancel()
                                })
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(key.label, color = foreground, fontSize = 14.sp, fontFamily = FontFamily.Monospace)
                    }
                }
            }
        }
    }
}

private const val REPEAT_DELAY_MS = 400L
private const val REPEAT_INTERVAL_MS = 50L
