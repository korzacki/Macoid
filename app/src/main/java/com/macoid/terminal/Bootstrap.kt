package com.macoid.terminal

import android.app.Activity
import android.app.AlertDialog
import android.app.ProgressDialog
import android.content.Context
import android.os.Build
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/**
 * Termux-style bootstrap installer (modelled on TermuxInstaller.java of termux-app 0.118.x).
 *
 * The bootstrap is ONE zip per CPU architecture holding apt + dpkg + bash + coreutils ... built for THIS app's prefix
 * (files/usr, see tools/build-repo.sh). Every later package is just a .deb that apt unpacks - no compiling, no runner.
 *
 * Two ways in, same unpack code:
 *  1. Bundled (like Termux): assets/bootstrap/bootstrap-<arch>.zip inside the APK. Installed on the FIRST LAUNCH
 *     (setupIfNeeded, with a progress dialog), works offline. Put the zips there with tools/bundle-bootstrap.sh.
 *  2. Download: `pkg install` calls  app_process / com.macoid.terminal.Cli bootstrap <zip-url|file> <prefix> [sha256]
 *     (used when no zip is bundled and NAT_BASE_URL in lib/native.conf is set).
 *
 * Same steps as Termux:
 *   (1) prefix exists and is not empty (or only tmp)  -> already installed, done
 *   (2) a leftover staging dir from a broken install is deleted
 *   (3) the zip is unpacked into a STAGING dir, never straight into the prefix; SYMLINKS.txt ("target<-link") is remembered
 *       and applied afterwards; bin/, libexec, apt helpers and the second-stage script get 0700
 *   (4) no SYMLINKS.txt = broken zip = error
 *   (5) staging is renamed to the prefix (atomic: a half-installed prefix is never used)
 *   (6) the second-stage script (dpkg configure of the unpacked packages) runs; if it fails the prefix is deleted again
 *       so the next start does not log into a broken prefix
 */
object NativeBoot {
    const val ASSET_DIR = "bootstrap"

    /** Termux 0.118.x keeps it in etc/termux/bootstrap; newer bootstraps use etc/termux/termux-bootstrap/second-stage. */
    private val SECOND_STAGE = listOf(
        "etc/termux/bootstrap/termux-bootstrap-second-stage.sh",
        "etc/termux/termux-bootstrap/second-stage/termux-bootstrap-second-stage.sh"
    )

    // ---------------------------------------------------------------- bundled bootstrap (first launch)

    /** Termux's arch names for the phone's primary ABI, or null when there is no bootstrap for it. */
    fun arch(): String? {
        for (abi in Build.SUPPORTED_ABIS) when (abi) {
            "arm64-v8a" -> return "aarch64"
            "armeabi-v7a", "armeabi" -> return "arm"
            "x86_64" -> return "x86_64"
            "x86" -> return "i686"
        }
        return null
    }

    private fun assetPath(): String? = arch()?.let { "$ASSET_DIR/bootstrap-$it.zip" }

    fun hasBundled(ctx: Context): Boolean {
        val a = arch() ?: return false
        return try { ctx.assets.list(ASSET_DIR)?.contains("bootstrap-$a.zip") == true } catch (e: Exception) { false }
    }

    fun prefixDir(ctx: Context): File = File(ctx.filesDir, "usr")

    /** Same test as Termux: a prefix with real content is installed; empty or only tmp/ is not. */
    fun isInstalled(prefix: File): Boolean {
        if (!prefix.isDirectory) return false
        val l = prefix.list() ?: return false
        return l.any { it != "tmp" }
    }

