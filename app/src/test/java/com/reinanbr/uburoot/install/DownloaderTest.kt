package com.reinanbr.uburoot.install

import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.security.MessageDigest
import java.util.Collections
import kotlin.random.Random

class DownloaderTest {
    private val body = Random(42).nextBytes(300_000)
    private val sha = MessageDigest.getInstance("SHA-256").digest(body).joinToString("") { "%02x".format(it) }
    private val ranges: MutableList<String?> = Collections.synchronizedList(mutableListOf())
    private lateinit var server: HttpServer
    private lateinit var dir: File
    private var honorRange = true

    @Before
    fun setUp() {
        dir = kotlin.io.path.createTempDirectory("uburoot-dl").toFile()
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/f") { ex ->
            val range = ex.requestHeaders.getFirst("Range")
            ranges += range
            val from = range?.removePrefix("bytes=")?.removeSuffix("-")?.toInt()
            if (from != null && honorRange) {
                ex.responseHeaders.add("Content-Range", "bytes $from-${body.size - 1}/${body.size}")
                ex.sendResponseHeaders(206, (body.size - from).toLong())
                ex.responseBody.use { it.write(body, from, body.size - from) }
            } else {
                ex.sendResponseHeaders(200, body.size.toLong())
                ex.responseBody.use { it.write(body) }
            }
        }
        server.start()
    }

    @After
    fun tearDown() {
        server.stop(0)
        dir.deleteRecursively()
    }

    private val url get() = "http://127.0.0.1:${server.address.port}/f"

    @Test
    fun resumesFromPartialFile() = runBlocking {
        val dest = File(dir, "rootfs.tar.gz")
        File(dest.path + ".part").writeBytes(body.copyOf(100_000))
        var last = 0L
        Downloader().download(url, dest, sha) { done, total -> last = done; assertEquals(body.size.toLong(), total) }
        assertEquals(listOf("bytes=100000-"), ranges.toList())
        assertArrayEquals(body, dest.readBytes())
        assertEquals(body.size.toLong(), last)
        assertFalse(File(dest.path + ".part").exists())
    }

    @Test
    fun restartsWhenServerIgnoresRange() = runBlocking {
        honorRange = false
        val dest = File(dir, "rootfs.tar.gz")
        File(dest.path + ".part").writeBytes(ByteArray(5000) { 7 })
        Downloader().download(url, dest, sha) { _, _ -> }
        assertArrayEquals(body, dest.readBytes())
    }

    @Test
    fun corruptPartialIsDiscardedAndRefetched() = runBlocking {
        val dest = File(dir, "rootfs.tar.gz")
        File(dest.path + ".part").writeBytes(ByteArray(100_000) { 1 }) // wrong bytes
        Downloader().download(url, dest, sha) { _, _ -> }
        assertEquals(listOf("bytes=100000-", null), ranges.toList())
        assertArrayEquals(body, dest.readBytes())
    }

    @Test
    fun wrongChecksumFailsAndLeavesNoFile() {
        val dest = File(dir, "rootfs.tar.gz")
        assertThrows(IOException::class.java) {
            runBlocking { Downloader().download(url, dest, "0".repeat(64)) { _, _ -> } }
        }
        assertFalse(dest.exists())
        assertFalse(File(dest.path + ".part").exists())
    }

    @Test
    fun completeFileIsNotDownloadedAgain() = runBlocking {
        val dest = File(dir, "rootfs.tar.gz").apply { writeBytes(body) }
        Downloader().download(url, dest, sha) { _, _ -> }
        assertEquals(0, ranges.size)
    }
}
