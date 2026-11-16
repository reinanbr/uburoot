package com.reinanbr.uburoot.bridge

import android.annotation.SuppressLint

/**
 * Maps where Android says a shared file lives to its directory inside Ubuntu.
 * Only the phone's primary shared storage is visible there (as /sdcard), so
 * anything else gives null and the file is imported instead (bridge.sh import).
 */
@SuppressLint("SdCardPath") // paths inside Ubuntu and Android's names for user 0's storage, not app storage
object SharedPaths {
    const val SDCARD = "/sdcard"

    // How Android spells the primary shared storage (user 0).
    private val ANDROID_ROOTS = listOf(
        "/storage/emulated/0",
        "/storage/self/primary",
        "/sdcard",
        "/data/media/0",
        "/mnt/user/0/emulated/0",
    )

    /** "primary:Download/a.pdf" (ExternalStorageProvider) -> "/sdcard/Download". */
    fun fromExternalStorageDocId(docId: String): String? {
        val colon = docId.indexOf(':')
        if (colon < 0) return null
        val rel = docId.substring(colon + 1)
        return when (docId.substring(0, colon)) {
            "primary" -> parentDir(SDCARD, rel)
            "home" -> parentDir("$SDCARD/Documents", rel)
            else -> null
        }
    }

    /** "raw:/storage/emulated/0/Download/a.pdf" (DownloadsProvider) and plain paths. */
    fun fromDownloadsDocId(docId: String): String? =
        if (docId.startsWith("raw:")) fromAndroidPath(docId.removePrefix("raw:")) else null

    /** "/storage/emulated/0/Download/a.pdf" -> "/sdcard/Download". */
    fun fromAndroidPath(path: String): String? {
        for (root in ANDROID_ROOTS) {
            if (path.startsWith("$root/")) return parentDir(SDCARD, path.removePrefix("$root/"))
        }
        return null
    }

    /** MediaStore's VOLUME_NAME + RELATIVE_PATH ("Download/Sub/") -> "/sdcard/Download/Sub". */
    fun fromMediaStore(volume: String?, relativePath: String?): String? {
        if (relativePath == null || volume !in setOf(null, "external", "external_primary")) return null
        val rel = relativePath.trim('/')
        if (!safe(rel)) return null
        return if (rel.isEmpty()) SDCARD else "$SDCARD/$rel"
    }

    /** Directory of [rel] (a file path relative to [base]); null on "..", "." or empty parts. */
    private fun parentDir(base: String, rel: String): String? {
        val dir = rel.trim('/').substringBeforeLast('/', "")
        if (!safe(dir)) return null
        return if (dir.isEmpty()) base else "$base/$dir"
    }

    private fun safe(rel: String) = rel.isEmpty() ||
        (rel.none { it < ' ' } && rel.split('/').none { it.isEmpty() || it == "." || it == ".." })

    /** A file name that is safe as one path component. */
    fun safeName(name: String?): String {
        val n = name?.substringAfterLast('/')?.replace(Regex("[\\u0000-\\u001f]"), "")?.trim().orEmpty()
        return if (n.isEmpty() || n == "." || n == "..") "shared-file" else n.take(200)
    }
}
