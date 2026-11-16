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

    @Test
    fun fullRootGate() {
        // Output of the S9 (Magisk 31.1, kernel 4.9): no NoNewPrivs line in /proc, reported as 0.
        val full = sample + listOf(
            "cap_last_cap=37",
            "cap_eff=0000003fffffffff",
            "cap_bnd=0000003fffffffff",
            "no_new_privs=0",
            "seccomp=0",
            "full_root=yes",
            "selinux=u:r:magisk:s0",
        )
        assertTrue(RootInfo.parse(full).fullRoot)
        val restricted = RootInfo.parse(full.map { if (it.startsWith("full_root=")) "full_root=no" else it })
        assertFalse(restricted.fullRoot)
        assertTrue(restricted.rootDetail.contains("selinux=u:r:magisk:s0"))
        // Scripts older than the gate don't report it: not a reason to refuse.
        assertTrue(RootInfo.parse(sample).fullRoot)
    }

    @Test
    fun migrationNeededOnlyForAnOlderSetUpRootfs() {
        fun info(vararg extra: String, setup: String = "done") =
            RootInfo.parse(sample.map { if (it.startsWith("setup=")) "setup=$setup" else it } + extra)
        assertTrue(info("schema=0", "schema_current=1").needsMigration)
        assertTrue(info("schema_current=1").needsMigration) // no /etc/uburoot-release yet
        assertFalse(info("schema=1", "schema_current=1").needsMigration)
        assertFalse(info("schema=2", "schema_current=1").needsMigration)
        assertFalse(info("schema=0", "schema_current=1", setup = "pending").needsMigration)
        assertEquals(1, info("schema=1", "schema_current=1").schema)
    }
}
