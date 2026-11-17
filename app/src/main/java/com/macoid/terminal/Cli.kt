package com.macoid.terminal

import java.io.File
import kotlin.system.exitProcess

/** Entry point for JVM tools, launched from shell scripts via: app_process / com.macoid.terminal.Cli <tool> args */
object Cli {
    @JvmStatic
    fun main(args: Array<String>) {
        System.setProperty("user.home", System.getenv("HOME") ?: "/data/local/tmp")
        val rest = args.drop(1)
        val code = try {
            when (args.firstOrNull()) {
                "git" -> GitCmd.run(rest)
                "gh" -> GhCmd.run(rest)
                "curl" -> HttpCmd.curl(rest)
                "wget" -> HttpCmd.wget(rest)
                "dns" -> HttpCmd.dns(rest)
                "unzip" -> ZipCmd.unzip(rest)
                "zip" -> ZipCmd.zip(rest)
                else -> { System.err.println("macoid: unknown tool '${args.firstOrNull()}'"); 127 }
            }
        } catch (e: Throwable) {
            System.err.println("error: ${e.message ?: e.toString()}")
            1
        }
        System.out.flush()
        System.err.flush()
        exitProcess(code)
    }

    fun cwd(): File = File(System.getProperty("user.dir") ?: ".")
}

/** Tiny option parser: valueFlags take an argument, everything else starting with '-' is boolean. */
class Opts(args: List<String>, valueFlags: Set<String> = emptySet()) {
    val pos = ArrayList<String>()
    val multi = HashMap<String, MutableList<String>>()
    val bools = HashSet<String>()

    init {
        var i = 0
        while (i < args.size) {
            val a = args[i]
            if (a == "--") { pos.addAll(args.drop(i + 1)); break }
            if (a.startsWith("-") && a.length > 1) {
                val k = a.substringBefore('=')
                if (k in valueFlags) {
                    val v = if (a.contains('=')) a.substringAfter('=') else { i++; args.getOrElse(i) { "" } }
                    multi.getOrPut(k) { ArrayList() }.add(v)
                } else bools.add(k)
            } else pos.add(a)
            i++
        }
    }

    fun v(vararg k: String): String? = k.firstNotNullOfOrNull { multi[it]?.lastOrNull() }
    fun all(vararg k: String): List<String> = k.flatMap { multi[it] ?: emptyList() }
    fun has(vararg k: String): Boolean = k.any { it in bools || it in multi }
}
