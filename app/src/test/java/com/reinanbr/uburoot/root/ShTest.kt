package com.reinanbr.uburoot.root

import org.junit.Assert.assertEquals
import org.junit.Test

class ShTest {
    /** Round-trip through a real POSIX shell: what we quote is what sh sees. */
    private fun shEcho(word: String): String {
        val p = ProcessBuilder("sh", "-c", "printf '%s' ${Sh.quote(word)}").start()
        val out = p.inputStream.readBytes().decodeToString()
        p.waitFor()
        return out
    }

    @Test
    fun quotesHostileStrings() {
        val hostile = listOf(
            "plain", "it's", "'", "''", "\$(id)", "`id`", "a b\tc", "x\ny", "\\", "-n", "; rm -rf /", "\"\$HOME\"",
        )
        for (s in hostile) {
            assertEquals(s, shEcho(s))
        }
    }

    @Test
    fun quoteFormat() {
        assertEquals("'it'\\''s'", Sh.quote("it's"))
    }
}
