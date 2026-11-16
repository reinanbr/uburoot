// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.hwbridge

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import kotlin.concurrent.thread

/**
 * One bridge's server: an abstract Unix socket with a random name and a random token,
 * both published inside Ubuntu by `hardware.sh bridge publish` (readable by root and
 * the class's group). Abstract sockets have no file permissions, so every request must
 * carry the token, and the peer must be root or a chroot user (uid 8000-9996, where
 * setup.sh puts them): never another Android app (uid >= 10000).
 */
class BridgeServer(val name: String, private val handler: (BridgeRequest) -> Unit) {
    val socketName = "uburoot.${hex(8)}.$name"
    val token = hex(16)
    private val server = LocalServerSocket(socketName)

    @Volatile private var stopped = false

    init {
        thread(name = "bridge-$name", isDaemon = true) {
            while (!stopped) {
                val s = try {
                    server.accept()
                } catch (_: IOException) {
                    break
                }
                if (stopped) {
                    runCatching { s.close() }
                    break
                }
                thread(name = "bridge-$name-conn", isDaemon = true) { serve(s) }
            }
        }
    }

    private fun serve(s: LocalSocket) {
        val req = try {
            val uid = s.peerCredentials.uid
            val line = readLine(s.inputStream) ?: return s.close()
            val parts = line.split(' ').filter { it.isNotEmpty() }
            val good = parts.size >= 2 &&
                MessageDigest.isEqual(parts[0].toByteArray(), token.toByteArray()) &&
                (uid == 0 || uid in CHROOT_UIDS)
            BridgeRequest(if (good) parts[1] else "", parts.drop(2), s)
        } catch (_: IOException) {
            runCatching { s.close() }
            return
        }
        try {
            if (req.cmd.isEmpty()) req.err("refused") else handler(req)
        } catch (_: IOException) {
            // The client went away.
        } catch (e: Exception) {
            runCatching { if (!req.answered) req.err(e.message ?: e.javaClass.simpleName) }
        } finally {
            req.close()
        }
    }

    fun stop() {
        stopped = true
        // close() does not wake a thread blocked in accept(): connect once instead.
        runCatching { LocalSocket().use { it.connect(LocalSocketAddress(socketName)) } }
        runCatching { server.close() }
    }

    companion object {
        val CHROOT_UIDS = 8000..9996
        private val random = SecureRandom()

        fun hex(bytes: Int): String = ByteArray(bytes).also(random::nextBytes).joinToString("") { "%02x".format(it) }

        private fun readLine(input: InputStream): String? {
            val sb = StringBuilder()
            while (sb.length < 512) {
                val c = input.read()
                if (c < 0) return null
                if (c == '\n'.code) return sb.toString()
                sb.append(c.toChar())
            }
            return null
        }
    }
}

/** One client request: `TOKEN COMMAND ARGS`, answered by `OK [info]` or `ERR message`. */
class BridgeRequest(val cmd: String, val args: List<String>, private val socket: LocalSocket) {
    val input: InputStream = socket.inputStream
    val out: OutputStream = socket.outputStream

    @Volatile var answered = false
        private set

    fun ok(info: String = "") {
        answered = true
        out.write((if (info.isEmpty()) "OK\n" else "OK $info\n").toByteArray())
    }

    fun err(message: String) {
        answered = true
        out.write("ERR ${message.replace('\n', ' ')}\n".toByteArray())
    }

    /**
     * For streams that write only when something happens (sensors, NMEA): calls
     * [onGone] once the client closes its end, so the stream stops even when idle.
     */
    fun onHangup(onGone: () -> Unit) {
        thread(name = "bridge-hangup", isDaemon = true) {
            try {
                @Suppress("ControlFlowWithEmptyBody")
                while (input.read() >= 0) {
                }
            } catch (_: IOException) {
                // Closed: the same as an end of stream.
            }
            onGone()
        }
    }

    fun close() {
        runCatching { socket.shutdownOutput() }
        runCatching { socket.close() }
    }
}
