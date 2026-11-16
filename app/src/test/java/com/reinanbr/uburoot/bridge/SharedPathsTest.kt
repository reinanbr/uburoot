// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SharedPathsTest {
    @Test
    fun documentIds() {
        assertEquals("/sdcard/Download", SharedPaths.fromExternalStorageDocId("primary:Download/a.pdf"))
        assertEquals("/sdcard", SharedPaths.fromExternalStorageDocId("primary:a.pdf"))
        assertEquals("/sdcard/Documents/x", SharedPaths.fromExternalStorageDocId("home:x/b.txt"))
        assertNull(SharedPaths.fromExternalStorageDocId("1234-ABCD:DCIM/c.jpg")) // SD card: not in Ubuntu
        assertNull(SharedPaths.fromExternalStorageDocId("primary:../../data/x"))
        assertNull(SharedPaths.fromExternalStorageDocId("nocolon"))
        assertEquals("/sdcard/Download", SharedPaths.fromDownloadsDocId("raw:/storage/emulated/0/Download/f.zip"))
        assertNull(SharedPaths.fromDownloadsDocId("msf:1234"))
    }

    @Test
    fun androidPaths() {
        assertEquals("/sdcard/DCIM/Camera", SharedPaths.fromAndroidPath("/storage/emulated/0/DCIM/Camera/i.jpg"))
        assertEquals("/sdcard", SharedPaths.fromAndroidPath("/sdcard/i.jpg"))
        assertEquals("/sdcard/Music", SharedPaths.fromAndroidPath("/data/media/0/Music/s.mp3"))
        assertNull(SharedPaths.fromAndroidPath("/storage/emulated/10/x/y"))
        assertNull(SharedPaths.fromAndroidPath("/data/data/com.app/files/x"))
        assertNull(SharedPaths.fromAndroidPath("/storage/emulated/0/a/../../../data/x"))
    }

    @Test
    fun mediaStore() {
        assertEquals("/sdcard/Download/Sub", SharedPaths.fromMediaStore("external_primary", "Download/Sub/"))
        assertEquals("/sdcard/Pictures", SharedPaths.fromMediaStore(null, "Pictures/"))
        assertNull(SharedPaths.fromMediaStore("1234-abcd", "DCIM/"))
        assertNull(SharedPaths.fromMediaStore("external_primary", null))
        assertNull(SharedPaths.fromMediaStore("external_primary", "../x/"))
        assertNull(SharedPaths.fromMediaStore("external_primary", "a\nb/"))
    }

    @Test
    fun names() {
        assertEquals("a.pdf", SharedPaths.safeName("a.pdf"))
        assertEquals("b.txt", SharedPaths.safeName("../../b.txt"))
        assertEquals("shared-file", SharedPaths.safeName(".."))
        assertEquals("shared-file", SharedPaths.safeName(null))
        assertEquals("xy", SharedPaths.safeName("x\ny"))
    }
}
