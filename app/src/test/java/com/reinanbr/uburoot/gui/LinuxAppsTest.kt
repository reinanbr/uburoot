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
        // Older x11.sh (no switch=): the window tools count as missing.
        assertTrue(s.toolsMissing)
    }

    @Test
    fun parsesStatusExtras() {
        val s = X11Status.parse(
            listOf(
                "x11=running",
                "wm=xfce4-session",
                "switch=yes",
                "desktop=running",
                "audio=ready",
                "firefox=installed",
            ),
        )
        assertTrue(s.running)
        assertTrue(s.switch)
        assertFalse(s.toolsMissing)
        assertEquals("running", s.desktop)
        assertEquals("installed", s.firefox)
        assertTrue(X11Status.parse(listOf("x11=running", "wm=none", "switch=no")).toolsMissing)
    }

    @Test
    fun parsesWindows() {
        val w = LinuxApps.parseWindows(
            listOf(
                "0x00800006|org.wireshark.Wireshark|The Wireshark Network Analyzer",
                "0x00c00003||A title | with a bar",
                "nothex|x|y",
                "0x12|only two",
            ),
        )
        assertEquals(2, w.size)
        assertEquals("org.wireshark.Wireshark", w[0].app)
        assertEquals("", w[1].app)
        assertEquals("A title | with a bar", w[1].title)
    }
}

class GpuTest {
    @Test
    fun parsesStatus() {
        val g = GpuStatus.parse(
            listOf("gpu=adreno", "model=Adreno630v2", "driver=installed", "mesa=26.0.8-1ubuntu0.3", "zink=on"),
        )
        assertTrue(g.adreno && g.installed && g.zink)
        assertEquals("Adreno630v2", g.model)
        val n = GpuStatus.parse(listOf("gpu=none", "driver=missing", "zink=off"))
        assertFalse(n.adreno || n.installed || n.zink)
    }

    @Test
    fun findsTheSum() {
        val a = "a".repeat(64)
        val b = "B".repeat(64)
        val sums = "$a  uburoot.apk\n$b *turnip-kgsl-arm64.tar.gz\nxyz  other\n"
        assertEquals("b".repeat(64), Gpu.sumFor(sums, Gpu.ASSET))
        assertEquals(null, Gpu.sumFor(sums, "missing.tar.gz"))
        assertEquals(null, Gpu.sumFor("short  ${Gpu.ASSET}", Gpu.ASSET))
    }
}
