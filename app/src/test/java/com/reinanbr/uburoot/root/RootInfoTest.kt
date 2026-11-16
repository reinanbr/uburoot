// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.root

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RootInfoTest {
    private val sample = """
        uid=0
        impl=magisk
        version=31.1:MAGISKSU
        mount_master_flag=--mount-master
        busybox=/data/adb/magisk/busybox
        busybox_kind=busybox
        arch=aarch64
        mnt_ns=mnt:[4026531840]
        init_mnt_ns=mnt:[4026531840]
        free_kb=52428800
        rootfs=installed
        setup=pending
    """.trimIndent().lines()

    @Test
    fun parsesRootinfoOutput() {
        val info = RootInfo.parse(sample)
        assertEquals("magisk", info.impl)
        assertTrue(info.isArm64)
        assertTrue(info.globalNamespace)
        assertTrue(info.rootfsInstalled)
        assertFalse(info.setupDone)
        assertEquals(52428800L * 1024, info.freeBytes)
    }

    @Test
    fun privateNamespaceIsDetected() {
        val info = RootInfo.parse(sample.map { if (it.startsWith("mnt_ns=")) "mnt_ns=mnt:[4026532999]" else it })
        assertFalse(info.globalNamespace)
    }

    @Test
    fun missingNamespaceIsNotGlobal() {
        assertFalse(RootInfo.parse(listOf("[uburoot] WARNING: something", "impl=unknown")).globalNamespace)
    }
}