    /**
     * Call from onCreate. Runs [whenDone] on the UI thread: at once when nothing needs installing (already installed,
     * or no bootstrap bundled so the lazy download in `pkg install` stays in charge), otherwise after the install.
     */
    fun setupIfNeeded(activity: Activity, whenDone: () -> Unit) {
        // like Termux: only the primary user has the expected file system paths
        if (android.os.Process.myUid() / 100000 != 0) {
            showError(activity, "Macoid can only run as the primary user (device owner): the package prefix " +
                prefixDir(activity).path + " only exists there.", null, retry = false)
            return
        }
        val prefix = prefixDir(activity)
        if (isInstalled(prefix) || !hasBundled(activity)) { whenDone(); return }

        @Suppress("DEPRECATION")
        val progress = ProgressDialog.show(activity, null, "Installing bootstrap packages...", true, false)
        Thread {
            try {
                installBundled(activity, prefix)
                activity.runOnUiThread { whenDone() }
            } catch (e: Throwable) {
                prefix.deleteRecursively()   // never leave a broken prefix behind (Termux does the same)
                showError(activity, e.message ?: e.toString(), whenDone, retry = true)
            } finally {
                activity.runOnUiThread { try { progress.dismiss() } catch (e: RuntimeException) { /* activity already gone */ } }
            }
        }.start()
    }

    private fun showError(activity: Activity, msg: String, whenDone: (() -> Unit)?, retry: Boolean) {
        System.err.println("[macoid] bootstrap error: $msg")
        activity.runOnUiThread {
            try {
                val b = AlertDialog.Builder(activity).setTitle("Bootstrap error")
                    .setMessage("Installing the package system failed:\n\n$msg")
                    .setNegativeButton("Abort") { d, _ -> d.dismiss(); activity.finish() }
                if (retry && whenDone != null) b.setPositiveButton("Try again") { d, _ ->
                    d.dismiss(); prefixDir(activity).deleteRecursively(); setupIfNeeded(activity, whenDone)
                }
                b.show()
            } catch (e: RuntimeException) { /* BadTokenException: activity already gone */ }
        }
    }

    /** Unpack assets/bootstrap/bootstrap-<arch>.zip into [prefix]. Throws on any problem; the caller deletes the prefix. */
    fun installBundled(ctx: Context, prefix: File) {
        val asset = assetPath() ?: throw RuntimeException("no bootstrap for this CPU (${Build.SUPPORTED_ABIS.joinToString()})")
        val parent = prefix.absoluteFile.parentFile ?: throw RuntimeException("bad prefix $prefix")
        parent.mkdirs()
        val staging = File(parent, prefix.name + "-staging")
        staging.deleteRecursively()        // leftover of a broken installation
        prefix.deleteRecursively()         // empty / only tmp, or something else sitting in the way
        staging.mkdirs()
        try {
            ctx.assets.open(asset).use { unpack(it, staging) }
        } catch (e: Throwable) { staging.deleteRecursively(); throw e }
        if (!staging.renameTo(prefix)) { staging.deleteRecursively(); throw RuntimeException("moving $staging to $prefix failed") }
        secondStage(prefix)
        File(prefix, "tmp").mkdirs()
    }

    /** dpkg configure of the unpacked packages. Runs with the prefix's own bash, like nat_run in native.sh. */
    private fun secondStage(prefix: File) {
        val script = SECOND_STAGE.map { File(prefix, it) }.firstOrNull { it.isFile } ?: return   // older bootstraps have none
        val sh = listOf("bin/bash", "bin/sh").map { File(prefix, it) }.firstOrNull { it.exists() }
            ?: throw RuntimeException("bootstrap second stage: no bash/sh in $prefix/bin")
        val pb = ProcessBuilder(sh.path, script.path).redirectErrorStream(true)
        val env = pb.environment()
        env["PREFIX"] = prefix.path
        env["PATH"] = prefix.path + "/bin:" + (env["PATH"] ?: "/system/bin")
        env["HOME"] = File(prefix.parentFile, "home").also { it.mkdirs() }.path
        env["TMPDIR"] = File(prefix, "tmp").also { it.mkdirs() }.path
        env["DEBIAN_FRONTEND"] = "noninteractive"
        listOf("lib/libtermux-exec-ld-preload.so", "lib/libtermux-exec.so").map { File(prefix, it) }
            .firstOrNull { it.isFile }?.let { env["LD_PRELOAD"] = it.path }
        val p = pb.start()
        val out = p.inputStream.bufferedReader().readText()
        val rc = p.waitFor()
        if (rc != 0) throw RuntimeException("bootstrap second stage failed (exit $rc):\n" + out.takeLast(1500))
    }

