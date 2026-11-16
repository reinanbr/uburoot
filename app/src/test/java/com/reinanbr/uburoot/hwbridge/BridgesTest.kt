// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.hwbridge

import org.junit.Assert.assertArrayEquals
import org.junit.Test

class BridgesTest {
    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test
    fun jpegPaddingIsCut() {
        val jpeg = bytes(0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 0xFF, 0xD9)
        assertArrayEquals(jpeg, Bridges.jpegOnly(jpeg))
        assertArrayEquals(jpeg, Bridges.jpegOnly(jpeg + ByteArray(1000)))
        // An EXIF thumbnail's own EOI inside the image is not the end.
        val withThumb = bytes(0xFF, 0xD8, 0xFF, 0xD8, 0xFF, 0xD9, 7, 0xFF, 0xD9)
        assertArrayEquals(withThumb, Bridges.jpegOnly(withThumb + ByteArray(8)))
    }
}
