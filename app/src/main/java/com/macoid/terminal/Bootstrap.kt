package com.macoid.terminal

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/**
 * Termux-style bootstrap installer.
 * Downloads one prebuilt bootstrap-<arch>.zip (apt + dpkg + coreutils + ... built for THIS app's prefix) and unpacks it
 * into the native prefix. After that, every package is just a .deb that apt extracts - no compiling, no runner.
 *
 *   app_process / com.macoid.terminal.Cli bootstrap <zip-url> <prefix-dir> [sha256]
 */
object NativeBoot {
    fun run(a: List<String>): Int {
        if (a.size < 2) { System.err.println("usage: bootstrap <zip-url> <prefix-dir> [sha256]"); return 2 }
        val url = a[0]
        val prefix = File(a[1]).absoluteFile
        val want = (a.getOrNull(2) ?: "").trim().lowercase()
        val parent = prefix.parentFile ?: return 1
        parent.mkdirs()
        val staging = File(parent, prefix.name + "-staging")
        val old = File(parent, prefix.name + "-old")
        val zip = File(parent, prefix.name + "-bootstrap.zip")

        staging.deleteRecursively(); old.deleteRecursively()
        var ok = false
        for (attempt in 1..3) {
            try { download(url, zip); ok = true; break }
            catch (e: Exception) { System.err.println("\nbootstrap: download failed (${e.message}), attempt $attempt/3") }
        }
        if (!ok) { zip.delete(); return 4 }

        if (want.length == 64) {
            val got = sha256(zip)
            if (got != want) {
                zip.delete()
                System.err.println("bootstrap: checksum mismatch (expected $want, got $got) - refusing to install")
                return 3
            }
        }

        staging.mkdirs()
        try { unpack(zip, staging) }
        catch (e: Exception) { staging.deleteRecursively(); zip.delete(); System.err.println("bootstrap: unpack failed: ${e.message}"); return 5 }
        zip.delete()

        if (prefix.exists() && !prefix.renameTo(old)) { staging.deleteRecursively(); System.err.println("bootstrap: cannot replace $prefix"); return 6 }
        if (!staging.renameTo(prefix)) {
            old.renameTo(prefix)
            System.err.println("bootstrap: cannot move the new prefix into place")
            return 6
        }
        old.deleteRecursively()
        System.err.println("bootstrap: installed into $prefix")
        return 0
    }

    private fun download(url: String, dest: File) {
        var u = url
        for (hop in 0 until 6) {
            val c = URL(u).openConnection() as HttpURLConnection
            c.instanceFollowRedirects = false
            c.connectTimeout = 20000
            c.readTimeout = 60000
            val code = c.responseCode
            if (code in 300..399) { u = URL(URL(u), c.getHeaderField("Location")).toString(); continue }
            if (code >= 400) throw RuntimeException("HTTP $code for $u")
            val total = c.contentLengthLong
            var done = 0L
            var lastPct = -1
            c.inputStream.use { i ->
                dest.outputStream().buffered(1 shl 16).use { o ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val n = i.read(buf)
                        if (n < 0) break
                        o.write(buf, 0, n)
                        done += n
                        if (total > 0) {
                            val pct = (done * 100 / total).toInt()
                            if (pct != lastPct) {
                                lastPct = pct
                                System.err.print("\r[macoid] downloading bootstrap: $pct%  (${done / 1048576} / ${total / 1048576} MB)")
                                System.err.flush()
                            }
                        }
                    }
                }
            }
            System.err.println()
            return
        }
        throw RuntimeException("too many redirects")
    }

    private fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { i ->
            val b = ByteArray(1 shl 16)
            while (true) { val n = i.read(b); if (n < 0) break; md.update(b, 0, n) }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /** Same layout Termux uses: files relative to the prefix, plus SYMLINKS.txt with lines "target<-linkpath". */
    private fun unpack(zip: File, dest: File) {
        val base = dest.canonicalFile
        val links = ArrayList<Pair<String, String>>()
        var files = 0
        ZipInputStream(zip.inputStream().buffered(1 shl 16)).use { z ->
            while (true) {
                val e = z.nextEntry ?: break
                if (e.name == "SYMLINKS.txt") {
                    z.readBytes().toString(Charsets.UTF_8).lineSequence().forEach { l ->
                        val p = l.split('\u2190')
                        if (p.size == 2) links.add(Pair(p[0], p[1]))
                    }
                    continue
                }
                val t = File(base, e.name).canonicalFile
                if (!t.path.startsWith(base.path + File.separator) && t != base) throw RuntimeException("unsafe path in bootstrap: ${e.name}")
                if (e.isDirectory) { t.mkdirs(); continue }
                t.parentFile?.mkdirs()
                t.outputStream().buffered(1 shl 16).use { o -> z.copyTo(o) }
                // same executable rules as Termux's own installer
                if (e.name.startsWith("bin/") || e.name.startsWith("libexec") ||
                    e.name.startsWith("lib/apt/apt-helper") || e.name.startsWith("lib/apt/methods")) {
                    android.system.Os.chmod(t.path, 448)   // 0700
                }
                files++
            }
        }
        for ((target, link) in links) {
            val lf = File(base, link)
            lf.parentFile?.mkdirs()
            try { android.system.Os.symlink(target, lf.path) } catch (e: Exception) { /* already exists */ }
        }
        // the bootstrap needs these folders before the first apt run
        listOf("tmp", "var/cache/apt/archives/partial", "var/lib/dpkg/updates", "var/log/apt").forEach { File(base, it).mkdirs() }
        System.err.println("[macoid] unpacked $files files, ${links.size} links")
    }
}
