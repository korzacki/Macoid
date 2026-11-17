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

    /** Download to a file; redirects are followed manually so that auth headers are NOT leaked to other hosts. */
    fun download(url: String, headers: Map<String, String>, dest: File, quiet: Boolean = true) {
        var u = url
        var h = headers
        for (hop in 0 until 6) {
            val c = URL(u).openConnection() as HttpURLConnection
            c.instanceFollowRedirects = false
            c.connectTimeout = 20000
            c.readTimeout = 120000
            h.forEach { (k, v) -> c.setRequestProperty(k, v) }
            val code = c.responseCode
            if (code in 300..399) {
                u = URL(URL(u), c.getHeaderField("Location")).toString()
                h = h.filterKeys { !it.equals("Authorization", true) }
                continue
            }
            if (code >= 400) throw RuntimeException("HTTP $code for $u")
            dest.absoluteFile.parentFile?.mkdirs()
            c.inputStream.use { i -> dest.outputStream().use { o -> i.copyTo(o) } }
            if (!quiet) System.err.println("saved ${dest.path} (${dest.length()} bytes)")
            return
        }
        throw RuntimeException("too many redirects")
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
