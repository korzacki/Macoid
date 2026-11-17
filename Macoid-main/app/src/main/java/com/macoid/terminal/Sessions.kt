package com.macoid.terminal

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.VibrationEffect
import android.os.Vibrator
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import java.io.File
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Builds an object that implements a Java interface by method *name*. The Termux client interfaces have
 * many methods that change between releases; going through a proxy means a missing/extra method can never
 * break the compile. Handlers return null for "nothing to say" and unmatched methods get a safe default.
 */
inline fun <reified T : Any> proxyOf(crossinline handler: (String, Array<Any?>) -> Any?): T {
    val h = InvocationHandler { p, m, a ->
        @Suppress("UNCHECKED_CAST")
        val args = (a ?: emptyArray<Any?>()) as Array<Any?>
        when (m.name) {
            "hashCode" -> System.identityHashCode(p)
            "equals" -> p === args.firstOrNull()
            "toString" -> "Proxy(" + T::class.java.simpleName + ")"
            else -> handler(m.name, args) ?: defaultFor(m.returnType)
        }
    }
    @Suppress("UNCHECKED_CAST")
    return Proxy.newProxyInstance(T::class.java.classLoader, arrayOf(T::class.java), h) as T
}

fun defaultFor(t: Class<*>): Any? = when (t) {
    java.lang.Boolean.TYPE -> false
    java.lang.Integer.TYPE -> 0
    java.lang.Float.TYPE -> 0f
    java.lang.Long.TYPE -> 0L
    java.lang.Double.TYPE -> 0.0
    else -> null
}

/** Single-quote a string for /bin/sh. */
fun shq(s: String): String = "'" + s.replace("'", "'\\''") + "'"

/** Root (su) helpers. "Root" here means: the phone is already rooted (Magisk / KernelSU / APatch ...) and Macoid asks su for a shell. */
object RootUtil {
    private val CANDIDATES = listOf(
        "/system/bin/su", "/system/xbin/su", "/sbin/su", "/su/bin/su", "/system_ext/bin/su",
        "/system/sbin/su", "/vendor/bin/su", "/data/adb/ksu/bin/su", "/data/adb/ap/bin/su"
    )

    fun suPath(): String? {
        CANDIDATES.firstOrNull { File(it).exists() }?.let { return it }
        System.getenv("PATH")?.split(':')?.forEach { d ->
            val f = File(d, "su")
            if (f.exists()) return f.path
        }
        return null
    }

    /** Runs [cmd] as root and returns (exit code, output). Blocks: call it off the UI thread. -1 = no su, -2 = timeout. */
    fun run(cmd: String, timeoutSec: Long = 30): Pair<Int, String> {
        val su = suPath() ?: return Pair(-1, "su not found - this device is not rooted")
        return try {
            val p = ProcessBuilder(su, "-c", cmd).redirectErrorStream(true).start()
            val buf = java.io.ByteArrayOutputStream()
            val t = Thread { try { p.inputStream.copyTo(buf) } catch (e: Exception) { } }
            t.start()
            if (!p.waitFor(timeoutSec, TimeUnit.SECONDS)) {
                p.destroyForcibly()
                return Pair(-2, "timeout (did you approve the root request?)")
            }
            t.join(2000)
            Pair(p.exitValue(), buf.toString("UTF-8"))
        } catch (e: Exception) {
            Pair(-1, e.message ?: e.toString())
        }
    }

    fun check(): Pair<Int, String> = run("id")
}

/** All terminal sessions live here (not in the Activity) so they survive while the app is in the background. */
object Sessions {
    interface Ui {
        fun onScreen(s: TerminalSession)
        fun onTabs()
        fun onCurrent()
        fun onEmpty()
    }

    const val VERSION = "4.0"
    val list = ArrayList<TerminalSession>()
    private val roots = HashSet<TerminalSession>()
    var current = 0
    var ui: Ui? = null
    lateinit var base: File
    private lateinit var app: Context
    private var ready = false

    private val client = proxyOf<TerminalSessionClient> { n, a -> onClient(n, a) }

    fun isRoot(s: TerminalSession) = s in roots

    @Synchronized
    fun init(ctx: Context) {
        if (ready) return
        app = ctx.applicationContext
        base = File(ctx.filesDir, "macoid")
        install(ctx)
        ready = true
    }

    // ---------------------------------------------------------------- install assets

    private fun copyAssets(ctx: Context, src: String, dst: File) {
        val kids = ctx.assets.list(src) ?: return
        if (kids.isEmpty()) {
            dst.parentFile?.mkdirs()
            ctx.assets.open(src).use { i -> dst.outputStream().use { o -> i.copyTo(o) } }
        } else {
            dst.mkdirs()
            kids.forEach { copyAssets(ctx, "$src/$it", File(dst, it)) }
        }
    }

    private fun install(ctx: Context) {
        val r = base
        listOf("home", "tmp", "root-home", "tmp-root").forEach { File(r, it).mkdirs() }
        // 4.0: the cloud / GitHub-runner / native-repo files are gone; remove what an older version left in the app folder
        listOf("lib/cloud.sh", "lib/installs.sh", "lib/runner-env.sh", "lib/native.sh", "lib/native.conf").forEach { File(r, it).delete() }
        File(r, "templates").deleteRecursively()
        File(r, "lib/skills/apk-release").deleteRecursively()
        listOf("bin", "lib").forEach { copyAssets(ctx, it, File(r, it)) }
        File(r, "bin").listFiles()?.forEach { it.setExecutable(true, false) }
        File(r, "lib").listFiles()?.forEach { it.setExecutable(true, false) }
        copyAssets(ctx, "macoid.rc", File(r, "macoid.rc"))
        val key = File(r, ".key")
        if (!key.exists()) key.writeText(UUID.randomUUID().toString())
        try { android.system.Os.symlink("/sdcard", File(r, "home/storage").absolutePath) } catch (e: Exception) { /* exists or unavailable */ }
    }

