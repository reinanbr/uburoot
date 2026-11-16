// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.terminal

/** Finds a web link in the word the user tapped in the terminal. */
object Links {
    private val URL = Regex("""(?:https?|ftp)://[^\s<>"'`]+""", RegexOption.IGNORE_CASE)

    // Closing punctuation that usually belongs to the sentence, not the URL.
    private const val TRAILING = ".,;:!?)]}>'\""

    fun find(word: String?): String? {
        val m = URL.find(word ?: return null) ?: return null
        var url = m.value
        while (url.isNotEmpty() && url.last() in TRAILING) {
            // Keep a ")" that closes a "(" inside the URL (Wikipedia-style links).
            if (url.last() == ')' && url.count { it == '(' } >= url.count { it == ')' }) break
            url = url.dropLast(1)
        }
        return url.takeIf { it.substringAfter("://").isNotEmpty() }
    }
}
