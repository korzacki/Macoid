package com.macoid.terminal

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.TextView
import android.widget.Toast
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient

/** Termux-style screen: session tabs on top, a real terminal (PTY + xterm emulation) in the middle, extra keys at the bottom. */
class MainActivity : Activity(), Sessions.Ui {
    private lateinit var tv: TerminalView
    private lateinit var tabs: LinearLayout
    private lateinit var tabScroll: HorizontalScrollView
    private lateinit var ctrlBtn: Button
    private lateinit var altBtn: Button
    private lateinit var prefs: SharedPreferences
    private val main = Handler(Looper.getMainLooper())
    private var ctrl = false
    private var alt = false
    private var fontDp = 14

    private val cBar = 0xFF1C1C1E.toInt()
    private val cBtn = 0xFF2C2C2E.toInt()
    private val cOn = 0xFF0A84FF.toInt()

    private val viewClient = proxyOf<TerminalViewClient> { n, a -> viewCall(n, a) }

    private fun viewCall(n: String, a: Array<Any?>): Any? = when (n) {
        "onScale" -> {
            val s = a[0] as Float
            if (s < 0.9f || s > 1.1f) { zoom(s > 1f); 1f } else s
        }
        "onSingleTapUp" -> { showKeyboard(); null }
        "shouldBackButtonBeMappedToEscape" -> false
        "shouldEnforceCharBasedInput" -> true
        "shouldUseCtrlSpaceWorkaround" -> false
        "isTerminalViewSelected" -> true
        "onKeyDown" -> {
            val code = a[0] as Int
            val s = a.getOrNull(2) as? TerminalSession
            if (s != null && !s.isRunning && code == KeyEvent.KEYCODE_ENTER) { Sessions.remove(s); true } else false
        }
        "readControlKey" -> readMod(true)
        "readAltKey" -> readMod(false)
        else -> null
    }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        Sessions.init(this)
        prefs = getSharedPreferences("macoid", MODE_PRIVATE)
        fontDp = prefs.getInt("font", 14)
        buildUi()
        Sessions.ui = this
        if (Sessions.list.isEmpty()) Sessions.create(false)
        show(Sessions.current)
        handleIntent(intent)
    }

    override fun onNewIntent(i: Intent) { super.onNewIntent(i); handleIntent(i) }

    private fun handleIntent(i: Intent?) {
        if (i?.action == "macoid.SETUP_STORAGE") {
            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE, Manifest.permission.READ_EXTERNAL_STORAGE), 1)
        }
    }

    override fun onResume() {
        super.onResume()
        Sessions.ui = this
        renderTabs()
        tv.onScreenUpdated()
    }

    override fun onBackPressed() { moveTaskToBack(true) }   // sessions keep running in the service

    override fun onDestroy() {
        if (Sessions.ui === this) Sessions.ui = null
        super.onDestroy()
    }

    // ---------------------------------------------------------------- Sessions.Ui

    override fun onScreen(s: TerminalSession) {
        if (Sessions.list.getOrNull(Sessions.current) === s) tv.onScreenUpdated()
    }
    override fun onTabs() = renderTabs()
    override fun onCurrent() = show(Sessions.current)
    override fun onEmpty() { finish() }

    // ---------------------------------------------------------------- UI

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun btn(label: String, onClick: () -> Unit): Button = Button(this).apply {
        text = label; isAllCaps = false; textSize = 13f; setTextColor(Color.WHITE)
        setBackgroundColor(cBtn); minWidth = 0; minimumWidth = 0; minHeight = 0; minimumHeight = 0
        setPadding(dp(8), 0, dp(8), 0)
        setOnClickListener { onClick() }
    }

    private fun lp(w: Int, weight: Float = 0f) = LinearLayout.LayoutParams(w, dp(40), weight).apply { setMargins(dp(1), dp(1), dp(1), dp(1)) }

    private fun buildUi() {
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.BLACK) }

        // tab bar
        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setBackgroundColor(cBar) }
        tabs = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        tabScroll = HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; addView(tabs) }
        bar.addView(tabScroll, LinearLayout.LayoutParams(0, dp(40), 1f))
        bar.addView(btn("+") { newSession(false) }, lp(dp(44)))
        bar.addView(btn("#") { newSession(true) }, lp(dp(44)))
        bar.addView(btn("\u22EE") {}.also { b -> b.setOnClickListener { menu(b) } }, lp(dp(44)))
        col.addView(bar, LinearLayout.LayoutParams(-1, -2))

        // terminal
        tv = TerminalView(this, null).apply { isFocusable = true; isFocusableInTouchMode = true }
        tv.setTerminalViewClient(viewClient)
        tv.setTextSize(dp(fontDp))
        col.addView(tv, LinearLayout.LayoutParams(-1, 0, 1f))

        // extra keys, row 1
        val r1 = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setBackgroundColor(Color.BLACK) }
        r1.addView(btn("ESC") { sendText("\u001b", raw = true) }, lp(0, 1f))
        r1.addView(btn("TAB") { sendText("\t", raw = true) }, lp(0, 1f))
        ctrlBtn = btn("CTRL") { ctrl = !ctrl; updateMods() }
        altBtn = btn("ALT") { alt = !alt; updateMods() }
        r1.addView(ctrlBtn, lp(0, 1f)); r1.addView(altBtn, lp(0, 1f))
        r1.addView(btn("\u2190") { sendKey(KeyEvent.KEYCODE_DPAD_LEFT) }, lp(0, 1f))
        r1.addView(btn("\u2193") { sendKey(KeyEvent.KEYCODE_DPAD_DOWN) }, lp(0, 1f))
        r1.addView(btn("\u2191") { sendKey(KeyEvent.KEYCODE_DPAD_UP) }, lp(0, 1f))
        r1.addView(btn("\u2192") { sendKey(KeyEvent.KEYCODE_DPAD_RIGHT) }, lp(0, 1f))
        col.addView(r1, LinearLayout.LayoutParams(-1, -2))

        // extra keys, row 2 (scrolls)
        val r2 = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        r2.addView(btn("HOME") { sendKey(KeyEvent.KEYCODE_MOVE_HOME) }, lp(-2))
        r2.addView(btn("END") { sendKey(KeyEvent.KEYCODE_MOVE_END) }, lp(-2))
        r2.addView(btn("PGUP") { sendKey(KeyEvent.KEYCODE_PAGE_UP) }, lp(-2))
        r2.addView(btn("PGDN") { sendKey(KeyEvent.KEYCODE_PAGE_DOWN) }, lp(-2))
        "/ - | ~ $ * ' \" \\ ; = & < > _ . : ! # % ^ @ ` , ( ) { } [ ] +".split(" ").forEach { k ->
            r2.addView(btn(k) { sendText(k) }, lp(dp(40)))
        }
        col.addView(HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; setBackgroundColor(Color.BLACK); addView(r2) },
            LinearLayout.LayoutParams(-1, -2))

        setContentView(col)
        updateMods()
    }

    private fun renderTabs() {
        tabs.removeAllViews()
        Sessions.list.forEachIndexed { i, s ->
            val root = Sessions.isRoot(s)
            val title = s.title?.takeIf { it.isNotBlank() }?.let { ": " + it.take(14) } ?: ""
            val t = TextView(this).apply {
                text = (i + 1).toString() + (if (root) " #" else " \$") + title
                setTextColor(Color.WHITE); textSize = 13f; gravity = Gravity.CENTER
                setPadding(dp(12), 0, dp(12), 0)
                setBackgroundColor(if (i == Sessions.current) (if (root) 0xFFB3261E.toInt() else cOn) else cBtn)
                setOnClickListener { Sessions.current = i; show(i) }
                setOnLongClickListener { confirmClose(s); true }
            }
            tabs.addView(t, lp(-2))
        }
        main.post { tabScroll.fullScroll(View.FOCUS_RIGHT) }
    }

    private fun show(i: Int) {
        if (Sessions.list.isEmpty()) return
        Sessions.current = i.coerceIn(0, Sessions.list.size - 1)
        tv.attachSession(Sessions.list[Sessions.current])
        tv.onScreenUpdated()
        tv.requestFocus()
        renderTabs()
    }

    private fun cur(): TerminalSession? = Sessions.list.getOrNull(Sessions.current)

    private fun newSession(root: Boolean) {
        if (Sessions.create(root) == null) {
            Toast.makeText(this, "su not found - this device is not rooted (Magisk / KernelSU / APatch)", Toast.LENGTH_LONG).show()
        }
    }

    private fun confirmClose(s: TerminalSession) {
        AlertDialog.Builder(this).setMessage("Close this session?")
            .setPositiveButton("Close") { _, _ -> Sessions.remove(s) }
            .setNegativeButton("Cancel", null).show()
    }

    private fun menu(anchor: View) {
        val m = PopupMenu(this, anchor)
        m.menu.add(0, 1, 0, "Paste")
        m.menu.add(0, 2, 0, "New session")
        m.menu.add(0, 3, 0, "New root session (su)")
        m.menu.add(0, 4, 0, "Close this session")
        m.menu.add(0, 5, 0, "Font bigger")
        m.menu.add(0, 6, 0, "Font smaller")
        m.menu.add(0, 7, 0, if (TerminalService.wakeHeld()) "Wake lock: turn off" else "Wake lock: turn on")
        m.menu.add(0, 8, 0, "Check root access")
        m.menu.add(0, 9, 0, "Exit (close all sessions)")
        m.setOnMenuItemClickListener {
            when (it.itemId) {
                1 -> Sessions.paste(cur())
                2 -> newSession(false)
                3 -> newSession(true)
                4 -> cur()?.let { s -> Sessions.remove(s) }
                5 -> zoom(true)
                6 -> zoom(false)
                7 -> TerminalService.toggleWake(this)
                8 -> checkRoot()
                9 -> Sessions.closeAll()
            }
            true
        }
        m.show()
    }

    private fun checkRoot() {
        Toast.makeText(this, "Checking root (approve the su prompt if one appears)...", Toast.LENGTH_SHORT).show()
        Thread {
            val (code, out) = RootUtil.check()
            runOnUiThread {
                val msg = if (code == 0) "Root OK: " + out.trim() else "No root access: " + out.trim()
                Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
            }
        }.start()
    }

    // ---------------------------------------------------------------- keys

    private fun zoom(bigger: Boolean) {
        fontDp = (fontDp + if (bigger) 1 else -1).coerceIn(8, 32)
        prefs.edit().putInt("font", fontDp).apply()
        tv.setTextSize(dp(fontDp))
    }

    private fun showKeyboard() {
        val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showSoftInput(tv, InputMethodManager.SHOW_IMPLICIT)
    }

    private fun readMod(isCtrl: Boolean): Boolean {
        val v = if (isCtrl) ctrl else alt
        if (v) {
            if (isCtrl) ctrl = false else alt = false
            main.post { updateMods() }
        }
        return v
    }

    private fun updateMods() {
        ctrlBtn.setBackgroundColor(if (ctrl) cOn else cBtn)
        altBtn.setBackgroundColor(if (alt) cOn else cBtn)
    }

    /** Arrows / Home / End / PgUp / PgDn go through the terminal view so application-cursor mode (vim, less, ...) is respected. */
    private fun sendKey(code: Int) {
        val now = SystemClock.uptimeMillis()
        tv.onKeyDown(code, KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
        tv.onKeyUp(code, KeyEvent(now, now, KeyEvent.ACTION_UP, code, 0))
        ctrl = false; alt = false; updateMods()
    }

    /** Literal text from the extra-key row, honouring the CTRL / ALT toggles. */
    private fun sendText(s: String, raw: Boolean = false) {
        val sess = cur() ?: return
        var t = s
        if (!raw && ctrl && s.length == 1) {
            val c = s[0]
            val code = when {
                c in 'a'..'z' -> c - 'a' + 1
                c in 'A'..'Z' -> c - 'A' + 1
                c in '@'..'_' -> c - '@'
                c == '?' -> 127
                else -> -1
            }
            if (code >= 0) t = code.toChar().toString()
        }
        if (alt) t = "\u001b" + t
        sess.write(t)
        ctrl = false; alt = false; updateMods()
    }
}
