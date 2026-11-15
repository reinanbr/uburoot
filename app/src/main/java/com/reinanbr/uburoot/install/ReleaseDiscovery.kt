package com.reinanbr.uburoot.install

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class UbuntuRelease(val version: String, val fileName: String, val url: String, val sha256: String)

/**
 * Finds the newest Ubuntu Base LTS (YY.04 with even YY) for arm64 on
 * cdimage.ubuntu.com. Nothing is hardcoded: the directory listing, the
 * point release and the checksum all come from the server.
 */
object ReleaseDiscovery {
    const val BASE_URL = "https://cdimage.ubuntu.com/ubuntu-base/releases/"

    private val HREF = Regex("""href="([^"]+)"""")
    private val SERIES_DIR = Regex("""^(\d{2})\.04$""")

    /** Two-digit years of the LTS series in the releases index, newest first. */
    fun ltsSeries(indexHtml: String): List<Int> = hrefs(indexHtml)
        .mapNotNull { SERIES_DIR.matchEntire(lastSegment(it))?.groupValues?.get(1)?.toInt() }
        .filter { it % 2 == 0 }
        .distinct()
        .sortedDescending()

    /** The newest arm64 tarball of series [yy] in a `YY.04/release/` listing. */
    fun arm64Tarball(listingHtml: String, yy: Int): Pair<String, String>? {
        val re = Regex("""^ubuntu-base-(${"%02d".format(yy)}\.04(?:\.(\d+))?)-base-arm64\.tar\.gz$""")
        return hrefs(listingHtml)
            .mapNotNull { re.matchEntire(lastSegment(it)) }
            .maxByOrNull { it.groupValues[2].toIntOrNull() ?: 0 }
            ?.let { it.value to it.groupValues[1] }
    }

    /** SHA256SUMS lines look like `<hash> *<file>` (binary) or `<hash>  <file>`. */
    fun sha256For(sums: String, fileName: String): String? = sums.lineSequence()
        .map { it.trim().split(Regex("\\s+"), limit = 2) }
        .firstOrNull { it.size == 2 && it[1].removePrefix("*") == fileName }
        ?.get(0)
        ?.lowercase()
        ?.takeIf { it.matches(Regex("[0-9a-f]{64}")) }

    suspend fun discover(fetch: (String) -> String = Http::getText): UbuntuRelease = withContext(Dispatchers.IO) {
        val series = ltsSeries(fetch(BASE_URL))
        if (series.isEmpty()) error("no LTS release found at $BASE_URL")
        // A brand-new series directory may not have an arm64 build yet.
        for (yy in series.take(3)) {
            val dir = BASE_URL + "%02d.04/release/".format(yy)
            val listing = try {
                fetch(dir)
            } catch (e: HttpException) {
                if (e.code == 404) continue else throw e
            }
            val (file, version) = arm64Tarball(listing, yy) ?: continue
            val sha = sha256For(fetch(dir + "SHA256SUMS"), file)
                ?: error("$file is not listed in ${dir}SHA256SUMS")
            return@withContext UbuntuRelease(version, file, dir + file, sha)
        }
        error("no arm64 Ubuntu Base tarball found for LTS series $series")
    }

    private fun hrefs(html: String) = HREF.findAll(html).map { it.groupValues[1] }.toList()

    private fun lastSegment(href: String) = href.trimEnd('/').substringAfterLast('/')
}
