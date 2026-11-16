// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.install

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/**
 * Resumable HTTP download: bytes go to `<dest>.part`, a later call continues
 * with a Range request, and the file is renamed to [dest] only after its
 * SHA256 matches.
 */
class Downloader(private val open: (String) -> HttpURLConnection = Http::open) {

    suspend fun download(
        url: String,
        dest: File,
        sha256: String,
        onProgress: (done: Long, total: Long) -> Unit,
    ): File = withContext(Dispatchers.IO) {
        if (dest.isFile && sha256Of(dest) == sha256) return@withContext dest
        dest.parentFile?.mkdirs()
        val part = File(dest.path + ".part")
        // Two attempts: a resumed .part from a different upstream file fails
        // the checksum once, then we start over from zero.
        for (attempt in 1..2) {
            fetch(url, part, onProgress)
            if (sha256Of(part) == sha256) {
                dest.delete()
                if (!part.renameTo(dest)) throw IOException("cannot rename ${part.name}")
                return@withContext dest
            }
            part.delete()
        }
        throw IOException("SHA256 mismatch for ${dest.name}")
    }

    private suspend fun fetch(url: String, part: File, onProgress: (Long, Long) -> Unit) {
        var have = if (part.isFile) part.length() else 0L
        val c = open(url)
        try {
            if (have > 0) c.setRequestProperty("Range", "bytes=$have-")
            val total = when (c.responseCode) {
                HttpURLConnection.HTTP_PARTIAL ->
                    c.getHeaderField("Content-Range")?.substringAfterLast('/')?.toLongOrNull() ?: -1L

                HttpURLConnection.HTTP_OK -> {
                    have = 0 // server ignored the Range header: start over
                    c.contentLengthLong
                }

                416 -> return

                // nothing left to fetch; the checksum decides
                else -> throw HttpException(c.responseCode, url)
            }
            c.inputStream.use { input ->
                FileOutputStream(part, have > 0).use { out ->
                    val buf = ByteArray(64 * 1024)
                    var done = have
                    var lastReport = 0L
                    onProgress(done, total)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        done += n
                        if (done - lastReport >= 256 * 1024) {
                            lastReport = done
                            onProgress(done, total)
                        }
                    }
                    onProgress(done, total)
                }
            }
        } finally {
            c.disconnect()
        }
    }

    companion object {
        fun sha256Of(file: File): String {
            val md = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    md.update(buf, 0, n)
                }
            }
            return md.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
