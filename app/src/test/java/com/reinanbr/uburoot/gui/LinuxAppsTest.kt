// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.gui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LinuxAppsTest {
    @Test
    fun parsesApps() {
        val apps = LinuxApps.parseApps(
            listOf(
                "org.wireshark.Wireshark|Wireshark|org.wireshark.Wireshark",
                "gimp|GNU Image Manipulation Program|",
                "bad",
                "|x|y",
            ),
        )
        assertEquals(listOf("org.wireshark.Wireshark", "gimp"), apps.map { it.id })
        assertEquals("", apps[1].icon)
    }

    @Test
    fun parsesIconsAndStatus() {
        assertEquals(mapOf("a" to "iVBOR"), LinuxApps.parseIcons(listOf("a|iVBOR", "b|", "junk")))
        val s = X11Status.parse(listOf("x11=running", "wm=matchbox-window-manager"))
        assertTrue(s.installed)
        assertEquals("matchbox-window-manager", s.wm)
        assertFalse(X11Status.parse(listOf("x11=missing", "wm=missing")).installed)
        assertFalse(X11Status.parse(emptyList()).installed)
        assertEquals("root", LinuxApps.userOf(""))
        assertEquals("ana", LinuxApps.userOf("ana"))
    }
}
