package com.reinanbr.uburoot.install

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ReleaseDiscoveryTest {
    // Shapes copied from the real cdimage.ubuntu.com listings (2026-11).
    private val index = """
        <a href="?C=N;O=D">Name</a> <a href="/ubuntu-base/">Parent</a>
        <a href="22.04/">22.04/</a> <a href="22.04.5/">22.04.5/</a>
        <a href="24.04/">24.04/</a> <a href="24.04.3/">24.04.3/</a>
        <a href="25.04/">25.04/</a> <a href="25.10/">25.10/</a>
        <a href="26.04/">26.04/</a> <a href="26.04.1/">26.04.1/</a>
        <a href="27.04/">27.04/</a> <a href="resolute/">resolute/</a>
    """.trimIndent()

    private val listing = """
        <a href="SHA256SUMS">SHA256SUMS</a> <a href="SHA256SUMS.gpg">SHA256SUMS.gpg</a>
        <a href="ubuntu-base-26.04-base-amd64.tar.gz">x</a>
        <a href="ubuntu-base-26.04-base-arm64.tar.gz">x</a>
        <a href="ubuntu-base-26.04-base-arm64.tar.gz.zsync">x</a>
        <a href="ubuntu-base-26.04.1-base-amd64.tar.gz">x</a>
        <a href="ubuntu-base-26.04.1-base-arm64.tar.gz">x</a>
        <a href="ubuntu-base-26.04.1-base-arm64.tar.gz.zsync">x</a>
        <a href="ubuntu-base-26.04.1-base-armhf.tar.gz">x</a>
    """.trimIndent()

    private val sums = """
        b2b46a37324ea1954e93f293fe6d7c2241daf2fc298c4022e6e4caceeed74cab *ubuntu-base-26.04-base-arm64.tar.gz
        a496a960472ce474a59590b8987d3a1135d3cbef1991f3b1abe8cacfea8bf85a *ubuntu-base-26.04.1-base-amd64.tar.gz
        5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd *ubuntu-base-26.04.1-base-arm64.tar.gz
    """.trimIndent()

    @Test
    fun ltsSeriesAreEvenYearAprilReleasesNewestFirst() {
        assertEquals(listOf(26, 24, 22), ReleaseDiscovery.ltsSeries(index))
    }

    @Test
    fun picksNewestPointReleaseForArm64() {
        assertEquals(
            "ubuntu-base-26.04.1-base-arm64.tar.gz" to "26.04.1",
            ReleaseDiscovery.arm64Tarball(listing, 26),
        )
        assertNull(ReleaseDiscovery.arm64Tarball(listing, 24))
    }

    @Test
    fun readsChecksumForExactFile() {
        assertEquals(
            "5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd",
            ReleaseDiscovery.sha256For(sums, "ubuntu-base-26.04.1-base-arm64.tar.gz"),
        )
        assertNull(ReleaseDiscovery.sha256For(sums, "ubuntu-base-26.04.1-base-arm64.tar"))
    }

    @Test
    fun discoverFallsBackWhenNewestSeriesHasNoArm64Build() = runBlocking {
        val base = ReleaseDiscovery.BASE_URL
        val pages = mapOf(
            base to """<a href="26.04/">a</a><a href="28.04/">b</a>""",
            "${base}28.04/release/" to """<a href="ubuntu-base-28.04-base-amd64.tar.gz">a</a>""",
            "${base}26.04/release/" to listing,
            "${base}26.04/release/SHA256SUMS" to sums,
        )
        val r = ReleaseDiscovery.discover { pages[it] ?: throw HttpException(404, it) }
        assertEquals("26.04.1", r.version)
        assertEquals("${base}26.04/release/ubuntu-base-26.04.1-base-arm64.tar.gz", r.url)
        assertEquals("5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd", r.sha256)
    }
}
