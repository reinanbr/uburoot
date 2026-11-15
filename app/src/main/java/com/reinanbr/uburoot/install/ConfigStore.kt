package com.reinanbr.uburoot.install

import android.content.Context
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.Sh
import com.reinanbr.uburoot.root.UbuPaths
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Reads and writes uburoot.conf (root:root 644 in /data/local/uburoot, so through su). */
object ConfigStore {
    suspend fun read(): UbuConfig {
        val r = RootShell.run("[ ! -e ${UbuPaths.CONFIG} ] || cat ${UbuPaths.CONFIG}")
        if (!r.ok) error("cannot read ${UbuPaths.CONFIG}: ${r.text}")
        return UbuConfig.parse(r.text)
    }

    suspend fun write(context: Context, config: UbuConfig) {
        val tmp = File(context.cacheDir, "uburoot.conf")
        withContext(Dispatchers.IO) { tmp.writeText(config.render()) }
        // Written next to the target and renamed: a script sourcing it never sees half a file.
        val r = RootShell.run(
            "cp -f ${Sh.quote(tmp.absolutePath)} ${UbuPaths.CONFIG}.new && " +
                "chown 0:0 ${UbuPaths.CONFIG}.new && chmod 644 ${UbuPaths.CONFIG}.new && " +
                "mv -f ${UbuPaths.CONFIG}.new ${UbuPaths.CONFIG}",
        )
        withContext(Dispatchers.IO) { tmp.delete() }
        if (!r.ok) error("cannot write ${UbuPaths.CONFIG}: ${r.text}")
    }

    /** Ubuntu accounts a session can log in as: root plus the regular users (uid 1000..59999). */
    suspend fun users(): List<String> {
        val r = RootShell.run(
            "awk -F: '\$3 >= 1000 && \$3 < 60000 { print \$1 }' ${UbuPaths.ROOTFS}/etc/passwd",
        )
        return listOf("root") + if (r.ok) r.out.filter { it.isNotBlank() } else emptyList()
    }
}
