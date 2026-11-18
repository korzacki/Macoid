package com.macoid.terminal

import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

object Zips {
    /** Extract with zip-slip protection. */
    fun extract(zip: File, dest: File, quiet: Boolean = true, overwrite: Boolean = true): Int {
        var n = 0
        val base = dest.absoluteFile.canonicalFile
        base.mkdirs()
        ZipFile(zip).use { z ->
            for (e in z.entries()) {
                val t = File(base, e.name).canonicalFile
                if (!t.path.startsWith(base.path + File.separator) && t != base) throw RuntimeException("unsafe path in zip: ${e.name}")
                if (e.isDirectory) { t.mkdirs(); continue }
                if (t.exists() && !overwrite) continue
                t.parentFile?.mkdirs()
                z.getInputStream(e).use { i -> t.outputStream().use { o -> i.copyTo(o) } }
                n++
                if (!quiet) println("  inflating: ${e.name}")
            }
        }
        return n
    }
}

object ZipCmd {
    fun unzip(a: List<String>): Int {
        val o = Opts(a, setOf("-d"))
        val f = o.pos.firstOrNull() ?: run { System.err.println("usage: unzip [-l] [-o] [-q] [-d dir] file.zip"); return 1 }
        val file = Cli.res(f).let { if (it.exists()) it else Cli.res("$f.zip") }
        if (!file.exists()) { System.err.println("unzip: cannot find $f"); return 9 }
        if (o.has("-l")) {
            ZipFile(file).use { z -> for (e in z.entries()) println(String.format("%10d  %s", e.size, e.name)) }
            return 0
        }
        val dest = Cli.res(o.v("-d") ?: ".")
        println("Archive:  ${file.name}")
        Zips.extract(file, dest, quiet = o.has("-q"), overwrite = true)
        return 0
    }

    /** zip -x pattern: a plain name excludes any path segment with that name; patterns with * ? / match the whole path. */
    private fun excluded(rel: String, pats: List<Regex>, names: Set<String>): Boolean {
        if (names.isNotEmpty() && rel.split('/').any { it in names }) return true
        return pats.any { it.matches(rel) || it.matches("$rel/") }
    }

    private fun glob(p: String): Regex = Regex(buildString {
        for (c in p) when (c) { '*' -> append(".*"); '?' -> append('.'); else -> append(Regex.escape(c.toString())) }
    })

    fun zip(a: List<String>): Int {
        val o = Opts(a, setOf("-x"))
        if (o.pos.size < 2) { System.err.println("usage: zip [-r] [-q] [-x pattern]... out.zip file..."); return 1 }
        var out = o.pos[0]
        if (!out.endsWith(".zip")) out += ".zip"
        val outF = Cli.res(out).canonicalFile
        val quiet = o.has("-q")
        val xs = o.all("-x")
        val names = xs.filter { !it.contains('*') && !it.contains('?') && !it.contains('/') }.toSet()
        val pats = xs.filter { it.contains('*') || it.contains('?') || it.contains('/') }.map { glob(it.trimStart('.', '/')) }
        outF.parentFile?.mkdirs()
        ZipOutputStream(outF.outputStream().buffered()).use { z ->
            fun add(f: File, name: String) {
                if (f.canonicalFile == outF) return                       // never put the archive into itself
                if (excluded(name, pats, names)) return
                if (f.isDirectory) {
                    z.putNextEntry(ZipEntry("$name/")); z.closeEntry()
                    if (o.has("-r")) f.listFiles()?.sortedBy { it.name }?.forEach { add(it, "$name/${it.name}") }
                } else {
                    z.putNextEntry(ZipEntry(name))
                    f.inputStream().use { it.copyTo(z) }
                    z.closeEntry()
                }
                if (!quiet) println("  adding: $name")
            }
            for (p in o.pos.drop(1)) {
                val f = Cli.res(p)
                if (!f.exists()) { System.err.println("zip warning: name not matched: $p"); continue }
                if (p == "." || p == "./") {                              // "zip -r out.zip ." = the folder's contents, no "./" prefix
                    if (o.has("-r")) f.listFiles()?.sortedBy { it.name }?.forEach { add(it, it.name) }
                    continue
                }
                add(f, p.trimEnd('/'))
            }
        }
        return 0
    }
}