    // ---------------------------------------------------------------- CLI: bootstrap <zip-url|file> <prefix> [sha256]

    fun run(a: List<String>): Int {
        if (a.size < 2) { System.err.println("usage: bootstrap <zip-url|file> <prefix-dir> [sha256]"); return 2 }
        val src = a[0]
        val prefix = File(a[1]).absoluteFile
        val want = (a.getOrNull(2) ?: "").trim().lowercase()
        val parent = prefix.parentFile ?: return 1
        parent.mkdirs()
        val staging = File(parent, prefix.name + "-staging")
        val old = File(parent, prefix.name + "-old")
        val zip = File(parent, prefix.name + "-bootstrap.zip")
        val local = !src.startsWith("http://") && !src.startsWith("https://")

        staging.deleteRecursively(); old.deleteRecursively()
        val file: File
        if (local) {
            file = File(src)
            if (!file.isFile) { System.err.println("bootstrap: $src not found"); return 4 }
        } else {
            var ok = false
            for (attempt in 1..3) {
                try { download(src, zip); ok = true; break }
                catch (e: Exception) { System.err.println("\nbootstrap: download failed (${e.message}), attempt $attempt/3") }
            }
            if (!ok) { zip.delete(); return 4 }
            file = zip
        }

        if (want.length == 64) {
            val got = sha256(file)
            if (got != want) {
                if (!local) zip.delete()
                System.err.println("bootstrap: checksum mismatch (expected $want, got $got) - refusing to install")
                return 3
            }
        }

        staging.mkdirs()
        try { file.inputStream().buffered(1 shl 16).use { unpack(it, staging) } }
        catch (e: Exception) { staging.deleteRecursively(); if (!local) zip.delete(); System.err.println("bootstrap: unpack failed: ${e.message}"); return 5 }
        if (!local) zip.delete()

        if (prefix.exists() && !prefix.renameTo(old)) { staging.deleteRecursively(); System.err.println("bootstrap: cannot replace $prefix"); return 6 }
        if (!staging.renameTo(prefix)) {
            old.renameTo(prefix)
            System.err.println("bootstrap: cannot move the new prefix into place")
            return 6
        }
        old.deleteRecursively()
        System.err.println("bootstrap: installed into $prefix")
        return 0   // the second stage is run by nat_setup in native.sh
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

    /** Termux layout: files relative to the prefix, plus SYMLINKS.txt with lines "target<-linkpath" (U+2190). */
    private fun unpack(input: InputStream, dest: File) {
        val base = dest.canonicalFile
        val links = ArrayList<Pair<String, String>>()
        var files = 0
        ZipInputStream(input).use { z ->
            while (true) {
                val e = z.nextEntry ?: break
                if (e.name == "SYMLINKS.txt") {
                    z.readBytes().toString(Charsets.UTF_8).lineSequence().filter { it.isNotBlank() }.forEach { l ->
                        val p = l.split('\u2190')
                        if (p.size != 2) throw RuntimeException("Malformed symlink line: $l")
                        links.add(Pair(p[0], p[1]))
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
                    e.name.startsWith("lib/apt/apt-helper") || e.name.startsWith("lib/apt/methods") ||
                    SECOND_STAGE.contains(e.name)) {
                    android.system.Os.chmod(t.path, 448)   // 0700
                }
                files++
            }
        }
        if (links.isEmpty()) throw RuntimeException("No SYMLINKS.txt encountered")
        for ((target, link) in links) {
            val lf = File(base, link)
            lf.parentFile?.mkdirs()
            try { android.system.Os.symlink(target, lf.path) }
            catch (e: Exception) { if (!Files.isSymbolicLink(lf.toPath())) throw RuntimeException("symlink $link -> $target failed: ${e.message}") }
        }
        // the bootstrap needs these folders before the first apt run
        listOf("tmp", "var/cache/apt/archives/partial", "var/lib/dpkg/updates", "var/log/apt").forEach { File(base, it).mkdirs() }
        System.err.println("[macoid] unpacked $files files, ${links.size} links")
    }
}
