// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.install

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

internal object Http {
    // Generic client name: no device or user details leave the phone.
    const val USER_AGENT = "UbuRoot"

    fun open(url: String): HttpURLConnection = (URL(url).openConnection() as HttpURLConnection).apply {
        connectTimeout = 20_000
        readTimeout = 30_000
        instanceFollowRedirects = true
        setRequestProperty("User-Agent", USER_AGENT)
    }

    fun getText(url: String): String {
        val c = open(url)
        try {
            if (c.responseCode != HttpURLConnection.HTTP_OK) {
                throw HttpException(c.responseCode, url)
            }
            return c.inputStream.bufferedReader().use { it.readText() }
        } finally {
            c.disconnect()
        }
    }
}

class HttpException(val code: Int, url: String) : IOException("HTTP $code: $url")
