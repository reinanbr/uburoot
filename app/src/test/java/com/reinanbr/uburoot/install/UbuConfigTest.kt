package com.reinanbr.uburoot.install

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UbuConfigTest {
    @Test
    fun rendersEveryKeyQuoted() {
        val text = UbuConfig(defaultUser = "ana", initCommand = "echo 'hi'; cd /").render()
        assertTrue(text.contains("DEFAULT_USER='ana'\n"))
        assertTrue(text.contains("MOUNT_SDCARD='1'\n"))
        assertTrue(text.contains("INIT_COMMAND='echo '\\''hi'\\''; cd /'\n"))
        assertTrue(text.contains("INOTIFY_MAX_WATCHES='524288'\n"))
        assertTrue(UbuConfig(inotifyMaxWatches = -5).render().contains("INOTIFY_MAX_WATCHES='0'\n"))
    }

    /** The scripts `. uburoot.conf`: sourcing it must only set variables. */
    @Test
    fun sourcingInSShGivesBackTheValues() {
        val cfg = UbuConfig(defaultUser = "ana", initCommand = "\$(touch /tmp/pwned) `id` 'x'", hostname = "h")
        val f = File.createTempFile("uburoot", ".conf").apply { writeText(cfg.render()) }
        try {
            val p = ProcessBuilder(
                "sh",
                "-c",
                ". \"$1\"; printf '%s|%s|%s' \"\$DEFAULT_USER\" \"\$INIT_COMMAND\" \"\$UBU_HOSTNAME\"",
                "sh",
                f.path,
            ).start()
            val out = p.inputStream.readBytes().decodeToString()
            assertEquals(0, p.waitFor())
            assertEquals("ana|${cfg.initCommand}|h", out)
        } finally {
            f.delete()
        }
    }

    @Test
    fun userNameRules() {
        for (ok in listOf("ana", "_x", "dev-1", "a_b")) assertTrue(ok, UbuConfig.isValidUserName(ok))
        for (bad in listOf("", "Root", "root", "daemon", "_apt", "1abc", "a b", "a;b", "-x", "a".repeat(33))) {
            assertFalse(bad, UbuConfig.isValidUserName(bad))
        }
    }
}