    // ---------------------------------------------------------------- environment

    private fun env(root: Boolean): LinkedHashMap<String, String> {
        // a PTY child gets exactly this environment, so start from ours (BOOTCLASSPATH etc. are needed by app_process / git / gh)
        val m = LinkedHashMap<String, String>(System.getenv())
        val b = base.absolutePath
        m["MACOID"] = b
        m["MACOID_APK"] = app.applicationInfo.sourceDir
        m["MACOID_UID"] = android.os.Process.myUid().toString()
        m["MACOID_VERSION"] = VERSION
        m["HOME"] = b + "/" + (if (root) "root-home" else "home")
        m["TMPDIR"] = b + "/" + (if (root) "tmp-root" else "tmp")
        // native (Termux-style) prefix: files/usr. Must match the prefix the packages were built for (see tools/build-repo.sh).
        val prefix = File(app.filesDir, "usr").absolutePath
        m["PREFIX"] = prefix
        m["PATH"] = "$b/bin:$prefix/bin:/system/bin:/system/xbin" +
            (if (root) ":/sbin:/system/sbin:/vendor/bin:/data/adb/magisk:/data/adb/ksu/bin" else "")
        m["TERM"] = "xterm-256color"
        m["COLORTERM"] = "truecolor"
        m["LANG"] = "en_US.UTF-8"
        m["GIT_CONFIG_NOSYSTEM"] = "1"
        m["ENV"] = "$b/macoid.rc"
        if (root) m["MACOID_ROOT"] = "1" else m.remove("MACOID_ROOT")
        return m
    }

    private val validName = Regex("[A-Za-z_][A-Za-z0-9_]*")

    // ---------------------------------------------------------------- create / remove

    /** Creates a session and makes it current. Returns null when a root session was requested but su does not exist. */
    fun create(root: Boolean): TerminalSession? {
        val home = File(base, if (root) "root-home" else "home").also { it.mkdirs() }
        File(base, if (root) "tmp-root" else "tmp").mkdirs()
        val e = env(root)
        val envArr = e.map { it.key + "=" + it.value }.toTypedArray()
        val s: TerminalSession
        if (!root) {
            s = TerminalSession("/system/bin/sh", home.absolutePath, arrayOf("sh", "-i"), envArr, 2000, client)
        } else {
            val su = RootUtil.suPath() ?: return null
            // su may drop our environment, so the root shell re-reads it from a file before starting
            val ef = File(base, "rootenv")
            ef.writeText(
                e.filter { validName.matches(it.key) && !it.value.contains('\u0000') }
                    .entries.joinToString("\n") { "export " + it.key + "=" + shq(it.value) } + "\n" +
                    "mkdir -p \"\$HOME\" \"\$TMPDIR\" 2>/dev/null\n"
            )
            val script = ". " + shq(ef.absolutePath) + "; cd \"\$HOME\" 2>/dev/null; exec /system/bin/sh -i"
            s = TerminalSession(su, home.absolutePath, arrayOf("su", "-c", script), envArr, 2000, client)
            roots.add(s)
        }
        list.add(s)
        current = list.size - 1
        if (TerminalService.instance == null) TerminalService.start(app)
        TerminalService.instance?.refresh()
        ui?.onTabs()
        ui?.onCurrent()
        return s
    }

    fun remove(s: TerminalSession) {
        val i = list.indexOf(s)
        if (i < 0) return
        s.finishIfRunning()
        list.removeAt(i)
        roots.remove(s)
        if (list.isEmpty()) {
            current = 0
            ui?.onEmpty()
            TerminalService.stop(app)
            return
        }
        if (current >= list.size) current = list.size - 1 else if (i < current) current--
        TerminalService.instance?.refresh()
        ui?.onTabs()
        ui?.onCurrent()
    }

    fun closeAll() {
        val all = list.toList()
        list.clear(); roots.clear(); current = 0
        all.forEach { it.finishIfRunning() }
        ui?.onEmpty()
    }

    // ---------------------------------------------------------------- terminal callbacks

    private fun onClient(name: String, a: Array<Any?>): Any? {
        when (name) {
            "onTextChanged", "onColorsChanged" -> (a[0] as? TerminalSession)?.let { ui?.onScreen(it) }
            "onTitleChanged" -> ui?.onTabs()
            "onSessionFinished" -> (a[0] as? TerminalSession)?.let { finished(it) }
            "onCopyTextToClipboard" -> copy(a.getOrNull(1) as? String)
            "onPasteTextFromClipboard" -> paste(a.getOrNull(0) as? TerminalSession)
            "onBell" -> bell()
        }
        return null
    }

    private fun finished(s: TerminalSession) {
        if (s !in list) return
        if (s.exitStatus == 0) { remove(s); return }
        // keep the output visible (e.g. "su: permission denied") until Enter is pressed
        val m = "\r\n[Process finished with code ${s.exitStatus} - press Enter to close]\r\n".toByteArray()
        s.emulator?.append(m, m.size)
        ui?.onScreen(s)
    }

    private fun copy(text: String?) {
        if (text.isNullOrEmpty()) return
        val cm = app.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("macoid", text))
    }

    fun paste(s: TerminalSession?) {
        val cm = app.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val t = cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(app)?.toString() ?: return
        if (t.isNotEmpty()) s?.emulator?.paste(t)
    }

    private fun bell() {
        try {
            val v = app.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            v.vibrate(VibrationEffect.createOneShot(40, VibrationEffect.DEFAULT_AMPLITUDE))
        } catch (e: Exception) { }
    }
}
