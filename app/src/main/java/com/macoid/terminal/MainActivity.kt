package com.macoid.terminal

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.Typeface
import android.os.*
import android.view.Gravity
import android.view.inputmethod.EditorInfo
import android.widget.*
import java.io.File
import java.io.OutputStreamWriter
import java.util.UUID

class MainActivity : Activity() {
    private lateinit var out: TextView
    private lateinit var scroll: ScrollView
    private lateinit var input: EditText
    private lateinit var promptLbl: TextView
    private val ui = Handler(Looper.getMainLooper())
    private var proc: java.lang.Process? = null
    private var writer: OutputStreamWriter? = null
    private val history = ArrayList<String>()
    private var hIdx = 0
    private var cwd = "~"
    private var curPath = ""
    private var gen = 0
    private var busy = false
    private var lastOut = ""
    private val pending = StringBuilder()
    private lateinit var root: File
    private val ansi = Regex("\u001B\\[[0-9;?]*[A-Za-z]")
    private val tail = Regex("([&|;\\\\({]|\\b(then|do|else))$")
    private val editors = setOf("nano", "vi", "vim", "edit", "pico", "emacs", "code", "open -e")

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        buildUi()
        root = install()
        curPath = File(root, "home").absolutePath
        startShell()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun buildUi() {
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.BLACK) }
        out = TextView(this).apply {
            typeface = Typeface.MONOSPACE; textSize = 12.5f; setTextColor(Color.parseColor("#E6E6E6"))
            setPadding(dp(8), dp(8), dp(8), dp(8)); setTextIsSelectable(true)
        }
        scroll = ScrollView(this).apply { addView(out) }
        col.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))

        val keys = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun key(t: String, a: () -> Unit) {
            val bt = Button(this).apply { text = t; isAllCaps = false; textSize = 12f; minWidth = dp(44); setPadding(dp(6), 0, dp(6), 0); setOnClickListener { a() } }
            keys.addView(bt, LinearLayout.LayoutParams(-2, dp(40)))
        }
        fun ins(s: String) = key(s) { input.append(s) }
        key("^C") { restart() }
        key("Tab") { complete() }
        key("↑") { if (hIdx > 0) { hIdx--; input.setText(history[hIdx]); input.setSelection(input.text.length) } }
        key("↓") { if (hIdx < history.size - 1) { hIdx++; input.setText(history[hIdx]) } else { hIdx = history.size; input.setText("") } }
        listOf("~", "/", "|", "-", ".", "_", ">", "<", "&", "$", "*", "'", "\"", "\\", ";", "=").forEach { ins(it) }
        col.addView(HorizontalScrollView(this).apply { addView(keys) })

        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        promptLbl = TextView(this).apply { typeface = Typeface.MONOSPACE; setTextColor(Color.parseColor("#5AF78E")); setPadding(dp(8), 0, 0, 0) }
        input = EditText(this).apply {
            typeface = Typeface.MONOSPACE; setTextColor(Color.WHITE); setSingleLine(true)
            imeOptions = EditorInfo.IME_ACTION_SEND
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            setOnEditorActionListener { _, _, _ -> run(); true }
        }
        row.addView(promptLbl); row.addView(input, LinearLayout.LayoutParams(0, -2, 1f))
        col.addView(row)
        setContentView(col)
        updatePrompt()
    }

    private fun updatePrompt() { promptLbl.text = "macoid@android $cwd %" }

    private fun copyAssets(src: String, dst: File) {
        val list = assets.list(src) ?: return
        if (list.isEmpty()) {
            dst.parentFile?.mkdirs()
            assets.open(src).use { i -> dst.outputStream().use { o -> i.copyTo(o) } }
        } else {
            dst.mkdirs()
            list.forEach { copyAssets("$src/$it", File(dst, it)) }
        }
    }

    private fun install(): File {
        val r = File(filesDir, "macoid")
        File(r, "home").mkdirs(); File(r, "tmp").mkdirs()
        listOf("bin", "lib", "templates").forEach { copyAssets(it, File(r, it)) }
        File(r, "bin").listFiles()?.forEach { it.setExecutable(true, false) }
        File(r, "lib").listFiles()?.forEach { it.setExecutable(true, false) }
        copyAssets("macoid.rc", File(r, "macoid.rc"))
        val key = File(r, ".key")
        if (!key.exists()) key.writeText(UUID.randomUUID().toString())
        try { android.system.Os.symlink("/sdcard", File(r, "home/storage").absolutePath) } catch (e: Exception) { /* exists or unavailable */ }
        return r
    }

    private fun startShell() {
        val my = ++gen
        val pb = ProcessBuilder("/system/bin/sh").redirectErrorStream(true)
        val env = pb.environment()
        env["MACOID"] = root.absolutePath
        env["MACOID_APK"] = applicationInfo.sourceDir
        env["HOME"] = File(root, "home").absolutePath
        env["TMPDIR"] = File(root, "tmp").absolutePath
        env["PATH"] = "${root.absolutePath}/bin:/system/bin:/system/xbin"
        env["TERM"] = "dumb"
        env["LANG"] = "en_US.UTF-8"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        pb.directory(File(env["HOME"]!!))
        val p = pb.start(); proc = p
        writer = OutputStreamWriter(p.outputStream)
        send(". \"\$MACOID/macoid.rc\"", false)
        if (curPath != File(root, "home").absolutePath) send("cd '${curPath.replace("'", "'\\''")}' 2>/dev/null", false)
        send("macoid motd")
        Thread {
            val rd = p.inputStream.reader(); val buf = CharArray(4096)
            while (true) { val n = rd.read(buf); if (n < 0) break; feed(String(buf, 0, n)) }
            if (my == gen) { emit("\n[shell exited - restarting]\n"); ui.post { startShell() } }
        }.start()
    }

    private fun send(cmd: String, marker: Boolean = true) {
        try {
            val t = cmd.trimEnd()
            val mk = "printf '\\001%s\\001\\n' \"\$PWD\""
            val line = when {
                !marker -> "$t\n"
                !t.contains('#') && !tail.containsMatchIn(t) -> "$t; $mk\n"   // same line, so programs reading stdin see the next typed line
                else -> "$t\n$mk\n"
            }
            writer?.write(line); writer?.flush()
        } catch (e: Exception) { emit("[error: ${e.message}]\n") }
    }

    private fun restart() { busy = false; gen++; proc?.destroyForcibly(); emit("^C\n"); startShell() }

    private fun resolve(arg: String): File = when {
        arg.startsWith("/") -> File(arg)
        arg == "~" || arg.startsWith("~/") -> File(File(root, "home"), arg.removePrefix("~").trimStart('/'))
        else -> File(curPath, arg)
    }

    private fun run() {
        val c = input.text.toString(); input.setText("")
        if (c.isBlank()) return
        history.add(c); hIdx = history.size
        val t = c.trim()
        val first = t.substringBefore(' ')
        if (t == "clear" || t == "reset") { out.text = ""; return }
        val secret = busy && (lastOut.contains("token", true) || lastOut.contains("password", true))
        emit(if (secret) "(hidden)\n" else if (busy) "$c\n" else "${promptLbl.text} $c\n")
        when {
            t == "exit" || t == "logout" -> restart()
            first in editors && t.contains(' ') -> openEditor(t.substringAfter(' ').trim().trim('"', '\''))
            first == "setup-storage" -> {
                requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE, Manifest.permission.READ_EXTERNAL_STORAGE), 1)
                emit("Requested storage access. Your shared storage is at ~/storage\n")
            }
            else -> if (busy) send(c, false) else { busy = true; send(c) }
        }
    }

    /** Minimal built-in text editor for nano / vi / vim / edit / code. */
    private fun openEditor(arg: String) {
        val f = resolve(arg)
        val text = try { if (f.exists()) f.readText() else "" } catch (e: Exception) { emit("edit: cannot read ${f.path}\n"); return }
        val et = EditText(this).apply {
            typeface = Typeface.MONOSPACE; textSize = 13f; setText(text)
            gravity = Gravity.TOP or Gravity.START; minLines = 12
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE or android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        }
        AlertDialog.Builder(this).setTitle(f.name).setView(et)
            .setPositiveButton("Save") { _, _ ->
                try { f.parentFile?.mkdirs(); f.writeText(et.text.toString()); emit("Saved ${f.path}\n") }
                catch (e: Exception) { emit("edit: cannot write ${f.path}: ${e.message}\n") }
            }
            .setNegativeButton("Cancel", null).show()
    }

    /** Tab completion for the last word, using the shell's own glob expansion. */
    private fun complete() {
        val s = input.text.toString()
        val w = s.substringAfterLast(' ')
        if (w.isEmpty()) return
        try {
            val dir = if (w.contains('/')) resolve(w.substringBeforeLast('/', "/").ifEmpty { "/" }) else File(curPath)
            val prefix = w.substringAfterLast('/')
            val hits = dir.listFiles()?.map { it.name + if (it.isDirectory) "/" else "" }?.filter { it.startsWith(prefix) }?.sorted() ?: return
            if (hits.size == 1) {
                val base = if (w.contains('/')) w.substringBeforeLast('/') + "/" else ""
                input.setText(s.dropLast(w.length) + base + hits[0]); input.setSelection(input.text.length)
            } else if (hits.size > 1) emit(hits.joinToString("  ") + "\n")
        } catch (e: Exception) { /* ignore */ }
    }

    private fun feed(s: String) {
        pending.append(s)
        while (true) {
            val a = pending.indexOf("\u0001")
            if (a < 0) { emit(pending.toString()); pending.setLength(0); return }
            val bI = pending.indexOf("\u0001", a + 1)
            if (bI < 0) { emit(pending.substring(0, a)); pending.delete(0, a); return }
            emit(pending.substring(0, a))
            val path = pending.substring(a + 1, bI)
            pending.delete(0, bI + 1)
            if (pending.startsWith("\n")) pending.deleteCharAt(0)
            val home = File(root, "home").absolutePath
            curPath = path
            busy = false
            cwd = if (path.startsWith(home)) "~" + path.removePrefix(home) else path
            ui.post { updatePrompt() }
        }
    }

    private fun emit(t: String) {
        val clean = ansi.replace(t, "")
        lastOut = (lastOut + clean).takeLast(160)
        if (clean.isEmpty()) return
        ui.post {
            out.append(clean)
            if (out.length() > 200_000) out.text = out.text.subSequence(out.length() - 150_000, out.length())
            scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
        }
    }

    override fun onDestroy() { gen++; proc?.destroy(); super.onDestroy() }
}
