// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.kernel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KernelStatusTest {
    private val sample = listOf(
        "mode=android",
        "access=on",
        "selinux=permissive",
        "kernel.kptr_restrict=1",
        "kernel.dmesg_restrict=0",
        "kernel.perf_event_paranoid=3",
        "devmode=on",
        "modules_loaded=2",
        "change=sysctl kernel.kptr_restrict 4",
        "change=selinux - 1",
        "change=module fake -",
        "changes=3",
    )

    @Test
    fun parsesStatus() {
        val s = KernelStatus.parse(sample)
        assertTrue(s.access)
        assertTrue(s.permissive)
        assertTrue(s.devMode)
        assertEquals(2, s.modulesLoaded)
        assertEquals("kernel.kptr_restrict" to "1", s.sysctls.first())
        assertEquals(3, s.sysctls.size)
        assertEquals(KernelChange("sysctl", "kernel.kptr_restrict", "4"), s.changes[0])
        assertEquals(KernelChange("module", "fake", "-"), s.changes[2])
    }

    @Test
    fun valuesWithSpacesStayWhole() {
        val s = KernelStatus.parse(listOf("change=sysctl net.ipv4.ping_group_range 0 2147483647"))
        assertEquals("0 2147483647", s.changes.single().original)
    }

    @Test
    fun emptyOrBrokenOutputIsOff() {
        val s = KernelStatus.parse(listOf("uburoot-kernel: must run as root"))
        assertFalse(s.access)
        assertEquals("absent", s.selinux)
        assertTrue(s.changes.isEmpty())
    }

    @Test
    fun parsesModuleList() {
        val m = KernelStatus.parseModules(listOf("* fake", "  wlan", "", "garbage"))
        assertEquals(listOf("fake" to true, "wlan" to false), m)
    }
}
