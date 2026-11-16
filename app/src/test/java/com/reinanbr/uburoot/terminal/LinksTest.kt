// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LinksTest {
    @Test
    fun findsLinksInTappedWords() {
        assertEquals("https://ubuntu.com/download", Links.find("https://ubuntu.com/download"))
        assertEquals("http://x.org/a?b=1&c=2", Links.find("(see:http://x.org/a?b=1&c=2)."))
        assertEquals(
            "https://en.wikipedia.org/wiki/Unix_(disambiguation)",
            Links.find("https://en.wikipedia.org/wiki/Unix_(disambiguation)"),
        )
        assertEquals("https://example.com", Links.find("<https://example.com>,"))
        assertEquals("ftp://ftp.example.org/f", Links.find("ftp://ftp.example.org/f"))
    }

    @Test
    fun ignoresEverythingElse() {
        assertNull(Links.find(null))
        assertNull(Links.find(""))
        assertNull(Links.find("/etc/hosts"))
        assertNull(Links.find("https://"))
        assertNull(Links.find("javascript:alert(1)"))
        assertNull(Links.find("file:///etc/passwd"))
    }
}
