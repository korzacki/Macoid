package com.macoid.terminal

import java.io.File
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL

object Http {
    class Resp(val code: Int, val body: String, val location: String?, val headers: Map<String?, List<String>>)

    private fun setMethod(c: HttpURLConnection, m: String) {
        try {
            c.requestMethod = m
        } catch (e: java.net.ProtocolException) {
            val f = HttpURLConnection::class.java.getDeclaredField("method")
            f.isAccessible = true
            f.set(c, m)
        }
    }

    fun request(
        method: String, url: String, headers: Map<String, String> = emptyMap(),
        body: ByteArray? = null, follow: Boolean = true
    ): Resp {
        val c = URL(url).openConnection() as HttpURLConnection
        c.instanceFollowRedirects = follow
        c.connectTimeout = 20000
        c.readTimeout = 120000
        setMethod(c, method)
        headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
        if (body != null) {
            c.doOutput = true
            c.outputStream.use { it.write(body) }
        }
        val code = c.responseCode
        val stream = if (code >= 400) c.errorStream else c.inputStream
        val txt = stream?.use { String(it.readBytes()) } ?: ""
        return Resp(code, txt, c.getHeaderField("Location"), c.headerFields)
    }

    /** HTTP statuses worth another try (rate limit, server hiccups). */
    private fun retryable(code: Int) = code == 408 || code == 429 || code in 500..599

    /** GET/HEAD with a few retries on network errors and 5xx, so one dropped packet does not fail a whole command. */
    fun requestRetry(
        method: String, url: String, headers: Map<String, String> = emptyMap(),
        body: ByteArray? = null, follow: Boolean = true, tries: Int = 3
    ): Resp {
        var last: Exception? = null
        for (i in 1..tries) {
            try {
                val r = request(method, url, headers, body, follow)
                if (retryable(r.code) && i < tries) { Thread.sleep(1500L * i); continue }
                return r
            } catch (e: java.io.IOException) {
                last = e
                if (i < tries) Thread.sleep(1500L * i)
            }
        }
        throw last ?: RuntimeException("request failed: $url")
    }

    /**
     * Download to a file. Redirects are followed manually so that auth headers are NOT leaked to other hosts.
     * Robust: data goes to "<dest>.part" and is renamed only when complete; a dropped connection is retried and
     * RESUMED from where it stopped (Range), a left-over .part from an earlier try is continued, never started again;
     * the size is checked against Content-Length.
     */
    fun download(url: String, headers: Map<String, String>, dest: File, quiet: Boolean = true, tries: Int = 5) {
        dest.absoluteFile.parentFile?.mkdirs()
        val part = File(dest.path + ".part")
        // a .part that is older than a day is probably from a different version of the file: start clean
        if (part.exists() && System.currentTimeMillis() - part.lastModified() > 24L * 3600 * 1000) part.delete()
        var lastErr: Exception? = null
        for (attempt in 1..tries) {
            try {
                if (fetchOnce(url, headers, part, quiet)) { moveInto(part, dest); if (!quiet) System.err.println("saved ${dest.path} (${dest.length()} bytes)"); return }
            } catch (e: HttpFatal) {
                part.delete(); throw RuntimeException(e.message)
            } catch (e: Exception) {
                lastErr = e
                if (!quiet) System.err.println("download interrupted (${e.message ?: e.javaClass.simpleName}), try $attempt/$tries")
            }
            if (attempt < tries) Thread.sleep(2000L * attempt)
        }
        // the .part stays on purpose: the next run continues it
        throw RuntimeException("download failed after $tries tries: ${lastErr?.message ?: url}")
    }

    private class HttpFatal(msg: String) : Exception(msg)

    private fun moveInto(part: File, dest: File) {
        dest.delete()
        if (!part.renameTo(dest)) { part.copyTo(dest, overwrite = true); part.delete() }
    }

