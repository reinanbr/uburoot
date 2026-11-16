// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.root

/** POSIX shell helpers for building commands that run through `su`. */
object Sh {
    /** Quote [s] as a single shell word: `it's` -> `'it'\''s'`. */
    fun quote(s: String): String = "'" + s.replace("'", "'\\''") + "'"
}
