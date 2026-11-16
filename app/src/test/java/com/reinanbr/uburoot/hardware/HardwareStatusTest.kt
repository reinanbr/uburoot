// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.hardware

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HardwareStatusTest {
    private val sample = listOf(
        "access=on",
        "class=gpu|direct|available|5|aid_graphics|",
        "class=serial|direct|available|1|dialout|ana,bob",
        "class=wifi|takeover|taken|0||",
        "class=bluetooth|none|unsupported|1||",
        "cpu=policy0|0 1 2 3|schedutil|576000|1766400|1766400",
        "battery=85|Charging|312",
        "wakelock=on",
        "rules=running",
        "changes=3",
    )

    @Test
    fun parsesStatus() {
        val s = HardwareStatus.parse(sample)
        assertTrue(s.access)
        assertEquals(4, s.classes.size)
        assertEquals(listOf("ana", "bob"), s.classes[1].users)
        assertEquals("dialout", s.classes[1].group)
        assertTrue(s.classes[0].users.isEmpty())
        assertTrue(s.wifiTaken)
        assertEquals("unsupported", s.classes[3].state)
        assertEquals(CpuPolicy("policy0", "0 1 2 3", "schedutil", 576000, 1766400, 1766400), s.cpus.single())
        assertEquals(Triple(85, "Charging", 312), s.battery)
        assertTrue(s.wakeLock)
        assertEquals(3, s.changes)
    }

    @Test
    fun brokenOutputIsOff() {
        val s = HardwareStatus.parse(listOf("uburoot-hw: must run as root", "class=short|x"))
        assertFalse(s.access)
        assertTrue(s.classes.isEmpty())
        assertNull(s.battery)
        assertFalse(s.wifiTaken)
    }
}