    /** One connection. Returns true when part now holds the complete file. */
    private fun fetchOnce(url: String, headers: Map<String, String>, part: File, quiet: Boolean): Boolean {
        var u = url
        var h = headers.toMutableMap()
        for (hop in 0 until 8) {
            val have = if (part.exists()) part.length() else 0L
            val c = URL(u).openConnection() as HttpURLConnection
            c.instanceFollowRedirects = false
            c.connectTimeout = 20000
            c.readTimeout = 60000
            h.forEach { (k, v) -> c.setRequestProperty(k, v) }
            c.setRequestProperty("Accept-Encoding", "identity")   // a gzip layer would make Content-Length / Range lie
            if (have > 0) c.setRequestProperty("Range", "bytes=$have-")
            val code = c.responseCode
            if (code in 300..399) {
                val loc = c.getHeaderField("Location") ?: throw HttpFatal("HTTP $code without Location for $u")
                u = URL(URL(u), loc).toString()
                h = h.filterKeys { !it.equals("Authorization", true) }.toMutableMap()
                c.disconnect()
                continue
            }
            if (code == 416) { part.delete(); c.disconnect(); throw java.io.IOException("server refused the resume, starting again") }
            if (code == 410) throw HttpFatal("HTTP 410: the file is gone (expired) - $u")
            if (code >= 400) {
                if (retryable(code)) throw java.io.IOException("HTTP $code for $u")
                throw HttpFatal("HTTP $code for $u")
            }
            val resumed = code == 206 && have > 0
            if (!resumed && have > 0) part.delete()            // server sent the whole file again
            val len = c.contentLengthLong
            val total = if (len >= 0) len + (if (resumed) have else 0L) else -1L
            var done = if (resumed) have else 0L
            var lastPct = -1
            c.inputStream.use { i ->
                java.io.FileOutputStream(part, resumed).buffered(1 shl 16).use { o ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val n = i.read(buf)
                        if (n < 0) break
                        o.write(buf, 0, n)
                        done += n
                        if (!quiet && total > 0) {
                            val pct = (done * 100 / total).toInt()
                            if (pct != lastPct) { lastPct = pct; System.err.print("\r[macoid] downloading: $pct%"); System.err.flush() }
                        }
                    }
                }
            }
            if (!quiet && total > 0) System.err.println()
            if (total >= 0 && part.length() != total) throw java.io.IOException("incomplete download (${part.length()} of $total bytes)")
            return true
        }
        throw HttpFatal("too many redirects")
    }
}

object HttpCmd {
    fun curl(a: List<String>): Int {
        val o = Opts(a, setOf("-o", "-X", "-H", "-d", "--data", "--data-binary", "-u", "-A", "--output", "--request", "--header", "--user", "--user-agent", "--max-time", "-m", "-w"))
        val url = o.pos.firstOrNull() ?: run { System.err.println("curl: no URL specified"); return 2 }
        val full = if (url.contains("://")) url else "https://$url"
        val headers = LinkedHashMap<String, String>()
        o.all("-H", "--header").forEach { h -> headers[h.substringBefore(':').trim()] = h.substringAfter(':', "").trim() }
        o.v("-A", "--user-agent")?.let { headers["User-Agent"] = it }
        o.v("-u", "--user")?.let { headers["Authorization"] = "Basic " + java.util.Base64.getEncoder().encodeToString(it.toByteArray()) }
        var body = (o.all("-d", "--data", "--data-binary")).takeIf { it.isNotEmpty() }?.joinToString("&")
        if (body != null && body.startsWith("@")) body = Cli.res(body.substring(1)).readText()
        val method = o.v("-X", "--request") ?: if (o.has("-I", "--head")) "HEAD" else if (body != null) "POST" else "GET"
        if (body != null && !headers.keys.any { it.equals("Content-Type", true) }) headers["Content-Type"] = "application/x-www-form-urlencoded"
        val r = Http.request(method, full, headers, body?.toByteArray(), follow = o.has("-L", "--location"))
        val silent = o.has("-s", "--silent")
        if (o.has("-I", "--head") || o.has("-i", "--include")) {
            r.headers.forEach { (k, v) -> println(if (k == null) v.joinToString() else "$k: ${v.joinToString(", ")}") }
            println()
        }
        if (o.has("-f", "--fail") && r.code >= 400) { if (!silent) System.err.println("curl: (22) The requested URL returned error: ${r.code}"); return 22 }
        if (!o.has("-I", "--head")) {
            val out = o.v("-o", "--output") ?: if (o.has("-O")) full.substringAfterLast('/').ifEmpty { "index.html" } else null
            if (out != null) Cli.res(out).writeText(r.body) else print(r.body)
        }
        return 0
    }

    fun wget(a: List<String>): Int {
        val o = Opts(a, setOf("-O", "-U", "--header"))
        val url = o.pos.firstOrNull() ?: run { System.err.println("wget: missing URL"); return 1 }
        val full = if (url.contains("://")) url else "https://$url"
        val name = o.v("-O") ?: full.substringBefore('?').substringAfterLast('/').ifEmpty { "index.html" }
        val h = HashMap<String, String>()
        o.v("-U")?.let { h["User-Agent"] = it }
        if (name == "-") { print(Http.request("GET", full, h).body); return 0 }
        Http.download(full, h, Cli.res(name), quiet = o.has("-q"))
        return 0
    }

    /** host / nslookup / dig-style lookups */
    fun dns(a: List<String>): Int {
        val names = a.filter { !it.startsWith("-") && !it.startsWith("+") && !it.startsWith("@") }
        if (names.isEmpty()) { System.err.println("usage: host <name>"); return 1 }
        var rc = 0
        for (n in names) {
            try {
                InetAddress.getAllByName(n).forEach {
                    if (a.contains("+short")) println(it.hostAddress)
                    else println("$n has ${if (it.address.size == 4) "address" else "IPv6 address"} ${it.hostAddress}")
                }
            } catch (e: Exception) { System.err.println("Host $n not found"); rc = 1 }
        }
        return rc
    }
}
