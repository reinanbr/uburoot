// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.root

import android.content.Context
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Copies assets/uburoot/bin to /data/local/uburoot/bin (root-owned, 0755). */
object ScriptDeployer {
    private const val ASSET_DIR = "uburoot/bin"

    suspend fun deploy(context: Context): RootShell.Result {
        val staging = File(context.cacheDir, "uburoot-bin")
        withContext(Dispatchers.IO) {
            staging.deleteRecursively()
            staging.mkdirs()
            for (name in context.assets.list(ASSET_DIR).orEmpty()) {
                context.assets.open("$ASSET_DIR/$name").use { input ->
                    File(staging, name).outputStream().use { input.copyTo(it) }
                }
            }
        }
        // Replace each script by rename, never in place: a running sh reads its
        // script incrementally, so truncating it under a live session breaks it.
        val src = Sh.quote(staging.absolutePath)
        val bin = UbuPaths.BIN
        return RootShell.run(
            """
            set -e
            mkdir -p $bin
            chmod 755 ${UbuPaths.BASE} $bin
            for f in $src/*; do
                n=${'$'}{f##*/}
                cmp -s "${'$'}f" "$bin/${'$'}n" 2>/dev/null && continue
                cp -f "${'$'}f" "$bin/.${'$'}n.new"
                chown 0:0 "$bin/.${'$'}n.new"
                chmod 755 "$bin/.${'$'}n.new"
                mv -f "$bin/.${'$'}n.new" "$bin/${'$'}n"
            done
            """.trimIndent(),
        ).also { withContext(Dispatchers.IO) { staging.deleteRecursively() } }
    }

    suspend fun rootInfo(): RootInfo = RootInfo.parse(RootShell.run(UbuPaths.script("rootinfo.sh")).out)
}
