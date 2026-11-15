package com.reinanbr.uburoot.root

/** Device paths; keep in sync with common.sh and CLAUDE.md. */
object UbuPaths {
    const val BASE = "/data/local/uburoot"
    const val BIN = "$BASE/bin"
    const val ROOTFS = "$BASE/rootfs"
    const val CONFIG = "$BASE/uburoot.conf"

    fun script(name: String) = "$BIN/$name"
}
